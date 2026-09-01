# Desktop capture

Firstmate ships an MCP server that hands an agent a still PNG of the captain's real desktop.
It is a general-purpose desktop capability, separate from any terminal-workspace screenshot tool, and it works whether or not a terminal workspace is running.

Two scopes are available: `screen`, the whole virtual display, and `region`, an explicit `x`/`y`/`width`/`height` rectangle in display pixels.
Per-window capture is not available, because GNOME Shell denies ordinary callers the window ids it would need.

## Setup

The server needs no installation and no new packages on a GNOME Wayland session that already has `python3-gi`, `gstreamer1.0-pipewire`, and `gstreamer1.0-plugins-good`.
Check the session before registering it:

```sh
bin/fm-deskcap-mcp.py --probe
```

Register it with any MCP client that speaks stdio:

```json
{
  "desktop": {
    "type": "stdio",
    "command": "python3",
    "args": ["<firstmate>/bin/fm-deskcap-mcp.py"],
    "env": {}
  }
}
```

The server needs `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` for the captain's session and nothing else.
A client that scrubs the environment must pass those two through in `env`.
No `WAYLAND_DISPLAY`, no `DISPLAY`, and no desktop session inheritance are required, so an agent launched over SSH can capture.

## The tool

`desktop_screenshot` returns a PNG image block plus one line of text naming the size, byte count, latency, and route.

| Argument | Meaning |
| --- | --- |
| `scope` | `screen` (default) or `region` |
| `x`, `y`, `width`, `height` | the rectangle, required for `scope="region"` |
| `cursor` | composite the pointer into the capture; default true |
| `max_width` | optional downscale ceiling, aspect ratio preserved |
| `route` | `auto` (default), `mutter`, or `portal`; pin one only to diagnose it |

## The two routes

`mutter` is the primary route and uses `org.gnome.Mutter.ScreenCast`, the compositor's own screen-cast API.
It needs no permission dialog, it is the only route with a native region scope, and it never touches the disk.

`portal` is the fallback and uses `org.freedesktop.portal.Screenshot`.
It captures the whole display only, so a region is cropped afterwards, and the portal alone chooses where it writes its file.
The server reads those bytes back and then removes that exact file, so repeated captures do not accumulate in the captain's home directory.

`auto` tries the compositor route and falls back to the portal, recording in the reply's text why it fell back.
Both routes are implemented from the start rather than the fallback being retrofitted, because nothing in the compositor's screen-cast API performs a permission check today, and a future GNOME release that adds one would close the primary route without warning.

## Limits

- No per-window scope.
- Coordinates and returned images are in logical pixels, the space the compositor's own screen-cast API works in.
  Both routes answer the same call with the same area at the same pixel dimensions, so a coordinate read off one route's image maps onto the other's.
  That is enforced after the capture rather than assumed of either route: whichever route served the call, the result is resampled to the size that was asked for, since under non-unity scaling both the compositor and the portal can return a larger image.
  The reply's text says so on any call where resampling happened, whichever route produced the image.
  On the captain's single output at scale 1.0 the sizes already match, so nothing is resampled and nothing is even decoded to check.
  This is checked by unit tests over the conversions only, because no scaled display has been available to capture from; see [verification/desktop-capture.md](verification/desktop-capture.md).
- Any call is refused rather than answered with the wrong content when the image a route produced is not the requested rectangle at a uniform factor, which is what a screenshot covering only one monitor out of several would look like.
  That applies to both scopes and both routes, so a mismatch is reported as unreconcilable instead of being stretched into distorted content.
- Reading the display layout is not required for a whole-screen capture on the `portal` route.
  If that layout cannot be read, the screenshot still comes back, with a note saying its dimensions were not reconciled to logical pixels; only a region call fails, because there is nothing to validate the rectangle against.
- Rotated outputs are not supported.
  The desktop bounds this server derives do not swap axes for a rotated monitor the way the compositor does, so on a rotated display both scopes would work from the wrong geometry.
  No rotated display has been tested; treat a rotated output as out of scope rather than as expected to work.
- The `portal` route always composites the pointer, so `cursor: false` is ignored there and the reply says so.
- A region must fit inside the desktop; one that does not is refused rather than clamped.
- A blanked or idle display captures as a genuinely black image on both routes.
  That is the screen's real content, not a failed capture, and neither route can wake the display.
- The server is stateless between calls: each capture builds and tears down its own screen-cast session, which costs a fraction of a second and in exchange can never serve a stale frame or outlive a virtual monitor that went away.
- Latency is a range, not a fixed figure, because it grows with the size of the display being captured.
  The captain's virtual output is sized by whatever his RDP client asks for, so it changes between his sessions and the figures move with it.
  Which route is quicker for a given scope is not the same on both, and a region on the fallback route can cost more than a whole display, because that route screenshots the whole framebuffer and then crops it.
  The measured table in [verification/desktop-capture.md](verification/desktop-capture.md) records all four cases with the display size and date they were taken on.

Current measured behavior is recorded in [verification/desktop-capture.md](verification/desktop-capture.md), reproducible with `bin/fm-deskcap-mcp.py --selftest`.
