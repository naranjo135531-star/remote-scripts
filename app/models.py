from datetime import datetime

from sqlalchemy import DateTime, String
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
