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

  --keep-captures                 keep the selftest's PNGs instead of removing
                                  them. A selftest writes pictures of the
                                  captain's live desktop, so a run that captured
                                  everything it asked for deletes them again;
                                  they are kept only for a failed run or when
                                  this flag asks for them.

Exit status: 0 success, 1 a selftest capture failed or its captures could not be
removed, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
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
                "is not available. A capture takes a fraction of a second, and takes longer "
                "the larger the captain's display is, which changes between his remote "
                "sessions."
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
    if arguments.get("max_width") is not None:
        try:
            max_width = int(arguments["max_width"])
        except (TypeError, ValueError) as err:
            raise CAPTURE.CaptureError("max_width must be an integer number of pixels") from err
        png = CAPTURE.downscale_png(png, max_width)
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


TOOLS = {"desktop_screenshot": tool_desktop_screenshot}


class InvalidParams(Exception):
    """A request whose `params` are the wrong JSON shape for its method."""


def _object_params(message: dict[str, Any]) -> dict[str, Any]:
    params = message.get("params")
    if params is None:
        return {}
    if not isinstance(params, dict):
        raise InvalidParams("params must be a JSON object")
    return params


class McpServer:
    """Newline-delimited JSON-RPC 2.0, the shape MCP stdio clients speak."""

    def __init__(self) -> None:
        self.protocol_version = DEFAULT_PROTOCOL_VERSION

    def handle(self, message: Any) -> dict[str, Any] | None:
        # Total over any JSON value, not just an object, so no caller has to
        # pre-screen what it read. A batch is a list of whatever the client
        # sent, and one stray literal in it must not take the server down.
        if not isinstance(message, dict):
            return _rpc_error(None, -32600, "invalid request")
        method = message.get("method")
        message_id = message.get("id")
        is_notification = message_id is None

        try:
            if method == "initialize":
                result = self._initialize(_object_params(message))
            elif method in ("notifications/initialized", "initialized"):
                return None
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": _tool_definitions()}
            elif method == "tools/call":
                result = self._call_tool(_object_params(message))
            elif method in ("resources/list", "prompts/list"):
                # Not in the declared capabilities, but some clients probe anyway.
                key = "resources" if method.startswith("resources") else "prompts"
                result = {key: []}
            elif is_notification:
                return None
            else:
                return _rpc_error(message_id, -32601, f"unknown method: {method}")
        except InvalidParams as err:
            # A wrongly shaped request is the client's mistake, so it gets the
            # protocol's own invalid-params code rather than a Python exception
            # name wrapped in an internal error.
            if is_notification:
                return None
            return _rpc_error(message_id, -32602, f"invalid params: {err}")
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
        name = params.get("name")
        if not isinstance(name, str):
            raise InvalidParams("tools/call needs a tool name string")
        handler = TOOLS.get(name)
        if handler is None:
            raise CAPTURE.CaptureError(f"unknown tool: {name}")
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            raise InvalidParams("tools/call arguments must be a JSON object")
        return {"content": handler(arguments), "isError": False}

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
                # Batches left the spec in 2025-06-18; older clients still send
                # them, and such a client expects exactly one array back. A batch
                # that was nothing but notifications gets no reply at all, since
                # an empty array is itself an invalid response.
                if not message:
                    _write(stdout, _rpc_error(None, -32600, "invalid request"))
                    continue
                responses = [r for r in (self.handle(item) for item in message) if r is not None]
                if responses:
                    _write(stdout, responses)
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


def _write(stream: Any, payload: dict[str, Any] | list[dict[str, Any]]) -> None:
    stream.write(json.dumps(payload) + "\n")
    stream.flush()


def _save_capture(directory: Path, name: str, png: bytes) -> Path:
    """Write one capture into `directory`, refusing to follow a symlink.

    These bytes are a picture of the captain's live desktop, which this tool
    otherwise never puts on disk. A fresh private directory plus O_EXCL and
    O_NOFOLLOW means nothing pre-created by another local user can redirect the
    write somewhere they can read.
    """
    path = directory / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, 0o600), "wb") as handle:
        handle.write(png)
    return path


def _discard_captures(directory: Path, saved: Iterable[Path]) -> bool:
    """Remove exactly the files this selftest wrote, then its directory."""
    removed = True
    for path in saved:
        try:
            path.unlink()
        except OSError as err:
            print(f"could not remove {path}: {err}")
            removed = False
    try:
        directory.rmdir()
    except OSError as err:
        print(f"could not remove {directory}: {err}")
        removed = False
    return removed


def _selftest(keep_captures: bool = False) -> int:
    """Capture both scopes for real and report what came back."""
    print("# tools")
    for tool in _tool_definitions():
        print(f"- {tool['name']}")
    outdir = Path(tempfile.mkdtemp(prefix="fm-deskcap-selftest-"))
    print(f"\ncaptures are being written to {outdir}")
    failures = 0
    saved: list[Path] = []
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
            out = _save_capture(outdir, f"{label}-{route}.png", png)
            saved.append(out)
            print(f"saved {out}")

    # These files are pictures of the captain's live desktop, so they only stay
    # on disk when the operator asked for them or when a failure makes them
    # evidence. Everything else is cleaned up before this returns.
    if saved and (failures or keep_captures):
        why = "the run failed" if failures else "--keep-captures was given"
        print(f"\nkept {len(saved)} capture(s) in {outdir} because {why}")
        return 1 if failures else 0
    if not _discard_captures(outdir, saved):
        print(f"\ncaptures may still be on disk under {outdir}; remove them by hand")
        return 1
    if saved:
        print(f"\nremoved {len(saved)} capture(s) and {outdir}")
    else:
        print(f"\nno captures were written; removed {outdir}")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-deskcap-mcp.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--selftest", action="store_true", help="capture both scopes for real and report")
    parser.add_argument("--probe", action="store_true", help="report route availability without capturing")
    parser.add_argument(
        "--keep-captures",
        action="store_true",
        help=(
            "keep the selftest's PNGs of the captain's desktop on disk; without "
            "it a run that captured everything removes them again"
        ),
    )
    args = parser.parse_args(argv)

    if args.probe:
        print(json.dumps(CAPTURE.probe(), indent=2))
        return 0
    if args.selftest:
        return _selftest(keep_captures=args.keep_captures)

    McpServer().serve(sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
