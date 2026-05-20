"""create payloads table

Revision ID: 001
Revises:
Create Date: 2026-05-20 22:00:00.000000

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "payloads",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("environment", sa.String(length=64), nullable=False),
        sa.Column("pc_name", sa.String(length=255), nullable=False),
        sa.Column("datetime", sa.DateTime(timezone=True), nullable=False),
        sa.Column("content", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_payloads_environment_pc_name", "payloads", ["environment", "pc_name"])
    op.create_index("ix_payloads_datetime", "payloads", ["datetime"])


def downgrade() -> None:
    op.drop_index("ix_payloads_datetime", table_name="payloads")
    op.drop_index("ix_payloads_environment_pc_name", table_name="payloads")
    op.drop_table("payloads")
