# Verification: desktop still capture

Active evidence for the guarantees in [../desktop-capture.md](../desktop-capture.md).
Reproduce the live part with `bin/fm-deskcap-mcp.py --selftest`; the hermetic part is `tests/fm-deskcap.test.sh`.

Machine and date: `homeserver`, Ubuntu 26.04 LTS, GNOME Shell / Mutter 50.1, on 2026-08-27.
The session under test is a headless GNOME Remote Login (RDP) Wayland session with one synthetic 1920x1009 monitor on connector `Meta-0` and no physical monitor connected.

## Both routes reach the session

```
$ bin/fm-deskcap-lib.py probe
bindings: ok
XDG_RUNTIME_DIR: /run/user/1000
DBUS_SESSION_BUS_ADDRESS: unix:path=/run/user/1000/bus
gstreamer: ok
display: {"monitors": [{"connector": "Meta-0", "x": 0, "y": 0, "width": 1920, "height": 1009, "scale": 1.0, "primary": true}], ... "width": 1920, "height": 1009}
mutter_route: reachable
portal_route: reachable
```

## Both scopes produce real pixels on both routes

Six captures through the MCP tool, both scopes against each of `auto`, `mutter`, and `portal`:

```
$ bin/fm-deskcap-mcp.py --selftest
# screen via auto     screen capture: 1920x1009 PNG, 216780 bytes, 123 ms, via mutter
# region via auto     region capture: 320x240 PNG, 19004 bytes, 44 ms, via mutter
# screen via mutter   screen capture: 1920x1009 PNG, 213910 bytes, 95 ms, via mutter
# region via mutter   region capture: 320x240 PNG, 19034 bytes, 50 ms, via mutter
# screen via portal   screen capture: 1920x1009 PNG, 245313 bytes, 94 ms, via portal
# region via portal   region capture: 320x240 PNG, 21339 bytes, 145 ms, via portal
```

Content was checked by sampling pixels rather than by trusting the file size, since a blank or black frame is also a valid non-empty PNG.
A full-display capture sampled every 7th pixel yielded 796 distinct colors with the most common at 44% of samples, and the equivalent portal capture yielded 777 with the most common at 37%.
A 380x940 region over the same area of the screen yielded 309 distinct colors on the compositor route and 310 on the portal route, agreeing on the same three most-common values.
Two captures of that region, one per route, were also read visually and show the same live desktop content.

## Latency

Twenty captures per case, end to end through `capture()`, on an otherwise busy machine:

```
screen mutter n=20 min=62ms median=70ms p95=92ms max=95ms
region mutter n=20 min=35ms median=45ms p95=53ms max=57ms
screen portal n=20 min=47ms median=60ms p95=71ms max=72ms
region portal n=20 min=64ms median=69ms p95=96ms max=99ms
```

## The portal route leaves nothing in the captain's home

The portal chooses where its screenshot lands, in practice `~/Pictures`.
Across roughly 40 portal captures during this verification, no file was added:

```
$ find ~/Pictures -newermt '2026-08-27 10:20' -printf '%T+ %p\n'
2026-08-27+10:56:02 /home/bchue/Pictures
2026-08-27+10:23:30 /home/bchue/Pictures/Screenshot-12.png
```

The only listed file predates every capture above, and the directory's own timestamp is the expected trace of files being created and removed again.

A later sweep, taken after the display had blanked, returned an all-black 1920x1009 PNG on both routes.
Both routes agreeing on black while the compositor route's screen cast still succeeded is the expected reading of a blanked display rather than a failed capture or a torn-down monitor.

## What is not verified here

- The rebuild after the compositor closes a screen-cast session is covered by unit tests over the retry contract, not by a real RDP disconnect and reconnect.
  A live disconnect test needs the captain's own client and was not performed.
- Multiple monitors, non-unity scaling, and non-Meta connectors are untested, because this session has one virtual output at scale 1.0.
  Both routes take `screen` scope as the full virtual desktop bounds by construction, the compositor route through `RecordArea(0, 0, width, height)`, so the two routes cannot disagree about what `screen` means on a multi-monitor layout.
  What remains unverified there is the geometry itself: the connector and mode resolution that computes those bounds is unit-tested against a two-monitor reply shape, but no real multi-monitor capture has been taken.
  Non-unity scaling is likewise unverified, and `screen` scope captures in logical pixels, so a scaled monitor would not be captured at its native resolution.
- The portal route's rescaling of a region into the screenshot's own pixel space has never run against a real scaled display, and cannot be exercised on this machine at all: its single virtual output is at scale 1.0, where the screenshot's dimensions equal the desktop bounds and the conversion is the identity.
  It is covered only by unit tests over the coordinate conversion, which pin the identity case, a 2.0 factor, a non-square factor, and clamping at the far edge.
  No capture from a scaled display was taken, so whether the portal really hands back the physical framebuffer on such a display is assumed from its documented behavior rather than observed here.
- Long-lived behavior is untested beyond back-to-back captures; the longest run here was the 80-capture latency sweep above.
- The compositor-route `screen` figures above were measured while that route recorded the primary monitor by connector.
  It now records the full virtual desktop bounds instead, which is the same 1920x1009 rectangle on this single-output session, but the sweep has not been re-run since that change.
