"""Build dimensions/facts from the Vault and publish the complete batch atomically."""
from boa_etl.database import active_run, execute_sql, layer_transaction, writer_connection


def main():
    with writer_connection() as conn:
        run = active_run(conn, "silver-vault-ready")
        with layer_transaction(conn, run, "build-gold", "build-gold"):
            execute_sql(conn, "build_gold.sql")
            execute_sql(conn, "finish_run.sql")


if __name__ == "__main__":
    main()

