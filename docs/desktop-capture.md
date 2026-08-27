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
- Coordinates are logical pixels, the space the compositor's own screen-cast API works in.
  `screen` scope captures the whole virtual desktop on both routes, so under non-unity display scaling the result is not the monitor's native resolution.
  A region is rescaled into the portal's screenshot before cropping, so both routes return the same area for the same rectangle even when that screenshot is the larger physical framebuffer; the reply's text says so when a rescale happened.
  On the captain's single output at scale 1.0 no rescaling occurs and the two spaces are the same thing.
  This is checked by unit tests over the conversion only, because no scaled display has been available to capture from; see [verification/desktop-capture.md](verification/desktop-capture.md).
- The `portal` route always composites the pointer, so `cursor: false` is ignored there and the reply says so.
- A region must fit inside the desktop; one that does not is refused rather than clamped.
- A blanked or idle display captures as a genuinely black image on both routes.
  That is the screen's real content, not a failed capture, and neither route can wake the display.
- The server is stateless between calls: each capture builds and tears down its own screen-cast session, which costs roughly 100 ms and in exchange can never serve a stale frame or outlive a virtual monitor that went away.

Current measured behavior is recorded in [verification/desktop-capture.md](verification/desktop-capture.md), reproducible with `bin/fm-deskcap-mcp.py --selftest`.
