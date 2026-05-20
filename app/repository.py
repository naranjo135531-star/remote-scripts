import logging
import os
from datetime import UTC, datetime
from typing import Any

from app.db import SessionLocal
from app.models import Payload

logger = logging.getLogger(__name__)

ENVIRONMENT = os.getenv("ENVIRONMENT", "production")


def parse_payload_datetime(payload: dict[str, Any]) -> datetime:
    executed_at = payload.get("executedAt")
    if isinstance(executed_at, str):
        try:
            return datetime.fromisoformat(executed_at.replace("Z", "+00:00"))
        except ValueError:
            pass
    return datetime.now(UTC)


def save_payload_record(payload: dict[str, Any]) -> dict[str, Any]:
    pc_name = str(payload.get("hostname") or "unknown")
    recorded_at = parse_payload_datetime(payload)

    with SessionLocal() as session:
        row = Payload(
            environment=ENVIRONMENT,
            pc_name=pc_name,
            datetime=recorded_at,
            content=payload,
        )
        session.add(row)
        session.commit()
        session.refresh(row)

    logger.info(
        "Saved payload id=%s environment=%s pc_name=%s",
        row.id,
        row.environment,
        row.pc_name,
    )
    return {
        "id": row.id,
        "environment": row.environment,
        "pc_name": row.pc_name,
        "datetime": row.datetime.isoformat(),
    }


def verify_database_connection() -> None:
    with SessionLocal() as session:
        session.connection()
