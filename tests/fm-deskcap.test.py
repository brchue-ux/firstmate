#!/usr/bin/env python3
"""Contract unit tests for the desktop-capture engine (bin/fm-deskcap-lib.py).

Everything here runs without a compositor, a session bus or a display. The
guards that matter most are the ones that made earlier attempts at this look
like total failures:

  - the portal request path must be PREDICTED from the bus name, because the
    Response subscription has to exist before the method call;
  - a session the compositor closed must be rebuilt, not reported as a failure;
  - the portal's output file must be removed after it is read, so captures never
    accumulate in the captain's home directory;
  - a close that arrives while a frame is being pulled must still be seen, which
    only happens if the GLib default main context is pumped during the wait;
  - one call gets one deadline, shared by the rebuild and by both routes.

Live capture against the real compositor is not asserted here - it is
docs/verification/desktop-capture.md plus `bin/fm-deskcap-mcp.py --selftest`.
"""
import base64
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin"


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, BIN / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CAP = _load("fm_deskcap_lib", "fm-deskcap-lib.py")

PNG_1X1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000100ffff03000006"
    "00057d13a20000000049454e44ae426082"
)


class FakeBus:
    def __init__(self, unique_name=":1.30893"):
        self._unique_name = unique_name

    def get_unique_name(self):
        return self._unique_name


class PngDimensionsTest(unittest.TestCase):
    def test_reads_ihdr(self):
        self.assertEqual(CAP.png_dimensions(PNG_1X1), (1, 1))

    def test_rejects_non_png(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.png_dimensions(b"not a png at all, definitely not")

    def test_rejects_truncated(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.png_dimensions(PNG_1X1[:10])

    def test_rejects_zero_sized(self):
        zeroed = PNG_1X1[:16] + (0).to_bytes(4, "big") + PNG_1X1[20:]
        with self.assertRaises(CAP.CaptureError):
            CAP.png_dimensions(zeroed)


class RegionValidationTest(unittest.TestCase):
    def test_normalizes_integers(self):
        self.assertEqual(
            CAP.normalize_region({"x": "10", "y": 20, "width": 30, "height": 40}),
            {"x": 10, "y": 20, "width": 30, "height": 40},
        )

    def test_rejects_zero_and_negative_size(self):
        for bad in ({"x": 0, "y": 0, "width": 0, "height": 5}, {"x": 0, "y": 0, "width": 5, "height": -1}):
            with self.assertRaises(CAP.CaptureError):
                CAP.normalize_region(bad)

    def test_rejects_negative_origin(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.normalize_region({"x": -1, "y": 0, "width": 5, "height": 5})

    def test_rejects_missing_fields(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.normalize_region({"x": 0, "y": 0, "width": 5})

    def test_rejects_non_mapping(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.normalize_region(None)

    def test_fit_rejects_region_off_the_desktop(self):
        bounds = {"width": 1920, "height": 1009}
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP.fit_region({"x": 0, "y": 0, "width": 5000, "height": 100}, bounds)
        self.assertIn("1920x1009", str(ctx.exception))

    def test_fit_accepts_a_region_flush_with_the_edge(self):
        bounds = {"width": 1920, "height": 1009}
        region = {"x": 1820, "y": 909, "width": 100, "height": 100}
        self.assertEqual(CAP.fit_region(region, bounds), region)


class RegionInImagePixelsTest(unittest.TestCase):
    """A logical rectangle has to land on the same content in a scaled screenshot."""

    BOUNDS = {"width": 1920, "height": 1080}

    def test_an_unscaled_screenshot_needs_no_conversion(self):
        region = {"x": 100, "y": 50, "width": 300, "height": 200}
        self.assertEqual(CAP.region_in_image_pixels(region, self.BOUNDS, 1920, 1080), region)

    def test_a_doubled_screenshot_doubles_the_rectangle(self):
        self.assertEqual(
            CAP.region_in_image_pixels(
                {"x": 100, "y": 50, "width": 300, "height": 200}, self.BOUNDS, 3840, 2160
            ),
            {"x": 200, "y": 100, "width": 600, "height": 400},
        )

    def test_each_axis_uses_its_own_factor(self):
        self.assertEqual(
            CAP.region_in_image_pixels(
                {"x": 10, "y": 10, "width": 100, "height": 100}, self.BOUNDS, 3840, 1080
            ),
            {"x": 20, "y": 10, "width": 200, "height": 100},
        )

    def test_a_rectangle_flush_with_the_edge_stays_inside_the_screenshot(self):
        placed = CAP.region_in_image_pixels(
            {"x": 1820, "y": 980, "width": 100, "height": 100}, self.BOUNDS, 3840, 2160
        )
        self.assertLessEqual(placed["x"] + placed["width"], 3840)
        self.assertLessEqual(placed["y"] + placed["height"], 2160)
        self.assertEqual((placed["x"], placed["y"]), (3640, 1960))

    def test_a_rectangle_never_collapses_to_nothing(self):
        placed = CAP.region_in_image_pixels(
            {"x": 0, "y": 0, "width": 3, "height": 3}, self.BOUNDS, 96, 54
        )
        self.assertGreaterEqual(placed["width"], 1)
        self.assertGreaterEqual(placed["height"], 1)

    def test_unknown_desktop_bounds_are_refused_rather_than_guessed(self):
        for bad in (None, {}, {"width": 0, "height": 1080}):
            with self.assertRaises(CAP.CaptureError):
                CAP.region_in_image_pixels({"x": 0, "y": 0, "width": 1, "height": 1}, bad, 100, 100)


class PortalRequestPathTest(unittest.TestCase):
    """Rule 2: the Response subscription needs the path BEFORE the call."""

    def test_predicts_the_documented_request_path(self):
        self.assertEqual(
            CAP._portal_request_path(FakeBus(":1.30893"), "fmshot1"),
            "/org/freedesktop/portal/desktop/request/1_30893/fmshot1",
        )

    def test_escapes_every_dot_in_the_bus_name(self):
        self.assertEqual(
            CAP._portal_request_path(FakeBus(":1.2.3"), "tok"),
            "/org/freedesktop/portal/desktop/request/1_2_3/tok",
        )


class PortalFileHygieneTest(unittest.TestCase):
    """The portal picks where it writes; a capture must not leave that behind."""

    def test_reads_then_removes_the_portal_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Screenshot-12.png"
            path.write_bytes(PNG_1X1)
            notes = []
            self.assertEqual(CAP._take_portal_file(path.as_uri(), notes), PNG_1X1)
            self.assertFalse(path.exists(), "the portal's output file was left on disk")
            self.assertEqual(notes, [])

    def test_rejects_a_location_it_cannot_read(self):
        with self.assertRaises(CAP.CaptureError):
            CAP._take_portal_file("https://example.invalid/shot.png", [])

    def test_reports_a_missing_file_clearly(self):
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP._take_portal_file("file:///nonexistent/fm-deskcap/none.png", [])
        self.assertIn("cannot read", str(ctx.exception))


class ClosedSessionRebuildTest(unittest.TestCase):
    """A headless RDP session's virtual monitor comes and goes with the client."""

    def test_rebuilds_once_after_the_compositor_closes_the_session(self):
        calls = []

        def flaky(scope, region, cursor, timeout):
            calls.append(scope)
            if len(calls) == 1:
                raise CAP.SessionClosed("closed")
            return PNG_1X1

        original = CAP._mutter_capture
        CAP._mutter_capture = flaky
        try:
            self.assertEqual(CAP._mutter_attempt("screen", None, True, 1.0), PNG_1X1)
        finally:
            CAP._mutter_capture = original
        self.assertEqual(len(calls), 2, "the capture was not rebuilt after the close")

    def test_a_second_close_is_reported_rather_than_retried_forever(self):
        calls = []

        def always_closed(scope, region, cursor, timeout):
            calls.append(scope)
            raise CAP.SessionClosed("closed")

        original = CAP._mutter_capture
        CAP._mutter_capture = always_closed
        try:
            with self.assertRaises(CAP.SessionClosed):
                CAP._mutter_attempt("screen", None, True, 1.0)
        finally:
            CAP._mutter_capture = original
        self.assertEqual(len(calls), 2)

    def test_the_rebuild_gets_what_is_left_of_the_budget_not_a_fresh_one(self):
        budgets = []

        def flaky(scope, region, cursor, timeout):
            budgets.append(timeout)
            if len(budgets) == 1:
                time.sleep(0.3)
                raise CAP.SessionClosed("closed")
            return PNG_1X1

        original = CAP._mutter_capture
        CAP._mutter_capture = flaky
        try:
            self.assertEqual(CAP._mutter_attempt("screen", None, True, 5.0), PNG_1X1)
        finally:
            CAP._mutter_capture = original
        self.assertEqual(budgets[0], 5.0)
        self.assertLess(budgets[1], budgets[0], "the rebuild restarted the timeout instead of continuing it")


class MainContextPumpTest(unittest.TestCase):
    """Signal callbacks only run while the default main context is iterated."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        CAP._pump_main_context()

    def test_pumping_delivers_a_callback_queued_on_the_default_context(self):
        seen = {"ran": False}

        def mark():
            seen["ran"] = True
            return False

        CAP.GLib.idle_add(mark)
        self.assertFalse(seen["ran"], "a queued callback must not run before the context is iterated")
        CAP._pump_main_context()
        self.assertTrue(seen["ran"], "a queued callback was not delivered by the pump")

    def test_pumping_returns_promptly_when_nothing_is_queued(self):
        started = time.monotonic()
        CAP._pump_main_context()
        self.assertLess(time.monotonic() - started, 1.0)


class FakeMapInfo:
    def __init__(self, data):
        self.data = data


class FakeBuffer:
    def __init__(self, data):
        self.data = data
        self.unmapped = False

    def map(self, _flags):
        return True, FakeMapInfo(self.data)

    def unmap(self, _info):
        self.unmapped = True


class FakeSample:
    def __init__(self, data):
        self.buffer = FakeBuffer(data)

    def get_buffer(self):
        return self.buffer


class FakeMessage:
    def __init__(self, message_type):
        self.type = message_type


class FakeSink:
    """An appsink replaying a scripted series of pull results."""

    def __init__(self, samples):
        self.samples = list(samples)
        self.pulls = 0

    def emit(self, _signal, _timeout_ns):
        self.pulls += 1
        if self.samples:
            return self.samples.pop(0)
        time.sleep(0.02)
        return None


class FakeGstBus:
    def __init__(self, messages):
        self.messages = list(messages)

    def pop_filtered(self, _mask):
        return self.messages.pop(0) if self.messages else None


class FakePipeline:
    def __init__(self, sink, bus):
        self.sink = sink
        self.bus = bus
        self.states = []

    def get_by_name(self, _name):
        return self.sink

    def set_state(self, state):
        self.states.append(state)

    def get_bus(self):
        return self.bus


class FakeGst:
    MSECOND = 1000000
    pipelines: list = []
    next_samples: list = []
    next_messages: list = []

    class State:
        PLAYING = "playing"
        NULL = "null"

    class MessageType:
        ERROR = 1
        EOS = 2

    class MapFlags:
        READ = 1

    @classmethod
    def parse_launch(cls, _description):
        pipeline = FakePipeline(FakeSink(cls.next_samples), FakeGstBus(cls.next_messages))
        cls.pipelines.append(pipeline)
        return pipeline


class ClosedDuringFramePullTest(unittest.TestCase):
    """The window this covers is the one a headless RDP disconnect lands in."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        CAP._pump_main_context()
        FakeGst.pipelines = []
        FakeGst.next_samples = []
        FakeGst.next_messages = []
        self.saved_gst = CAP.Gst
        CAP.Gst = FakeGst

    def tearDown(self):
        CAP.Gst = self.saved_gst
        CAP._pump_main_context()

    def test_a_close_delivered_during_the_pull_ends_the_wait(self):
        closed = {"seen": False}

        def close_it():
            closed["seen"] = True
            return False

        CAP.GLib.idle_add(close_it)
        started = time.monotonic()
        png = CAP._pull_png(7, 30.0, lambda: closed["seen"])
        elapsed = time.monotonic() - started

        self.assertEqual(png, b"", "a closed session must not be reported as a frame")
        self.assertLess(elapsed, 5.0, "the close was not observed until the pull timed out")
        self.assertEqual(len(FakeGst.pipelines), 1, "the pull never reached its wait loop")
        self.assertEqual(FakeGst.pipelines[0].states[-1], FakeGst.State.NULL, "the pipeline was not torn down")

    def test_an_already_closed_session_never_builds_a_pipeline(self):
        self.assertEqual(CAP._pull_png(7, 30.0, lambda: True), b"")
        self.assertEqual(FakeGst.pipelines, [])

    def test_without_a_close_the_pull_still_gives_up_at_its_timeout(self):
        started = time.monotonic()
        self.assertEqual(CAP._pull_png(7, 0.3, lambda: False), b"")
        self.assertLess(time.monotonic() - started, 5.0)

    def test_a_frame_that_lands_with_the_eos_is_returned_not_discarded(self):
        # pngenc posts EOS right after its single frame, so the pull that
        # follows the EOS message is where that frame can show up.
        FakeGst.next_samples = [None, FakeSample(PNG_1X1)]
        FakeGst.next_messages = [FakeMessage(FakeGst.MessageType.EOS)]

        started = time.monotonic()
        png = CAP._pull_png(7, 2.0, None)

        self.assertEqual(png, PNG_1X1, "the frame pulled after EOS was thrown away")
        self.assertLess(time.monotonic() - started, 1.5, "the pull spun on instead of returning the frame")
        self.assertTrue(FakeGst.pipelines[0].sink.samples == [], "the scripted frame was never pulled")

    def test_an_eos_with_no_frame_behind_it_still_gives_up(self):
        FakeGst.next_samples = [None, None]
        FakeGst.next_messages = [FakeMessage(FakeGst.MessageType.EOS)]
        self.assertEqual(CAP._pull_png(7, 2.0, None), b"")

    def test_a_frame_pulled_before_any_message_is_returned(self):
        FakeGst.next_samples = [FakeSample(PNG_1X1)]
        self.assertEqual(CAP._pull_png(7, 2.0, None), PNG_1X1)
        self.assertTrue(FakeGst.pipelines[0].sink.samples == [])


class RecordingBus:
    """A session bus that records D-Bus calls and can fire the stream signal."""

    def __init__(self, node_id=None):
        self.calls = []
        self.node_id = node_id
        self._next_sub = 1

    def call_sync(self, _name, _path, _iface, method, args, _cancellable, _flags, timeout_ms, _extra):
        self.calls.append(
            {"method": method, "args": None if args is None else args.unpack(), "timeout_ms": timeout_ms}
        )
        if method == "CreateSession":
            return CAP.GLib.Variant("(o)", ("/org/gnome/Mutter/ScreenCast/Session/u1",))
        if method in ("RecordArea", "RecordMonitor"):
            return CAP.GLib.Variant("(o)", ("/org/gnome/Mutter/ScreenCast/Session/u1/Stream/u1",))
        return CAP.GLib.Variant("()", ())

    def signal_subscribe(self, name, iface, signal, path, _arg0, _flags, callback):
        sub = self._next_sub
        self._next_sub += 1
        if signal == "PipeWireStreamAdded" and self.node_id is not None:
            node_id = self.node_id

            def fire():
                callback(self, name, path, iface, signal, CAP.GLib.Variant("(ua{sv})", (node_id, {})))
                return False

            CAP.GLib.idle_add(fire)
        return sub

    def signal_unsubscribe(self, _sub):
        return None

    def methods(self):
        return [call["method"] for call in self.calls]

    def args_for(self, method):
        return [call["args"] for call in self.calls if call["method"] == method]


class MutterStreamGeometryTest(unittest.TestCase):
    """What the compositor route asks the compositor to record."""

    TWO_MONITORS = {
        "monitors": [
            {"connector": "DP-1", "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "primary": True},
            {"connector": "DP-2", "x": 1920, "y": 0, "width": 1080, "height": 1200, "scale": 1.0, "primary": False},
        ],
        "primary": {"connector": "DP-1"},
        "width": 3000,
        "height": 1200,
    }

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        CAP._pump_main_context()
        self.bus = RecordingBus(node_id=42)
        self.saved = (CAP._session_bus, CAP._require_gst, CAP.display_state, CAP._pull_png)
        CAP._session_bus = lambda: self.bus
        CAP._require_gst = lambda: None
        CAP.display_state = lambda *_args, **_kwargs: self.TWO_MONITORS
        CAP._pull_png = lambda node_id, timeout, closed=None: PNG_1X1

    def tearDown(self):
        CAP._session_bus, CAP._require_gst, CAP.display_state, CAP._pull_png = self.saved
        CAP._pump_main_context()

    def test_screen_scope_records_the_whole_virtual_desktop(self):
        self.assertEqual(CAP._mutter_capture("screen", None, True, 5.0), PNG_1X1)
        areas = self.bus.args_for("RecordArea")
        self.assertEqual(len(areas), 1, "screen scope did not record an area")
        self.assertEqual(
            tuple(areas[0][:4]),
            (0, 0, 3000, 1200),
            "screen scope recorded something other than the full virtual desktop",
        )
        self.assertNotIn("RecordMonitor", self.bus.methods())

    def test_region_scope_records_exactly_the_requested_rectangle(self):
        region = {"x": 10, "y": 20, "width": 30, "height": 40}
        self.assertEqual(CAP._mutter_capture("region", region, True, 5.0), PNG_1X1)
        self.assertEqual(tuple(self.bus.args_for("RecordArea")[0][:4]), (10, 20, 30, 40))

    def test_the_session_is_started_and_stopped_around_the_capture(self):
        CAP._mutter_capture("screen", None, True, 5.0)
        methods = self.bus.methods()
        self.assertEqual(methods[0], "CreateSession")
        self.assertIn("Start", methods)
        self.assertEqual(methods[-1], "Stop", "the screen-cast session was not torn down")

    def test_no_d_bus_call_outlives_the_remaining_budget(self):
        CAP._mutter_capture("screen", None, True, 1.0)
        for call in self.bus.calls:
            self.assertLessEqual(
                call["timeout_ms"], 1000, f"{call['method']} was given longer than the whole capture budget"
            )


# Loads the engine in a fresh interpreter where `gi` cannot be imported at all,
# so the module-level GLib name is genuinely never bound, then prints what
# probe() reports. That is the machine probe() exists to diagnose, and it cannot
# be reproduced in-process because this interpreter has already imported gi.
PROBE_WITHOUT_GI = """
import importlib.util, json, sys


class BlockGi:
    def find_spec(self, name, path=None, target=None):
        if name == "gi" or name.startswith("gi."):
            raise ImportError("blocked: gir1.2-gst-plugins-base-1.0 is missing")
        return None


sys.meta_path.insert(0, BlockGi())
spec = importlib.util.spec_from_file_location("fm_deskcap_lib", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert not hasattr(module, "GLib"), "the test did not actually unbind GLib"
print(json.dumps(module.probe()))
"""


class ProbeWithoutBindingsTest(unittest.TestCase):
    """probe() has to survive the machine it exists to diagnose."""

    def test_a_broken_gi_import_is_reported_rather_than_raised(self):
        done = subprocess.run(
            [sys.executable, "-c", PROBE_WITHOUT_GI, str(BIN / "fm-deskcap-lib.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(done.returncode, 0, f"probe() crashed without gi:\n{done.stderr}")
        report = json.loads(done.stdout)
        for key in ("bindings", "gstreamer", "display", "mutter_route", "portal_route"):
            self.assertIn(key, report, "probe() dropped a section it is meant to report")
        for key in ("bindings", "gstreamer", "display", "mutter_route", "portal_route"):
            self.assertIn("gir1.2-gst-plugins-base-1.0 is missing", str(report[key]))


class RouteSelectionTest(unittest.TestCase):
    def setUp(self):
        self.saved = (CAP._mutter_attempt, CAP._portal_capture, CAP.display_state)
        CAP.display_state = lambda *_a, **_k: {"width": 1920, "height": 1009, "monitors": [], "primary": {}}

    def tearDown(self):
        CAP._mutter_attempt, CAP._portal_capture, CAP.display_state = self.saved

    def test_auto_prefers_the_compositor_route(self):
        CAP._mutter_attempt = lambda *a: PNG_1X1
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(AssertionError("portal must not be used"))
        result = CAP.capture(scope="screen")
        self.assertEqual(result.route, "mutter")
        self.assertEqual((result.width, result.height), (1, 1))

    def test_auto_falls_back_to_the_portal_and_says_why(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("screen cast refused"))
        CAP._portal_capture = lambda *a: (PNG_1X1, [])
        result = CAP.capture(scope="screen")
        self.assertEqual(result.route, "portal")
        self.assertTrue(any("screen cast refused" in note for note in result.notes))

    def test_auto_falls_back_when_the_primary_route_raises_a_raw_glib_error(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(
            CAP.GLib.Error("no element videoconvert")
        )
        CAP._portal_capture = lambda *a: (PNG_1X1, [])
        result = CAP.capture(scope="screen")
        self.assertEqual(result.route, "portal")
        self.assertTrue(any("videoconvert" in note for note in result.notes))

    def test_a_raw_glib_error_on_a_pinned_route_is_reported_as_a_capture_failure(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.GLib.Error("gst init failed"))
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP.capture(scope="screen", route="mutter")
        self.assertIn("gst init failed", str(ctx.exception))

    def test_the_fallback_continues_the_deadline_instead_of_restarting_it(self):
        budgets = []

        def slow_mutter(scope, region, cursor, timeout):
            budgets.append(timeout)
            time.sleep(0.3)
            raise CAP.CaptureError("screen cast refused")

        def portal(scope, region, cursor, timeout, bounds=None):
            budgets.append(timeout)
            return PNG_1X1, []

        CAP._mutter_attempt = slow_mutter
        CAP._portal_capture = portal
        self.assertEqual(CAP.capture(scope="screen", timeout=5.0).route, "portal")
        self.assertLessEqual(budgets[0], 5.0)
        self.assertLess(budgets[1], budgets[0], "the portal route was handed a fresh budget")

    def test_a_malformed_rectangle_is_refused_before_the_compositor_is_asked(self):
        def refuse(*_a, **_k):
            raise AssertionError("the display layout was read before the rectangle was checked")

        CAP.display_state = refuse
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(AssertionError("no capture must be attempted"))
        with self.assertRaises(CAP.CaptureError):
            CAP.capture(scope="region", region={"x": 0, "y": 0, "width": 0, "height": 10})

    def test_region_validation_is_inside_the_capture_deadline(self):
        seen = {}

        def recording_display_state(timeout_ms=CAP.DBUS_CALL_TIMEOUT_MS):
            seen["timeout_ms"] = timeout_ms
            return {"width": 1920, "height": 1009, "monitors": [], "primary": {}}

        CAP.display_state = recording_display_state
        CAP._mutter_attempt = lambda *a: PNG_1X1
        CAP.capture(scope="region", region={"x": 0, "y": 0, "width": 10, "height": 10}, timeout=1.0)
        self.assertLessEqual(
            seen["timeout_ms"],
            1000,
            "reading the display layout was allowed to outlive the whole capture budget",
        )

    def test_a_pinned_route_does_not_fall_back(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("screen cast refused"))
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(AssertionError("portal must not be used"))
        with self.assertRaises(CAP.CaptureError):
            CAP.capture(scope="screen", route="mutter")

    def test_the_portal_route_is_given_the_desktop_bounds_for_a_region(self):
        seen = {}

        def portal(scope, region, cursor, timeout, bounds=None):
            seen["bounds"] = bounds
            return PNG_1X1, []

        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("no screen cast"))
        CAP._portal_capture = portal
        CAP.capture(scope="region", region={"x": 0, "y": 0, "width": 10, "height": 10})
        self.assertIsNotNone(seen["bounds"], "the portal route cannot rescale without the desktop bounds")
        self.assertEqual((seen["bounds"]["width"], seen["bounds"]["height"]), (1920, 1009))

    def test_a_dependency_failure_on_every_route_is_reported_as_one(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.MissingDependency("no gi"))
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(CAP.MissingDependency("no gi"))
        with self.assertRaises(CAP.MissingDependency):
            CAP.capture(scope="screen")

    def test_a_dependency_failure_on_only_one_route_stays_an_ordinary_failure(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.MissingDependency("no gstreamer"))
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("no portal"))
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP.capture(scope="screen")
        self.assertNotIsInstance(ctx.exception, CAP.MissingDependency)

    def test_both_routes_failing_reports_both(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("no screen cast"))
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("no portal"))
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP.capture(scope="screen")
        self.assertIn("no screen cast", str(ctx.exception))
        self.assertIn("no portal", str(ctx.exception))

    def test_region_scope_reaches_the_route_with_a_normalized_rectangle(self):
        seen = {}

        def record(scope, region, cursor, timeout):
            seen.update({"scope": scope, "region": region})
            return PNG_1X1

        CAP._mutter_attempt = record
        CAP.capture(scope="region", region={"x": "1", "y": 2, "width": 3, "height": 4})
        self.assertEqual(seen["region"], {"x": 1, "y": 2, "width": 3, "height": 4})

    def test_window_scope_is_not_offered_by_this_slice(self):
        with self.assertRaises(CAP.CaptureError) as ctx:
            CAP.capture(scope="window")
        self.assertIn("window", str(ctx.exception))

    def test_an_unknown_route_is_refused(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.capture(scope="screen", route="magic")

    def test_a_route_that_returns_something_other_than_a_png_fails(self):
        CAP._mutter_attempt = lambda *a: b"\x00" * 64
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("no portal"))
        with self.assertRaises(CAP.CaptureError):
            CAP.capture(scope="screen", route="mutter")


class CropTest(unittest.TestCase):
    """The portal has no region scope, so a region there is cropped afterwards."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")

    def _solid_png(self, width, height):
        pixbuf = CAP.GdkPixbuf.Pixbuf.new(CAP.GdkPixbuf.Colorspace.RGB, False, 8, width, height)
        pixbuf.fill(0x336699FF)
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        self.assertTrue(ok)
        return bytes(data)

    def test_crops_to_exactly_the_region(self):
        cropped = CAP.crop_png(self._solid_png(200, 100), {"x": 10, "y": 20, "width": 50, "height": 30})
        self.assertEqual(CAP.png_dimensions(cropped), (50, 30))

    def test_refuses_a_region_larger_than_the_screenshot(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.crop_png(self._solid_png(40, 40), {"x": 0, "y": 0, "width": 80, "height": 10})

    def test_rejects_bytes_that_are_not_a_png(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.crop_png(b"still not a png", {"x": 0, "y": 0, "width": 1, "height": 1})


class DownscaleTest(unittest.TestCase):
    """max_width keeps a full-display capture small for the agents this serves."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")

    def _solid_png(self, width, height):
        pixbuf = CAP.GdkPixbuf.Pixbuf.new(CAP.GdkPixbuf.Colorspace.RGB, False, 8, width, height)
        pixbuf.fill(0x336699FF)
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        self.assertTrue(ok)
        return bytes(data)

    def test_shrinks_to_the_ceiling_and_keeps_the_aspect_ratio(self):
        scaled = CAP.downscale_png(self._solid_png(1920, 1009), 480)
        self.assertEqual(CAP.png_dimensions(scaled), (480, 252))

    def test_a_capture_already_under_the_ceiling_is_returned_unchanged(self):
        original = self._solid_png(100, 50)
        self.assertIs(CAP.downscale_png(original, 400), original)

    def test_a_very_small_ceiling_still_produces_at_least_one_row(self):
        self.assertEqual(CAP.png_dimensions(CAP.downscale_png(self._solid_png(1920, 1009), 1)), (1, 1))

    def test_undecodable_bytes_fail_as_a_capture_error_not_a_raw_glib_error(self):
        # This is the difference between an agent reading a tool error and the
        # MCP client getting an internal error with the capture already lost.
        with self.assertRaises(CAP.CaptureError):
            CAP.downscale_png(b"not a png at all, definitely not", 100)

    def test_a_nonsense_ceiling_is_refused(self):
        with self.assertRaises(CAP.CaptureError):
            CAP.downscale_png(self._solid_png(40, 40), 0)


class PortalRegionScalingTest(unittest.TestCase):
    """The portal hands back the framebuffer, which need not match the logical desktop."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")

    def _marked_png(self, width, height, mark):
        pixbuf = CAP.GdkPixbuf.Pixbuf.new(CAP.GdkPixbuf.Colorspace.RGB, False, 8, width, height)
        pixbuf.fill(0x000000FF)
        pixbuf.new_subpixbuf(mark["x"], mark["y"], mark["width"], mark["height"]).fill(0xFF0000FF)
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        self.assertTrue(ok)
        return bytes(data)

    def _colors(self, png):
        pixbuf = CAP._decode_png(png, "test")
        pixels = pixbuf.get_pixels()
        stride, channels = pixbuf.get_rowstride(), pixbuf.get_n_channels()
        seen = set()
        for row in range(pixbuf.get_height()):
            for col in range(pixbuf.get_width()):
                offset = row * stride + col * channels
                seen.add(tuple(pixels[offset:offset + 3]))
        return seen

    def test_a_region_lands_on_the_same_content_in_a_doubled_screenshot(self):
        bounds = {"width": 200, "height": 100}
        screenshot = self._marked_png(400, 200, {"x": 200, "y": 100, "width": 100, "height": 50})
        placed = CAP.region_in_image_pixels({"x": 100, "y": 50, "width": 50, "height": 25}, bounds, 400, 200)
        cropped = CAP.crop_png(screenshot, placed)
        self.assertEqual(CAP.png_dimensions(cropped), (100, 50))
        self.assertEqual(self._colors(cropped), {(255, 0, 0)}, "the crop did not land on the marked area")

    def test_cropping_the_unconverted_rectangle_would_miss_that_content(self):
        screenshot = self._marked_png(400, 200, {"x": 200, "y": 100, "width": 100, "height": 50})
        stray = CAP.crop_png(screenshot, {"x": 100, "y": 50, "width": 50, "height": 25})
        self.assertNotIn((255, 0, 0), self._colors(stray))


class McpToolArgumentTest(unittest.TestCase):
    """A bad argument must reach the agent as a tool error, not an internal error."""

    def setUp(self):
        if CAP._GI_IMPORT_ERROR is not None:
            self.skipTest("GObject introspection bindings unavailable")
        self.mcp = _load("fm_deskcap_mcp", "fm-deskcap-mcp.py")
        engine = self.mcp.CAPTURE
        # A real decodable PNG, because max_width actually re-encodes the bytes.
        pixbuf = CAP.GdkPixbuf.Pixbuf.new(CAP.GdkPixbuf.Colorspace.RGB, False, 8, 8, 4)
        pixbuf.fill(0x336699FF)
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        self.assertTrue(ok)
        self.png = bytes(data)
        engine.capture = lambda **kwargs: engine.Capture(
            self.png, "mutter", kwargs.get("scope", "screen"), 1.0, []
        )

    def _call(self, arguments):
        return self.mcp.McpServer().handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "desktop_screenshot", "arguments": arguments},
            }
        )

    def test_a_non_numeric_max_width_is_a_tool_error_not_an_internal_error(self):
        reply = self._call({"scope": "screen", "max_width": "half"})
        self.assertNotIn("error", reply, "a bad max_width must not become a JSON-RPC error")
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("max_width", reply["result"]["content"][0]["text"])

    def test_a_structured_max_width_is_a_tool_error_too(self):
        reply = self._call({"scope": "screen", "max_width": [800]})
        self.assertNotIn("error", reply)
        self.assertTrue(reply["result"]["isError"])

    def test_a_zero_max_width_is_refused_rather_than_silently_ignored(self):
        reply = self._call({"scope": "screen", "max_width": 0})
        self.assertNotIn("error", reply)
        self.assertTrue(reply["result"]["isError"])

    def test_a_usable_max_width_shrinks_the_image_it_returns(self):
        reply = self._call({"scope": "screen", "max_width": 4})
        self.assertFalse(reply["result"]["isError"], reply["result"]["content"][0]["text"])
        image = reply["result"]["content"][1]
        self.assertEqual(image["type"], "image")
        self.assertEqual(CAP.png_dimensions(base64.b64decode(image["data"])), (4, 2))

    def test_a_max_width_above_the_capture_leaves_it_alone(self):
        reply = self._call({"scope": "screen", "max_width": 4000})
        self.assertFalse(reply["result"]["isError"])
        image = reply["result"]["content"][1]
        self.assertEqual(CAP.png_dimensions(base64.b64decode(image["data"])), (8, 4))

    def test_no_max_width_returns_the_image_untouched(self):
        reply = self._call({"scope": "screen"})
        self.assertFalse(reply["result"]["isError"])
        self.assertEqual(reply["result"]["content"][1]["type"], "image")


class CliExitStatusTest(unittest.TestCase):
    """The engine's header documents these, and that header is what --help prints."""

    def setUp(self):
        self.saved = CAP.capture
        self.tmp = tempfile.TemporaryDirectory()
        self.out = str(Path(self.tmp.name) / "out.png")

    def tearDown(self):
        CAP.capture = self.saved
        self.tmp.cleanup()

    def _run(self, argv):
        with contextlib.redirect_stderr(io.StringIO()):
            return CAP.main(argv)

    def test_a_written_capture_exits_zero(self):
        CAP.capture = lambda **kwargs: CAP.Capture(PNG_1X1, "mutter", "screen", 1.0, [])
        self.assertEqual(self._run(["screen", self.out]), 0)
        self.assertTrue(Path(self.out).exists())

    def test_a_capture_that_failed_on_every_route_exits_one(self):
        CAP.capture = lambda **kwargs: (_ for _ in ()).throw(CAP.CaptureError("no route worked"))
        self.assertEqual(self._run(["screen", self.out]), 1)
        self.assertFalse(Path(self.out).exists())

    def test_a_missing_runtime_dependency_exits_two(self):
        CAP.capture = lambda **kwargs: (_ for _ in ()).throw(CAP.MissingDependency("install python3-gi"))
        self.assertEqual(self._run(["screen", self.out]), 2)
        self.assertFalse(Path(self.out).exists())


class MonitorResolutionTest(unittest.TestCase):
    """Connector -> current mode, from the DisplayConfig reply shape."""

    SPECS = [
        (("Meta-0", "MetaVendor", "Virtual remote monitor", "0x0a"),
         [("1920x1009@60", 1920, 1009, 60.0, 1.0, [1.0], {"is-current": True})],
         {}),
        (("DP-1", "Vendor", "Panel", "0x0b"),
         [("2560x1440@60", 2560, 1440, 60.0, 1.0, [1.0], {}),
          ("1920x1080@60", 1920, 1080, 60.0, 1.0, [1.0], {"is-current": True})],
         {}),
    ]

    def test_picks_the_current_mode(self):
        self.assertEqual(
            CAP.monitors_for(self.SPECS, ["DP-1"]),
            [{"connector": "DP-1", "width": 1920, "height": 1080}],
        )

    def test_preserves_the_requested_order_and_drops_unknown_connectors(self):
        self.assertEqual(
            [m["connector"] for m in CAP.monitors_for(self.SPECS, ["DP-1", "HDMI-9", "Meta-0"])],
            ["DP-1", "Meta-0"],
        )

    def test_falls_back_to_the_first_mode_when_none_is_current(self):
        specs = [(("X-1", "v", "d", "0x0"), [("m", 800, 600, 60.0, 1.0, [1.0], {})], {})]
        self.assertEqual(CAP.monitors_for(specs, ["X-1"])[0]["width"], 800)


if __name__ == "__main__":
    unittest.main(verbosity=1)
