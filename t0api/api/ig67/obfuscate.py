"""
Vercel Python Serverless Function for ig67.

ig67 is pure Python (no external pip packages, stdlib only) -- the only
reason it couldn't just be dropped into the Node dispatcher like the Lua
engines is that it's a different language runtime entirely, so it gets its
own function file here (api/ig67/obfuscate.py -> /api/ig67/obfuscate),
using Vercel's Python runtime. This is function #3 for the whole project
(the Node dispatcher is #1+#2: [engine]/[action].js and health.js) --
still far under the Hobby 12-function cap.

build(payload, seed, min_kb, name, ver) in lib/engines/ig67/src/obfuscate.py
is a pure function (no file I/O) -- verified end-to-end with the real
python3 in the build sandbox (this one, unlike the wasmoon-based engines,
WAS actually testable here, since Python was available offline).
"""

import os
import sys
import json
from http.server import BaseHTTPRequestHandler

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_IG67_SRC = os.path.normpath(os.path.join(_THIS_DIR, "..", "..", "lib", "engines", "ig67", "src"))
if _IG67_SRC not in sys.path:
    sys.path.insert(0, _IG67_SRC)

from obfuscate import build  # noqa: E402

MAX_SOURCE_BYTES = 200_000


def _check_api_key(headers):
    expected = os.environ.get("API_KEY")
    if not expected:
        return False, 500, "Server misconfigured: API_KEY is not set in the Vercel project environment variables."
    provided = headers.get("X-API-Key") or headers.get("x-api-key")
    auth = headers.get("Authorization") or headers.get("authorization")
    if not provided and auth and auth.lower().startswith("bearer "):
        provided = auth[7:].strip()
    if not provided or provided != expected:
        return False, 401, "Missing or invalid API key. Send it as 'X-API-Key: <key>' or 'Authorization: Bearer <key>'."
    return True, 200, None


class handler(BaseHTTPRequestHandler):
    def _set_cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-API-Key, Authorization")
        self.send_header("Cache-Control", "no-store")

    def _json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self._set_cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._set_cors()
        self.end_headers()

    def do_GET(self):
        self._json(405, {"success": False, "error": "Method not allowed. Use POST."})

    def do_POST(self):
        ok, status, err = _check_api_key(self.headers)
        if not ok:
            return self._json(status, {"success": False, "error": err})

        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return self._json(400, {"success": False, "error": "Invalid JSON body."})

        source = body.get("source")
        if not isinstance(source, str) or not source:
            return self._json(400, {"success": False, "error": "Body must include a non-empty string field 'source'."})
        if len(source.encode("utf-8")) > MAX_SOURCE_BYTES:
            return self._json(413, {"success": False, "error": f"Source too large. Limit is {MAX_SOURCE_BYTES} bytes."})

        try:
            seed = int(body.get("seed", 0x7C01))
            min_kb = int(body.get("minKb", 1))
        except (TypeError, ValueError):
            return self._json(400, {"success": False, "error": "'seed' and 'minKb' must be numbers."})
        name = str(body.get("name", "obfuscated"))
        version = str(body.get("version", "1.0"))

        try:
            output = build(source, seed, min_kb, name, version)
        except Exception as e:
            return self._json(500, {"success": False, "error": "Obfuscation failed (ig67).", "detail": str(e)})

        return self._json(200, {"success": True, "engine": "ig67", "output": output, "seed": seed})
