"""create script_errors table

Revision ID: 003
Revises: 002
Create Date: 2026-05-20 23:00:00.000000

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "003"
down_revision: Union[str, None] = "002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "script_errors",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("environment", sa.String(length=64), nullable=False),
        sa.Column("pc_name", sa.String(length=255), nullable=False),
        sa.Column("datetime", sa.DateTime(timezone=True), nullable=False),
        sa.Column("content", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_script_errors_environment_pc_name", "script_errors", ["environment", "pc_name"])
    op.create_index("ix_script_errors_datetime", "script_errors", ["datetime"])


def downgrade() -> None:
    op.drop_index("ix_script_errors_datetime", table_name="script_errors")
    op.drop_index("ix_script_errors_environment_pc_name", table_name="script_errors")
    op.drop_table("script_errors")
