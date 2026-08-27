#!/usr/bin/env python3
"""MCP stdio server exposing still desktop capture to agents.

This is the AGENT-FACING half of firstmate's desktop-capture tool. It speaks
MCP over stdin/stdout using only the Python standard library and does no capture
of its own: every compositor interaction lives in bin/fm-deskcap-lib.py, whose
header owns the routes, the D-Bus handshake rules and the headless-session
reasoning.

One tool, `desktop_screenshot`, with two scopes:
  screen  the whole virtual display
  region  an explicit x/y/width/height rectangle
Per-window capture is deliberately absent from this slice.

It returns a real PNG as an MCP image block, so an agent can look at the
captain's actual screen rather than at a description of it. Nothing is written
into the captain's home directory.

Register it alongside any other stdio MCP server:

  {"desktop": {"type": "stdio", "command": "python3",
               "args": ["<firstmate>/bin/fm-deskcap-mcp.py"], "env": {}}}

The server needs XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS for the captain's
session and nothing else; a client that scrubs the environment must pass those
two through in `env`.

CLI:
  fm-deskcap-mcp.py               serve MCP on stdin/stdout
  fm-deskcap-mcp.py --selftest    capture both scopes for real and report
  fm-deskcap-mcp.py --probe       report route availability without capturing

Exit status: 0 success, 1 a selftest capture failed, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable

SERVER_NAME = "firstmate-desktop-capture"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

INSTRUCTIONS = (
    "Still capture of the captain's real desktop. Call desktop_screenshot with "
    "scope 'screen' for the whole display, or scope 'region' with x/y/width/height "
    "for one rectangle. It returns a PNG you can look at. There is no per-window "
    "scope, and nothing here can change what is on screen."
)


def _load_capture_module() -> Any:
    path = Path(__file__).resolve().parent / "fm-deskcap-lib.py"
    spec = importlib.util.spec_from_file_location("fm_deskcap_lib", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load the capture engine at {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CAPTURE = _load_capture_module()


def _tool_definitions() -> list[dict[str, Any]]:
    return [
        {
            "name": "desktop_screenshot",
            "description": (
                "Capture a still PNG of the captain's live desktop and return it as an "
                "image. scope='screen' captures the whole virtual display; scope='region' "
                "captures the rectangle given by x, y, width and height. Per-window capture "
                "is not available. Typical latency is about 100 ms."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "scope": {
                        "type": "string",
                        "enum": list(CAPTURE.SCOPES),
                        "default": "screen",
                        "description": "What to capture: the whole display, or one rectangle.",
                    },
                    "x": {"type": "integer", "minimum": 0, "description": "Region left edge, in pixels. Required for scope='region'."},
                    "y": {"type": "integer", "minimum": 0, "description": "Region top edge, in pixels. Required for scope='region'."},
                    "width": {"type": "integer", "minimum": 1, "description": "Region width, in pixels. Required for scope='region'."},
                    "height": {"type": "integer", "minimum": 1, "description": "Region height, in pixels. Required for scope='region'."},
                    "cursor": {
                        "type": "boolean",
                        "default": True,
                        "description": "Composite the mouse pointer into the capture.",
                    },
                    "max_width": {
                        "type": "integer",
                        "minimum": 1,
                        "description": (
                            "Optional. Downscale the result so it is at most this wide, "
                            "preserving aspect ratio. Useful for keeping a full-display "
                            "capture small; omit for full resolution."
                        ),
                    },
                    "route": {
                        "type": "string",
                        "enum": list(CAPTURE.ROUTES),
                        "default": "auto",
                        "description": (
                            "Capture route. 'auto' uses the compositor's screen-cast API and "
                            "falls back to the desktop portal. Pin a route only when "
                            "diagnosing one of them."
                        ),
                    },
                },
                "required": [],
                "additionalProperties": False,
            },
        }
    ]


def tool_desktop_screenshot(arguments: dict[str, Any]) -> list[dict[str, Any]]:
    scope = arguments.get("scope") or "screen"
    region = None
    if scope == "region":
        missing = [k for k in ("x", "y", "width", "height") if arguments.get(k) is None]
        if missing:
            raise CAPTURE.CaptureError(
                "scope 'region' needs " + ", ".join(missing) + "; give the rectangle in pixels"
            )
        region = {k: arguments[k] for k in ("x", "y", "width", "height")}

    result = CAPTURE.capture(
        scope=scope,
        region=region,
        cursor=bool(arguments.get("cursor", True)),
        route=arguments.get("route") or "auto",
    )
    png, width, height = result.png, result.width, result.height
    max_width = arguments.get("max_width")
    if max_width and width > int(max_width):
        png = _downscale_png(png, int(max_width))
        width, height = CAPTURE.png_dimensions(png)

    summary = (
        f"{scope} capture: {width}x{height} PNG, {len(png)} bytes, "
        f"{result.elapsed_ms:.0f} ms, via {result.route}"
    )
    for note in result.notes:
        summary += f"\nnote: {note}"
    return [
        {"type": "text", "text": summary},
        {"type": "image", "data": base64.b64encode(png).decode("ascii"), "mimeType": "image/png"},
    ]


def _downscale_png(png: bytes, max_width: int) -> bytes:
    """Shrink PNG bytes to `max_width`, preserving aspect ratio, in memory."""
    gdk, glib = CAPTURE.GdkPixbuf, CAPTURE.GLib
    loader = gdk.PixbufLoader.new_with_type("png")
    loader.write_bytes(glib.Bytes.new(png))
    loader.close()
    pixbuf = loader.get_pixbuf()
    if pixbuf is None:
        raise CAPTURE.CaptureError("could not decode the capture for downscaling")
    height = max(1, round(pixbuf.get_height() * max_width / pixbuf.get_width()))
    scaled = pixbuf.scale_simple(max_width, height, gdk.InterpType.BILINEAR)
    ok, data = scaled.save_to_bufferv("png", [], [])
    if not ok:
        raise CAPTURE.CaptureError("could not re-encode the downscaled capture")
    return bytes(data)


TOOLS = {"desktop_screenshot": tool_desktop_screenshot}


class McpServer:
    """Newline-delimited JSON-RPC 2.0, the shape MCP stdio clients speak."""

    def __init__(self) -> None:
        self.protocol_version = DEFAULT_PROTOCOL_VERSION

    def handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        method = message.get("method")
        message_id = message.get("id")
        is_notification = message_id is None

        try:
            if method == "initialize":
                result = self._initialize(message.get("params") or {})
            elif method in ("notifications/initialized", "initialized"):
                return None
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": _tool_definitions()}
            elif method == "tools/call":
                result = self._call_tool(message.get("params") or {})
            elif method in ("resources/list", "prompts/list"):
                # Not in the declared capabilities, but some clients probe anyway.
                key = "resources" if method.startswith("resources") else "prompts"
                result = {key: []}
            elif is_notification:
                return None
            else:
                return _rpc_error(message_id, -32601, f"unknown method: {method}")
        except CAPTURE.CaptureError as err:
            if is_notification:
                return None
            if method == "tools/call":
                return _rpc_result(message_id, _tool_error(str(err)))
            return _rpc_error(message_id, -32000, str(err))
        except Exception as err:  # noqa: BLE001 - a tool bug must not kill the server
            if is_notification:
                return None
            return _rpc_error(message_id, -32603, f"{type(err).__name__}: {err}")

        if is_notification:
            return None
        return _rpc_result(message_id, result)

    def _initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        requested = params.get("protocolVersion")
        if requested in SUPPORTED_PROTOCOL_VERSIONS:
            self.protocol_version = requested
        return {
            "protocolVersion": self.protocol_version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        }

    def _call_tool(self, params: dict[str, Any]) -> dict[str, Any]:
        handler = TOOLS.get(params.get("name"))
        if handler is None:
            raise CAPTURE.CaptureError(f"unknown tool: {params.get('name')}")
        return {"content": handler(params.get("arguments") or {}), "isError": False}

    def serve(self, stdin: Iterable[str], stdout: Any) -> None:
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError as err:
                _write(stdout, _rpc_error(None, -32700, f"parse error: {err}"))
                continue
            if isinstance(message, list):
                # Batches left the spec in 2025-06-18; older clients still send them.
                for response in filter(None, (self.handle(item) for item in message)):
                    _write(stdout, response)
                continue
            if not isinstance(message, dict):
                _write(stdout, _rpc_error(None, -32600, "invalid request"))
                continue
            response = self.handle(message)
            if response is not None:
                _write(stdout, response)


def _rpc_result(message_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def _rpc_error(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def _tool_error(message: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": message}], "isError": True}


def _write(stream: Any, payload: dict[str, Any]) -> None:
    stream.write(json.dumps(payload) + "\n")
    stream.flush()


def _selftest() -> int:
    """Capture both scopes for real and report what came back."""
    print("# tools")
    for tool in _tool_definitions():
        print(f"- {tool['name']}")
    failures = 0
    cases: list[tuple[str, dict[str, Any]]] = [
        ("screen", {"scope": "screen"}),
        ("region", {"scope": "region", "x": 0, "y": 0, "width": 320, "height": 240}),
    ]
    for route in CAPTURE.ROUTES:
        for label, arguments in cases:
            call = dict(arguments, route=route)
            print(f"\n# {label} via {route}")
            try:
                content = tool_desktop_screenshot(call)
            except CAPTURE.CaptureError as err:
                print(f"failed: {err}")
                failures += 1
                continue
            print(content[0]["text"])
            png = base64.b64decode(content[1]["data"])
            out = Path(tempfile.gettempdir()) / f"fm-deskcap-selftest-{label}-{route}.png"
            out.write_bytes(png)
            print(f"saved {out}")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-deskcap-mcp.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--selftest", action="store_true", help="capture both scopes for real and report")
    parser.add_argument("--probe", action="store_true", help="report route availability without capturing")
    args = parser.parse_args(argv)

    if args.probe:
        print(json.dumps(CAPTURE.probe(), indent=2))
        return 0
    if args.selftest:
        return _selftest()

    McpServer().serve(sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
