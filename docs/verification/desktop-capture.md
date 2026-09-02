# Verification: desktop still capture

Active evidence for the guarantees in [../desktop-capture.md](../desktop-capture.md).
Reproduce the live part with `bin/fm-deskcap-mcp.py --selftest`; the hermetic part is `tests/fm-deskcap.test.sh`.
That self-check removes its captures once it has captured everything it asked for, so add `--keep-captures` to keep the PNGs for inspection.

Machine and date: `homeserver`, Ubuntu 26.04 LTS, GNOME Shell / Mutter 50.1, on 2026-08-27, with the latency section re-measured on 2026-09-01.
The session under test is a headless GNOME Remote Login (RDP) Wayland session with one synthetic monitor on connector `Meta-0` and no physical monitor connected.
That monitor's size is whatever the captain's RDP client asks for, so it differs between the two dates: 1920x1009 on 2026-08-27 and 3440x1369 on 2026-09-01.
It is unrotated and at scale 1.0 on both.

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

Re-measured on 2026-09-01 against the current code, after the route reconciliation and the shared-boundary size normalization were added.
These figures describe that code, not the original implementation.
The captain's virtual output follows his RDP client's size and was 3440x1369 at this measurement rather than the 1920x1009 recorded above, so the whole-display rows cover about 2.4 times as many pixels as the earlier sweep did and are not comparable with it.

Twenty captures per case, end to end through `capture()`, on an otherwise busy machine:

```
screen mutter n=20 min=130ms median=144ms p95=160ms max=166ms
region mutter n=20 min=46ms median=52ms p95=64ms max=78ms
screen portal n=20 min=145ms median=154ms p95=160ms max=167ms
region portal n=20 min=191ms median=201ms p95=208ms max=239ms
```

Every one of those 80 captures came back at the size the call asked for, 3440x1369 for `screen` and 380x940 for `region`, on both routes.
None carried a resampling note, which is the observable form of the size normalization being a no-op on an unscaled output.

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

## A pinned compositor route sometimes finds no frame on a static screen

Measured on 2026-09-02 against a substitute desktop, not the captain's own: a nested headless `gnome-shell` with a 1280x720 virtual monitor and `xdg-desktop-portal-gnome` on a private session bus.
That desktop is completely static, with nothing on it that repaints.

Twelve captures pinned to `--route mutter` at `region` scope produced one failure reporting that the stream produced no frame; twelve pinned `screen` captures at the same time produced none.
The same failure appeared twice more during MCP stdio sessions against that desktop.
Under the default `auto` route it was never user-visible: fifteen region calls with the portal available were all served, none of them needing the fallback.

This could NOT be reproduced against the captain's real session, because that session is disconnected and its virtual monitor is torn down, so live capture cannot be run at all right now.
Whether his real display is affected is therefore unknown, and nothing here should be read as evidence that it is or is not.

What changed in response is only the cost: the compositor route now waits `FIRST_FRAME_SECONDS` for its first frame instead of the caller's whole end-to-end deadline, so the fallback starts within about two seconds rather than after fifteen, with the rest of the budget still to spend.
The underlying reason the compositor withholds the frame was deliberately not investigated.
The short wait and the pinned route's failure message are covered hermetically by `tests/fm-deskcap.test.py`, which drives `capture()` against a frame pull that never yields.

## What is not verified here

- The rebuild after the compositor closes a screen-cast session is covered by unit tests over the retry contract, not by a real RDP disconnect and reconnect.
  A live disconnect test needs the captain's own client and was not performed.
- Multiple monitors, non-unity scaling, and non-Meta connectors are untested, because this session has one virtual output at scale 1.0.
  Both routes take `screen` scope as the full virtual desktop bounds by construction, the compositor route through `RecordArea(0, 0, width, height)`, so the two routes cannot disagree about what `screen` means on a multi-monitor layout.
  What remains unverified there is the geometry itself: the connector and mode resolution that computes those bounds is unit-tested against a two-monitor reply shape, but no real multi-monitor capture has been taken.
  Non-unity scaling is likewise unverified, and captures are returned in logical pixels, so a scaled monitor would not be captured at its native resolution.
- No capture from a scaled display was taken, and none can be taken here: this session's single virtual output is at scale 1.0, where both routes already return the size that was asked for and every conversion below is the identity.
  That covers both halves of the reconciliation, the region mapping into the screenshot's pixel space and the resampling of a result back to the size the call asked for, neither of which has ever run with a factor other than 1.0 against a real compositor.
  Both are covered only by unit tests over the conversions, which pin the identity case, a 2.0 factor, clamping at the far edge, the refusal of a non-uniform factor, and the rounding of a fractional scale.
  The size guarantee no longer rests on an assumption about what either route returns: whatever comes back is resampled to the expected size at a shared boundary, so neither the portal's framebuffer behavior nor Mutter's choice of screen-cast stream size has to be predicted.
  What is still assumed rather than observed is only that resampling a larger image down is an acceptable substitute for a native-resolution capture, which no scaled display was available to judge.
- Rotated outputs are not supported and were not tested.
  The bounds this server derives do not swap axes for a rotated monitor the way the compositor does, so rotated geometry is a known gap rather than an untested-but-expected-to-work case.
  This session's virtual output is unrotated, so no rotated capture was attempted.
- Long-lived behavior is untested beyond back-to-back captures; the longest run here was the 80-capture latency sweep above.
- The pixel-content sampling and the `~/Pictures` hygiene check above are from the 2026-08-27 session at 1920x1009 and were not repeated during the 2026-09-01 latency re-measurement.
  That later sweep did confirm the file hygiene incidentally: its 40 portal captures added nothing to `~/Pictures`, whose newest entry is still the 2026-08-27 file listed above.
