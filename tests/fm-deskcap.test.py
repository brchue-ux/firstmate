#!/usr/bin/env python3
"""Contract unit tests for the desktop-capture engine (bin/fm-deskcap-lib.py).

Everything here runs without a compositor, a session bus or a display. The
guards that matter most are the ones that made earlier attempts at this look
like total failures:

  - the portal request path must be PREDICTED from the bus name, because the
    Response subscription has to exist before the method call;
  - a session the compositor closed must be rebuilt, not reported as a failure;
  - the portal's output file must be removed after it is read, so captures never
    accumulate in the captain's home directory.

Live capture against the real compositor is not asserted here - it is
docs/verification/desktop-capture.md plus `bin/fm-deskcap-mcp.py --selftest`.
"""
import importlib.util
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
        import tempfile

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


class RouteSelectionTest(unittest.TestCase):
    def setUp(self):
        self.saved = (CAP._mutter_attempt, CAP._portal_capture, CAP.display_state)
        CAP.display_state = lambda: {"width": 1920, "height": 1009, "monitors": [], "primary": {}}

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

    def test_a_pinned_route_does_not_fall_back(self):
        CAP._mutter_attempt = lambda *a: (_ for _ in ()).throw(CAP.CaptureError("screen cast refused"))
        CAP._portal_capture = lambda *a: (_ for _ in ()).throw(AssertionError("portal must not be used"))
        with self.assertRaises(CAP.CaptureError):
            CAP.capture(scope="screen", route="mutter")

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
