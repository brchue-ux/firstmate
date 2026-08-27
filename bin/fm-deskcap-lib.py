#!/usr/bin/env python3
"""Still desktop capture for the captain's Wayland session, as importable core + CLI.

This is the CAPTURE ENGINE half of firstmate's desktop-capture tool. The MCP
surface that agents actually call lives in bin/fm-deskcap-mcp.py and does no
capture of its own; everything about talking to the compositor is here.

Scopes (slice 1): `screen` (the whole virtual display) and `region` (an explicit
x/y/width/height rectangle). Per-window capture is deliberately absent - it needs
a window id that GNOME Shell 50 denies to ordinary callers.

Two independent routes, both implemented from the start:

  mutter  PRIMARY. org.gnome.Mutter.ScreenCast - the compositor's own screen-cast
          API. Reachable unprivileged with no permission dialog, and the only
          route with a native region scope (RecordArea). Captures straight to
          memory; nothing is written to disk.
  portal  FALLBACK. org.freedesktop.portal.Screenshot. Whole-screen only, so a
          region is cropped afterwards. The portal chooses where to write the
          file (in practice ~/Pictures); this module reads those bytes back and
          then unlinks that exact file, so a capture never leaves litter behind.

`auto` (the default) tries mutter and falls back to portal. The fallback is not
decoration: nothing in Mutter's ScreenCast API performs an allowlist check today,
and if a future GNOME release adds one, the portal route is what keeps this
working.

Two D-Bus handshake rules are load-bearing, and getting either wrong makes a
call that actually SUCCEEDS look like a total failure:

  1. Subscribe to Stream.PipeWireStreamAdded on the stream path BEFORE calling
     Session.Start(). The signal arrives in single-digit milliseconds.
  2. Subscribe to Request.Response on the PREDICTED portal request path BEFORE
     calling Screenshot(). The portal answers in ~100 ms and destroys the Request
     object; subscribing to the returned handle afterwards can never see it.

Each capture builds a fresh screen-cast session and tears it down. That is a
deliberate choice over a cached warm pipeline: the captain's session is a
headless GNOME Remote Login (RDP) one whose virtual monitor is torn down when he
disconnects, and Mutter reuses PipeWire node ids across sessions. A per-call
session cannot serve a stale frame, cannot outlive the monitor it recorded, and
still lands around 100 ms. Session.Closed is handled on top of that: if the
compositor closes the session mid-capture, the capture is rebuilt once rather
than reported as a failure. That close is only observable while the GLib default
main context is iterated, so the frame pull pumps it by hand rather than blocking
on GStreamer alone.

Both scopes record through RecordArea: `screen` is the full virtual desktop
bounds, not the primary monitor, so both routes answer the same arguments with
the same content on a multi-monitor layout. RecordArea works in logical pixels,
which under non-unity scaling is not a monitor's native resolution.

Logical pixels are this engine's one coordinate space, because that is what
RecordArea takes and what a region is validated against. The portal returns the
compositor's own framebuffer instead, which under non-unity scaling is larger, so
the portal route reconciles both scopes back into logical pixels: a region is
mapped into the screenshot's own pixel space before cropping and the crop is then
resampled to the requested size, and a screen capture is resampled to the desktop
bounds. The factor comes from the screenshot's real dimensions rather than from a
configured scale value. Without that a scaled display would answer the same call
with a different area or a different pixel size depending on which route won, and
coordinates read off one route's image would not map onto the other's.

Rotated outputs are NOT supported. Mutter swaps a logical monitor's axes when the
transform is rotated and this engine does not, so the bounds it derives for a
rotated output have their axes the wrong way round.

One capture gets one end-to-end deadline, starting at the region check that
reads the display layout. The rebuild after a close and the fallback to the
portal both spend what is left of it rather than each starting a fresh budget,
and every D-Bus call is capped by the remainder, so a wedged compositor cannot
stack timeouts against a caller serving requests in sequence.

Environment: only XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are required. No
WAYLAND_DISPLAY, no DISPLAY, no desktop session inheritance - an agent process
running as the captain's user can capture from a bare SSH environment.

CLI:
  fm-deskcap-lib.py screen <out.png|-> [--route auto|mutter|portal] [--no-cursor]
  fm-deskcap-lib.py region <x> <y> <w> <h> <out.png|-> [--route ...] [--no-cursor]
  fm-deskcap-lib.py probe [--json]

Exit status: 0 capture written, 1 capture failed on every attempted route,
2 bad arguments or a missing runtime dependency.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

MUTTER_BUS = "org.gnome.Mutter.ScreenCast"
MUTTER_PATH = "/org/gnome/Mutter/ScreenCast"
MUTTER_SESSION_IFACE = "org.gnome.Mutter.ScreenCast.Session"
MUTTER_STREAM_IFACE = "org.gnome.Mutter.ScreenCast.Stream"
DISPLAY_CONFIG_BUS = "org.gnome.Mutter.DisplayConfig"
DISPLAY_CONFIG_PATH = "/org/gnome/Mutter/DisplayConfig"
PORTAL_BUS = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
PORTAL_SCREENSHOT_IFACE = "org.freedesktop.portal.Screenshot"
PORTAL_REQUEST_IFACE = "org.freedesktop.portal.Request"

# cursor-mode: 0 hidden, 1 embedded in the framebuffer, 2 metadata only.
CURSOR_EMBEDDED = 1
CURSOR_HIDDEN = 0

ROUTES = ("auto", "mutter", "portal")
SCOPES = ("screen", "region")

DEFAULT_TIMEOUT = 15.0
DBUS_CALL_TIMEOUT_MS = 10000
# Floor on what any single attempt is given once the shared deadline is nearly
# spent, so a late attempt fails fast instead of not being tried at all.
MIN_ATTEMPT_SECONDS = 0.5
MIN_CALL_TIMEOUT_MS = 100

_GI_IMPORT_ERROR: str | None = None
try:
    import gi

    gi.require_version("Gio", "2.0")
    gi.require_version("GLib", "2.0")
    gi.require_version("Gst", "1.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf, Gio, GLib, Gst
except Exception as err:  # noqa: BLE001 - reported as a clean CaptureError later
    _GI_IMPORT_ERROR = f"{type(err).__name__}: {err}"

# Any handler that can run BEFORE `_require_gi()` has succeeded must reach for
# this rather than naming GLib.Error: when the import above failed the name GLib
# does not exist, and an except clause that mentions it dies with NameError on
# exactly the broken machine `probe` is meant to diagnose. Handlers reachable
# only after `_require_gi()` may name GLib.Error directly, which is why every
# function that touches GdkPixbuf or Gst calls `_require_gi()` on entry.
if _GI_IMPORT_ERROR is None:
    _GLIB_ERRORS: tuple[type[BaseException], ...] = (GLib.Error,)
else:
    _GLIB_ERRORS = ()


class CaptureError(RuntimeError):
    """A capture could not be produced by the requested route."""


class SessionClosed(CaptureError):
    """The compositor closed the screen-cast session before a frame arrived."""


class MissingDependency(CaptureError):
    """A package this machine needs for a route is not installed.

    Distinct from an ordinary capture failure because the operator has to install
    something rather than retry, which is what the CLI's exit status 2 means.
    """


class Capture:
    """One still, in memory. `png` is the complete PNG file's bytes."""

    def __init__(self, png: bytes, route: str, scope: str, elapsed_ms: float, notes: list[str]):
        self.png = png
        self.route = route
        self.scope = scope
        self.elapsed_ms = elapsed_ms
        self.notes = notes
        self.width, self.height = png_dimensions(png)

    def summary(self) -> str:
        return (
            f"{self.scope} via {self.route}: {self.width}x{self.height} PNG, "
            f"{len(self.png)} bytes, {self.elapsed_ms:.0f} ms"
        )


def png_dimensions(png: bytes) -> tuple[int, int]:
    """Width and height from the PNG IHDR chunk. Raises on anything that is not a PNG."""
    if len(png) < 24 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
        raise CaptureError("capture did not produce a PNG")
    width, height = struct.unpack(">II", png[16:24])
    if width == 0 or height == 0:
        raise CaptureError("capture produced a zero-sized PNG")
    return width, height


# ---------------------------------------------------------------------------
# Runtime plumbing
# ---------------------------------------------------------------------------


def _require_gi() -> None:
    if _GI_IMPORT_ERROR is not None:
        raise MissingDependency(
            "python3 GObject introspection bindings are unavailable "
            f"({_GI_IMPORT_ERROR}); install python3-gi, gir1.2-gst-plugins-base-1.0 "
            "and gir1.2-gdkpixbuf-2.0"
        )


def _session_bus() -> Any:
    _require_gi()
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS") and not os.environ.get("XDG_RUNTIME_DIR"):
        raise CaptureError(
            "neither DBUS_SESSION_BUS_ADDRESS nor XDG_RUNTIME_DIR is set, so the "
            "session bus cannot be reached"
        )
    try:
        return Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as err:
        raise CaptureError(f"cannot reach the session bus: {err.message}") from err


_GST_READY = False


def _require_gst() -> None:
    global _GST_READY
    _require_gi()
    if not _GST_READY:
        Gst.init(None)
        _GST_READY = True
    if Gst.ElementFactory.find("pipewiresrc") is None:
        raise MissingDependency("the GStreamer element pipewiresrc is missing; install gstreamer1.0-pipewire")
    if Gst.ElementFactory.find("pngenc") is None:
        raise MissingDependency("the GStreamer element pngenc is missing; install gstreamer1.0-plugins-good")


def _remaining(deadline: float) -> float:
    """Seconds left before `deadline`, floored so an attempt is still made."""
    return max(MIN_ATTEMPT_SECONDS, deadline - time.monotonic())


def _call_timeout_ms(deadline: float) -> int:
    """A single D-Bus call's timeout, never longer than what `deadline` allows."""
    left = int((deadline - time.monotonic()) * 1000)
    return max(MIN_CALL_TIMEOUT_MS, min(DBUS_CALL_TIMEOUT_MS, left))


def _error_text(err: BaseException) -> str:
    """A readable message from either a CaptureError or a raw GLib.Error."""
    return getattr(err, "message", None) or str(err)


def _pump_main_context() -> None:
    """Deliver anything queued on the default main context without blocking.

    D-Bus signal callbacks only run while that context is iterated. Code that
    blocks on something other than a main loop has to pump it by hand, or a
    signal that already arrived stays queued and is never observed.
    """
    context = GLib.MainContext.default()
    while context.pending():
        context.iteration(False)


def _run_until(predicate, timeout: float) -> bool:
    """Iterate the default main context until `predicate()` is true or `timeout` elapses."""
    loop = GLib.MainLoop()
    sources: dict[str, int | None] = {"poll": None, "expire": None}

    def _poll() -> bool:
        if predicate():
            sources["poll"] = None
            loop.quit()
            return False
        return True

    def _expire() -> bool:
        sources["expire"] = None
        loop.quit()
        return False

    if predicate():
        return True
    sources["poll"] = GLib.timeout_add(2, _poll)
    sources["expire"] = GLib.timeout_add(max(1, int(timeout * 1000)), _expire)
    try:
        loop.run()
    finally:
        for source_id in sources.values():
            if source_id is not None:
                GLib.source_remove(source_id)
    return predicate()


# ---------------------------------------------------------------------------
# Display geometry
# ---------------------------------------------------------------------------


def _logical_size(pixels: int, scale: float) -> int:
    """A mode's size in logical pixels, rounded the way Mutter's own roundf rounds.

    Truncating instead would put a fractional scale such as 1.5 a pixel short of
    the desktop Mutter reports, which then biases both `fit_region` and the
    portal route's rescale factor.
    """
    if not scale:
        return int(pixels)
    return max(1, int(pixels / scale + 0.5))


def display_state(timeout_ms: int = DBUS_CALL_TIMEOUT_MS) -> dict[str, Any]:
    """The virtual desktop's connector name and bounds, from Mutter's DisplayConfig.

    On the captain's headless RDP session this is a single synthetic monitor
    (connector `Meta-0`), but the shape below handles several logical monitors
    without assuming one. `width`/`height` are the full virtual desktop bounds;
    `monitors` keeps the per-monitor detail that probe output relies on.
    """
    bus = _session_bus()
    try:
        state = bus.call_sync(
            DISPLAY_CONFIG_BUS,
            DISPLAY_CONFIG_PATH,
            DISPLAY_CONFIG_BUS,
            "GetCurrentState",
            None,
            None,
            Gio.DBusCallFlags.NONE,
            timeout_ms,
            None,
        ).unpack()
    except GLib.Error as err:
        raise CaptureError(f"cannot read the display layout: {err.message}") from err

    monitors: list[dict[str, Any]] = []
    right = bottom = 0
    for logical in state[2]:
        x, y, scale, _transform, primary, connectors = logical[0], logical[1], logical[2], logical[3], logical[4], logical[5]
        width = height = 0
        for spec in monitors_for(state[1], [c[0] for c in connectors]):
            width, height = spec["width"], spec["height"]
            monitors.append(
                {
                    "connector": spec["connector"],
                    "x": x,
                    "y": y,
                    "width": _logical_size(width, scale),
                    "height": _logical_size(height, scale),
                    "scale": scale,
                    "primary": bool(primary),
                }
            )
    if not monitors:
        raise CaptureError("Mutter reports no logical monitors; nothing can be captured")
    for mon in monitors:
        right = max(right, mon["x"] + mon["width"])
        bottom = max(bottom, mon["y"] + mon["height"])
    primary = next((m for m in monitors if m["primary"]), monitors[0])
    return {"monitors": monitors, "primary": primary, "width": right, "height": bottom}


def monitors_for(monitor_specs: Any, connectors: list[str]) -> list[dict[str, Any]]:
    """Resolve connector names to their current mode size, preserving `connectors` order."""
    by_connector: dict[str, dict[str, Any]] = {}
    for spec in monitor_specs:
        connector = spec[0][0]
        current = next((m for m in spec[1] if m[6].get("is-current")), None)
        if current is None and spec[1]:
            current = spec[1][0]
        if current is None:
            continue
        by_connector[connector] = {"connector": connector, "width": current[1], "height": current[2]}
    return [by_connector[c] for c in connectors if c in by_connector]


def normalize_region(region: Any) -> dict[str, int]:
    """Check a region's own shape. Deliberately does not talk to the compositor.

    Callers run this before any D-Bus work so an obviously wrong rectangle is
    rejected with a useful message rather than as a compositor error.
    """
    if not isinstance(region, dict):
        raise CaptureError("region must be given as x, y, width and height")
    try:
        x, y = int(region["x"]), int(region["y"])
        width, height = int(region["width"]), int(region["height"])
    except (KeyError, TypeError, ValueError) as err:
        raise CaptureError("region needs integer x, y, width and height") from err
    if width <= 0 or height <= 0:
        raise CaptureError(f"region width and height must be positive, got {width}x{height}")
    if x < 0 or y < 0:
        raise CaptureError(f"region x and y must not be negative, got {x},{y}")
    return {"x": x, "y": y, "width": width, "height": height}


def _desktop_size(bounds: dict[str, Any] | None) -> tuple[int, int]:
    """The virtual desktop's logical size, refused rather than guessed if unknown."""
    width = int(bounds.get("width") or 0) if bounds else 0
    height = int(bounds.get("height") or 0) if bounds else 0
    if width <= 0 or height <= 0:
        raise CaptureError(
            "the desktop bounds are unknown, so a capture cannot be placed in logical pixels"
        )
    return width, height


def region_in_image_pixels(
    region: dict[str, int], bounds: dict[str, Any], image_width: int, image_height: int
) -> dict[str, int]:
    """Place a logical-pixel rectangle onto an image that may be at another scale.

    A region is given, validated and recorded by Mutter's RecordArea in logical
    pixels. The portal instead hands back whatever the compositor's own
    framebuffer is, which under non-unity scaling is larger than the logical
    desktop, so cropping the logical rectangle straight out of it would silently
    return the wrong area rather than merely the wrong resolution.

    The factor is derived from the image the portal actually returned against the
    desktop bounds, not from a configured scale value, so it stays correct
    whatever the portal chose to do.
    """
    desktop_width, desktop_height = _desktop_size(bounds)
    if (image_width, image_height) == (desktop_width, desktop_height):
        return region
    scale_x = image_width / desktop_width
    scale_y = image_height / desktop_height
    x = max(0, min(image_width - 1, round(region["x"] * scale_x)))
    y = max(0, min(image_height - 1, round(region["y"] * scale_y)))
    return {
        "x": x,
        "y": y,
        "width": max(1, min(image_width - x, round(region["width"] * scale_x))),
        "height": max(1, min(image_height - y, round(region["height"] * scale_y))),
    }


def fit_region(region: dict[str, int], bounds: dict[str, Any]) -> dict[str, int]:
    """Reject an already-normalized region that falls outside the desktop."""
    if region["x"] + region["width"] > bounds["width"] or region["y"] + region["height"] > bounds["height"]:
        raise CaptureError(
            f"region {region['width']}x{region['height']}+{region['x']}+{region['y']} does not fit the "
            f"{bounds['width']}x{bounds['height']} desktop"
        )
    return region


# ---------------------------------------------------------------------------
# Route 1 (primary): org.gnome.Mutter.ScreenCast
# ---------------------------------------------------------------------------


def _mutter_capture(
    scope: str,
    region: dict[str, int] | None,
    cursor: bool,
    timeout: float,
    bounds: dict[str, Any] | None = None,
) -> bytes:
    _require_gst()
    bus = _session_bus()
    deadline = time.monotonic() + timeout

    try:
        session_path = bus.call_sync(
            MUTTER_BUS,
            MUTTER_PATH,
            MUTTER_BUS,
            "CreateSession",
            GLib.Variant("(a{sv})", ({},)),
            None,
            Gio.DBusCallFlags.NONE,
            _call_timeout_ms(deadline),
            None,
        ).unpack()[0]
    except GLib.Error as err:
        raise CaptureError(f"Mutter refused a screen-cast session: {err.message}") from err

    closed = {"seen": False}
    subscriptions: list[int] = []

    def _unsubscribe() -> None:
        for sub in subscriptions:
            bus.signal_unsubscribe(sub)
        subscriptions.clear()

    def _session_call(method: str, args: Any = None) -> Any:
        return bus.call_sync(
            MUTTER_BUS,
            session_path,
            MUTTER_SESSION_IFACE,
            method,
            args,
            None,
            Gio.DBusCallFlags.NONE,
            _call_timeout_ms(deadline),
            None,
        )

    try:
        # The virtual monitor of a headless RDP session disappears when the
        # captain disconnects, and Mutter announces that as Session.Closed.
        # Subscribe before recording anything so the close is never missed.
        subscriptions.append(
            bus.signal_subscribe(
                MUTTER_BUS,
                MUTTER_SESSION_IFACE,
                "Closed",
                session_path,
                None,
                Gio.DBusSignalFlags.NONE,
                lambda *_args: closed.__setitem__("seen", True),
            )
        )

        props = {"cursor-mode": GLib.Variant("u", CURSOR_EMBEDDED if cursor else CURSOR_HIDDEN)}
        if scope == "region":
            assert region is not None
            area = region
        else:
            # `screen` means the whole virtual desktop, not the primary monitor,
            # so both routes answer the same arguments with the same content.
            layout = bounds or display_state(_call_timeout_ms(deadline))
            width, height = _desktop_size(layout)
            area = {"x": 0, "y": 0, "width": width, "height": height}
        try:
            stream_path = _session_call(
                "RecordArea",
                GLib.Variant(
                    "(iiiia{sv})",
                    (area["x"], area["y"], area["width"], area["height"], props),
                ),
            ).unpack()[0]
        except GLib.Error as err:
            raise CaptureError(f"Mutter refused the {scope} stream: {err.message}") from err

        # RULE 1: subscribe before Start(). PipeWireStreamAdded lands within a
        # few milliseconds, and a subscription made afterwards never sees it.
        node = {"id": None}
        subscriptions.append(
            bus.signal_subscribe(
                MUTTER_BUS,
                MUTTER_STREAM_IFACE,
                "PipeWireStreamAdded",
                stream_path,
                None,
                Gio.DBusSignalFlags.NONE,
                lambda *args: node.__setitem__("id", args[5].unpack()[0]),
            )
        )

        try:
            _session_call("Start")
        except GLib.Error as err:
            raise CaptureError(f"Mutter refused to start the screen cast: {err.message}") from err

        if not _run_until(lambda: node["id"] is not None or closed["seen"], _remaining(deadline)):
            raise CaptureError("Mutter never announced a PipeWire stream for the capture")
        if closed["seen"]:
            raise SessionClosed("the compositor closed the screen-cast session before it produced a frame")

        png = _pull_png(int(node["id"]), _remaining(deadline), lambda: closed["seen"])
        if not png and closed["seen"]:
            raise SessionClosed("the compositor closed the screen-cast session mid-capture")
        if not png:
            raise CaptureError("the screen-cast stream produced no frame before the timeout")
        return png
    finally:
        _unsubscribe()
        try:
            _session_call("Stop")
        except GLib.Error:
            # A session the compositor already closed cannot be stopped again,
            # and the capture's own result is what matters here.
            pass


def _pull_png(node_id: int, timeout: float, closed=None) -> bytes:
    """Encode exactly one frame off PipeWire node `node_id` to PNG, in memory.

    `num-buffers=1` plus `pngenc snapshot=true` guarantees a freshly presented
    frame rather than whatever a long-lived pipeline last held. The PNG is pulled
    out of an appsink instead of a filesink so a capture never touches the disk.

    `closed`, when given, is polled for the compositor having closed the session
    underneath this pipeline. Waiting here blocks on GStreamer rather than on a
    main loop, so the default main context is pumped each pass; without that the
    Session.Closed signal that sets `closed` would sit queued until after the
    capture had already been given up on as a plain timeout.
    """
    if closed is not None and closed():
        return b""

    def _encoded(sample: Any) -> bytes:
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            raise CaptureError("could not read the encoded frame out of the pipeline")
        try:
            return bytes(info.data)
        finally:
            buf.unmap(info)

    pipeline = Gst.parse_launch(
        f"pipewiresrc path={node_id} num-buffers=1 ! videoconvert ! "
        "pngenc snapshot=true ! "
        "appsink name=fmsink sync=false max-buffers=1 drop=false"
    )
    sink = pipeline.get_by_name("fmsink")
    pipeline.set_state(Gst.State.PLAYING)
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            _pump_main_context()
            if closed is not None and closed():
                return b""
            # GstApp's typelib is not installed here, so the action signal is
            # used rather than the bound try_pull_sample() method.
            sample = sink.emit("try-pull-sample", 200 * Gst.MSECOND)
            if sample is not None:
                return _encoded(sample)
            msg = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
            _pump_main_context()
            if closed is not None and closed():
                return b""
            if msg is not None and msg.type == Gst.MessageType.ERROR:
                err, _debug = msg.parse_error()
                raise CaptureError(f"capture pipeline failed: {err.message}")
            if msg is not None and msg.type == Gst.MessageType.EOS:
                # pngenc posts EOS straight after the single encoded frame, so a
                # buffer can be waiting here even though the pull above missed it.
                sample = sink.emit("try-pull-sample", 200 * Gst.MSECOND)
                return _encoded(sample) if sample is not None else b""
        return b""
    finally:
        pipeline.set_state(Gst.State.NULL)


# ---------------------------------------------------------------------------
# Route 2 (fallback): org.freedesktop.portal.Screenshot
# ---------------------------------------------------------------------------


def _portal_request_path(bus: Any, token: str) -> str:
    """The request object path the portal WILL create, derived the documented way.

    Predicting it is what makes rule 2 possible: the Response subscription has to
    exist before the method call, because the portal answers in about 100 ms and
    destroys the Request object immediately afterwards.
    """
    sender = bus.get_unique_name().lstrip(":").replace(".", "_")
    return f"{PORTAL_PATH}/request/{sender}/{token}"


def _portal_capture(
    scope: str,
    region: dict[str, int] | None,
    cursor: bool,
    timeout: float,
    bounds: dict[str, Any] | None = None,
) -> tuple[bytes, list[str]]:
    bus = _session_bus()
    deadline = time.monotonic() + timeout
    notes: list[str] = []
    if not cursor:
        notes.append("the portal route always composites the pointer; cursor=false was ignored")

    token = f"fmdeskcap{os.getpid()}_{int(time.monotonic() * 1000) % 1000000}"
    request_path = _portal_request_path(bus, token)

    answer: dict[str, Any] = {}

    # RULE 2: subscribe to the PREDICTED path BEFORE calling Screenshot().
    sub = bus.signal_subscribe(
        PORTAL_BUS,
        PORTAL_REQUEST_IFACE,
        "Response",
        request_path,
        None,
        Gio.DBusSignalFlags.NONE,
        lambda *args: answer.update(zip(("code", "results"), args[5].unpack())),
    )
    try:
        options = {
            "handle_token": GLib.Variant("s", token),
            "interactive": GLib.Variant("b", False),
            "modal": GLib.Variant("b", False),
        }
        try:
            bus.call_sync(
                PORTAL_BUS,
                PORTAL_PATH,
                PORTAL_SCREENSHOT_IFACE,
                "Screenshot",
                GLib.Variant("(sa{sv})", ("", options)),
                None,
                Gio.DBusCallFlags.NONE,
                _call_timeout_ms(deadline),
                None,
            )
        except GLib.Error as err:
            raise CaptureError(f"the desktop portal refused a screenshot: {err.message}") from err

        if not _run_until(lambda: "code" in answer, _remaining(deadline)):
            raise CaptureError("the desktop portal never answered the screenshot request")
        if answer["code"] != 0:
            raise CaptureError(
                f"the desktop portal declined the screenshot (response code {answer['code']})"
            )
        uri = (answer.get("results") or {}).get("uri")
        if not uri:
            raise CaptureError("the desktop portal answered without a screenshot location")
    finally:
        bus.signal_unsubscribe(sub)

    png = _take_portal_file(uri, notes)
    image_width, image_height = png_dimensions(png)
    desktop_width, desktop_height = _desktop_size(bounds)
    rescaled = (image_width, image_height) != (desktop_width, desktop_height)

    if scope == "region":
        assert region is not None
        placed = region_in_image_pixels(region, bounds, image_width, image_height)
        png = resize_png(crop_png(png, placed), region["width"], region["height"])
    else:
        png = resize_png(png, desktop_width, desktop_height)

    if rescaled:
        notes.append(
            f"the portal returned a {image_width}x{image_height} screenshot of a "
            f"{desktop_width}x{desktop_height} desktop, so it was resampled into the "
            "logical pixel space the compositor route uses"
        )
    return png, notes


def _take_portal_file(uri: str, notes: list[str]) -> bytes:
    """Read the portal's output file and remove it.

    The portal alone chooses where a screenshot lands - in practice the captain's
    ~/Pictures. Only the exact file this call was just handed is removed, which
    is what keeps repeated captures from filling his home directory.
    """
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        raise CaptureError(f"the desktop portal returned an unreadable location: {uri}")
    path = Path(unquote(parsed.path))
    try:
        png = path.read_bytes()
    except OSError as err:
        raise CaptureError(f"cannot read the portal's screenshot at {path}: {err}") from err
    try:
        path.unlink()
    except OSError as err:
        notes.append(f"could not remove the portal's temporary file {path}: {err}")
    return png


def _decode_png(png: bytes, purpose: str) -> Any:
    """Decode PNG bytes to a pixbuf, reporting any failure as a CaptureError."""
    _require_gi()
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    try:
        loader.write_bytes(GLib.Bytes.new(png))
        loader.close()
    except GLib.Error as err:
        raise CaptureError(f"could not decode the screenshot for {purpose}: {err.message}") from err
    pixbuf = loader.get_pixbuf()
    if pixbuf is None:
        raise CaptureError(f"could not decode the screenshot for {purpose}")
    return pixbuf


def _encode_png(pixbuf: Any, purpose: str) -> bytes:
    """Re-encode a pixbuf to PNG bytes, reporting any failure as a CaptureError."""
    _require_gi()
    if pixbuf is None:
        raise CaptureError(f"could not resize the screenshot for {purpose}")
    try:
        ok, data = pixbuf.save_to_bufferv("png", [], [])
    except GLib.Error as err:
        raise CaptureError(f"could not re-encode the screenshot after {purpose}: {err.message}") from err
    if not ok:
        raise CaptureError(f"could not re-encode the screenshot after {purpose}")
    return bytes(data)


def downscale_png(png: bytes, max_width: int) -> bytes:
    """Shrink PNG bytes to `max_width`, preserving aspect ratio, in memory.

    A full-display capture is around 210 KB, which is a lot of base64 for the
    agents this serves. A failure here must not lose a capture that already
    succeeded, so every step reports as a CaptureError like the rest of the
    engine rather than as a raw GLib.Error.
    """
    if max_width <= 0:
        raise CaptureError(f"max_width must be positive, got {max_width}")
    pixbuf = _decode_png(png, "downscaling")
    if pixbuf.get_width() <= max_width:
        return png
    height = max(1, round(pixbuf.get_height() * max_width / pixbuf.get_width()))
    return _encode_png(pixbuf.scale_simple(max_width, height, GdkPixbuf.InterpType.BILINEAR), "downscaling")


def resize_png(png: bytes, width: int, height: int) -> bytes:
    """Resample PNG bytes to exactly `width` x `height`, in memory.

    This is what puts the portal route's output in the same pixel space as the
    compositor route's. The portal hands back the raw framebuffer, so without it
    the same call would answer with different dimensions depending on which route
    served it, and coordinates read off one image would not map onto the other.
    """
    if width <= 0 or height <= 0:
        raise CaptureError(f"a resize needs positive dimensions, got {width}x{height}")
    pixbuf = _decode_png(png, "rescaling")
    if (pixbuf.get_width(), pixbuf.get_height()) == (width, height):
        return png
    return _encode_png(pixbuf.scale_simple(width, height, GdkPixbuf.InterpType.BILINEAR), "rescaling")


def crop_png(png: bytes, region: dict[str, int]) -> bytes:
    """Crop PNG bytes to `region`, in memory.

    Needed only on the portal route, which has no region scope of its own.
    """
    pixbuf = _decode_png(png, "cropping")
    if (
        region["x"] + region["width"] > pixbuf.get_width()
        or region["y"] + region["height"] > pixbuf.get_height()
    ):
        raise CaptureError(
            f"region {region['width']}x{region['height']}+{region['x']}+{region['y']} does not fit "
            f"the {pixbuf.get_width()}x{pixbuf.get_height()} screenshot"
        )
    cropped = pixbuf.new_subpixbuf(region["x"], region["y"], region["width"], region["height"])
    return _encode_png(cropped, "cropping")


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def capture(
    scope: str = "screen",
    region: dict[str, int] | None = None,
    cursor: bool = True,
    route: str = "auto",
    timeout: float = DEFAULT_TIMEOUT,
) -> Capture:
    """Capture one still and return it in memory.

    `route="auto"` uses the compositor's own screen-cast API and falls back to
    the desktop portal if that route fails for any reason.

    This is the single owner of region validation. The rectangle's own shape is
    checked first, in its own statement, so a malformed one is refused before any
    compositor call rather than depending on argument evaluation order.

    `timeout` is one end-to-end budget for the whole call. It is shared by the
    close-and-rebuild retry and by both routes, and every D-Bus call is capped by
    what is left of it, so a wedged compositor cannot stack timeouts.
    """
    if scope not in SCOPES:
        raise CaptureError(f"scope must be one of {', '.join(SCOPES)} (window scope is not in this slice)")
    if route not in ROUTES:
        raise CaptureError(f"route must be one of {', '.join(ROUTES)}")
    notes: list[str] = []
    started = time.monotonic()
    deadline = started + timeout

    region = normalize_region(region) if scope == "region" else None
    bounds = display_state(_call_timeout_ms(deadline))
    if region is not None:
        region = fit_region(region, bounds)

    order = ("mutter", "portal") if route == "auto" else (route,)
    failures: list[str] = []
    causes: list[BaseException] = []

    for chosen in order:
        try:
            budget = _remaining(deadline)
            if chosen == "mutter":
                png = _mutter_attempt(scope, region, cursor, budget, bounds)
            else:
                png, portal_notes = _portal_capture(scope, region, cursor, budget, bounds)
                notes.extend(portal_notes)
            elapsed = (time.monotonic() - started) * 1000
            result = Capture(png, chosen, scope, elapsed, notes)
            if failures:
                result.notes.append("fell back after: " + "; ".join(failures))
            return result
        except (CaptureError, *_GLIB_ERRORS) as err:
            # A raw GLib.Error out of GStreamer or D-Bus is a failure of that
            # route, not of the call. Treating it as one is what keeps the
            # fallback reachable when the primary route breaks.
            failures.append(f"{chosen}: {_error_text(err)}")
            causes.append(err)

    if causes and all(isinstance(err, MissingDependency) for err in causes):
        raise MissingDependency("; ".join(failures))
    raise CaptureError("; ".join(failures))


def _mutter_attempt(
    scope: str,
    region: dict[str, int] | None,
    cursor: bool,
    timeout: float,
    bounds: dict[str, Any] | None = None,
) -> bytes:
    """The primary route, retried once when the compositor closes the session.

    A headless RDP session's virtual monitor is rebuilt on reconnect, so a close
    means "build a new session", not "capture is unavailable". The rebuild gets
    what is left of `timeout`, not a fresh copy of it.
    """
    deadline = time.monotonic() + timeout
    try:
        return _mutter_capture(scope, region, cursor, timeout, bounds)
    except SessionClosed:
        return _mutter_capture(scope, region, cursor, _remaining(deadline), bounds)


def probe() -> dict[str, Any]:
    """Report what each route needs and whether it is present, without capturing."""
    report: dict[str, Any] = {"bindings": _GI_IMPORT_ERROR or "ok"}
    for name, value in (
        ("XDG_RUNTIME_DIR", os.environ.get("XDG_RUNTIME_DIR")),
        ("DBUS_SESSION_BUS_ADDRESS", os.environ.get("DBUS_SESSION_BUS_ADDRESS")),
    ):
        report[name] = value or "unset"
    try:
        _require_gst()
        report["gstreamer"] = "ok"
    except (CaptureError, *_GLIB_ERRORS) as err:
        report["gstreamer"] = _error_text(err)
    try:
        report["display"] = display_state()
    except (CaptureError, *_GLIB_ERRORS) as err:
        report["display"] = _error_text(err)
    for label, bus_name, path, iface in (
        ("mutter", MUTTER_BUS, MUTTER_PATH, MUTTER_BUS),
        ("portal", PORTAL_BUS, PORTAL_PATH, PORTAL_SCREENSHOT_IFACE),
    ):
        if _GI_IMPORT_ERROR is not None:
            report[f"{label}_route"] = f"unknown: {_GI_IMPORT_ERROR}"
            continue
        try:
            bus = _session_bus()
            bus.call_sync(
                bus_name,
                path,
                "org.freedesktop.DBus.Properties",
                "GetAll",
                GLib.Variant("(s)", (iface,)),
                None,
                Gio.DBusCallFlags.NONE,
                DBUS_CALL_TIMEOUT_MS,
                None,
            )
            report[f"{label}_route"] = "reachable"
        except (CaptureError, *_GLIB_ERRORS) as err:
            report[f"{label}_route"] = f"unreachable: {_error_text(err)}"
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _write_out(destination: str, png: bytes) -> None:
    if destination == "-":
        sys.stdout.buffer.write(png)
        sys.stdout.buffer.flush()
        return
    Path(destination).write_bytes(png)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-deskcap-lib.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--route", choices=ROUTES, default="auto", help="capture route (default: auto)")
    common.add_argument("--no-cursor", action="store_true", help="leave the pointer out of the capture")
    common.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds to wait for a frame")

    screen = sub.add_parser("screen", parents=[common], help="capture the whole virtual display")
    screen.add_argument("out", help="destination .png path, or - for stdout")

    region = sub.add_parser("region", parents=[common], help="capture an explicit rectangle")
    for axis in ("x", "y", "width", "height"):
        region.add_argument(axis, type=int)
    region.add_argument("out", help="destination .png path, or - for stdout")

    probe_parser = sub.add_parser("probe", help="report route availability without capturing")
    probe_parser.add_argument("--json", action="store_true", help="print the report as JSON")

    args = parser.parse_args(argv)

    if args.command == "probe":
        report = probe()
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            for key, value in report.items():
                print(f"{key}: {json.dumps(value) if isinstance(value, (dict, list)) else value}")
        return 0

    region_arg = None
    if args.command == "region":
        region_arg = {"x": args.x, "y": args.y, "width": args.width, "height": args.height}
    try:
        result = capture(
            scope=args.command,
            region=region_arg,
            cursor=not args.no_cursor,
            route=args.route,
            timeout=args.timeout,
        )
    except MissingDependency as err:
        print(f"capture failed: {err}", file=sys.stderr)
        return 2
    except CaptureError as err:
        print(f"capture failed: {err}", file=sys.stderr)
        return 1
    _write_out(args.out, result.png)
    print(result.summary(), file=sys.stderr)
    for note in result.notes:
        print(f"note: {note}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
