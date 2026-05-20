"""create pcs table

Revision ID: 002
Revises: 001
Create Date: 2026-05-20 22:10:00.000000

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "pcs",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("environment", sa.String(length=64), nullable=False),
        sa.Column("pc_name", sa.String(length=255), nullable=False),
        sa.Column("tag", sa.String(length=255), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("environment", "pc_name", name="uq_pcs_environment_pc_name"),
    )
    op.create_index("ix_pcs_environment", "pcs", ["environment"])


def downgrade() -> None:
    op.drop_index("ix_pcs_environment", table_name="pcs")
    op.drop_table("pcs")
