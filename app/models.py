from datetime import datetime

from sqlalchemy import DateTime, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Payload(Base):
    __tablename__ = "payloads"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    environment: Mapped[str] = mapped_column(String(64), nullable=False)
    pc_name: Mapped[str] = mapped_column(String(255), nullable=False)
    datetime: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    content: Mapped[dict] = mapped_column(JSONB, nullable=False)


class Pc(Base):
    __tablename__ = "pcs"
    __table_args__ = (UniqueConstraint("environment", "pc_name", name="uq_pcs_environment_pc_name"),)

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    environment: Mapped[str] = mapped_column(String(64), nullable=False)
    pc_name: Mapped[str] = mapped_column(String(255), nullable=False)
    tag: Mapped[str | None] = mapped_column(String(255), nullable=True)


class ScriptError(Base):
    __tablename__ = "script_errors"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    environment: Mapped[str] = mapped_column(String(64), nullable=False)
    pc_name: Mapped[str] = mapped_column(String(255), nullable=False)
    datetime: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    content: Mapped[dict] = mapped_column(JSONB, nullable=False)
