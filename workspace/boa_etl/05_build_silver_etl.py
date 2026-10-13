"""Clean/integrate Bronze, then append Data Vault hubs, links and changed satellites."""
from boa_etl.database import active_run, execute_sql, layer_transaction, writer_connection


def main():
    with writer_connection() as conn:
        run = active_run(conn, "bronze-ready")
        with layer_transaction(conn, run, "build-silver-vault", "silver-vault-ready"):
            execute_sql(conn, "build_silver.sql")
            execute_sql(conn, "load_vault.sql")


if __name__ == "__main__":
    main()

