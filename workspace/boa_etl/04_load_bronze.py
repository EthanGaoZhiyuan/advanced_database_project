"""Extract all three persisted source databases into Bronze and retain run/source metadata."""
from boa_etl.database import execute_sql, layer_transaction, start_run, writer_connection
from boa_etl.sample_data import read_manifest


def main():
    manifest = read_manifest()
    with writer_connection() as conn:
        run = start_run(conn, manifest)
        with layer_transaction(conn, run, "ingest-bronze", "bronze-ready"):
            execute_sql(conn, "extract_bronze.sql")
            rows = conn.execute("""SELECT source_system,entity_name,count(*) AS rows
                FROM boa_bronze.source_record r JOIN boa_audit.raw_run_record m USING(raw_record_id)
                WHERE m.run_id=%s GROUP BY source_system,entity_name ORDER BY source_system,entity_name""",
                (run["run_id"],)).fetchall()
            for row in rows:
                print(f"{row['source_system']:8} {row['entity_name']:15} {row['rows']:>8}")
            conn.execute("""UPDATE boa_audit.pipeline_run SET records_read=
                (SELECT coalesce(sum(input_count),0) FROM boa_audit.source_file WHERE run_id=%s)
                WHERE run_id=%s""", (run["run_id"], run["run_id"]))


if __name__ == "__main__":
    main()

