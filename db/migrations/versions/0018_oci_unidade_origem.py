"""Unidade de origem da OCI (ADR-0039).

O Navegador passa a abrir a OCI com a 1ª etapa em qualquer unidade. Sem guardar a unidade de quem
abriu, ela deixaria de ver a OCI que acabou de abrir. As OCIs existentes recebem a unidade da
1ª etapa, que até aqui era sempre a de quem abriu (ADR-0025, item 5). O preenchimento não mexe em
`atualizado_em`: a OCI não foi alterada por ninguém.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0018"
down_revision: str | None = "0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE app.oci ADD COLUMN id_unidade_origem integer"
        " REFERENCES app.unidade_saude (id_unidade)"
    )
    op.execute("ALTER TABLE app.oci DISABLE TRIGGER oci_atualizado_em")
    op.execute(
        """
        UPDATE app.oci o
           SET id_unidade_origem = (
                   SELECT n.id_unidade
                     FROM app.oci_navegacao n
                    WHERE n.id_oci = o.id_oci
                    ORDER BY n.id_oci_navegacao
                    LIMIT 1
               )
        """
    )
    op.execute("ALTER TABLE app.oci ENABLE TRIGGER oci_atualizado_em")
    op.execute("CREATE INDEX oci_unidade_origem_idx ON app.oci (id_unidade_origem)")
    # A app_user grava a origem só na abertura (INSERT, já concedido) e nunca a altera.


def downgrade() -> None:
    op.execute("ALTER TABLE app.oci DROP COLUMN id_unidade_origem")
