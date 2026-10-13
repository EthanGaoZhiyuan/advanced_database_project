"""Load the supplied SQL INSERT scripts after 02 and before 03, like tutorial import_raw.py."""
from boa_etl.config import DATA_DIR, SOURCES, SQL_DIR
from boa_etl.database import connect, writer_connection
from boa_etl.sample_data import read_manifest


def main():
    manifest = read_manifest()
    with writer_connection() as warehouse:
        if warehouse.execute("SELECT 1 FROM boa_audit.pipeline_run WHERE status='RUNNING'").fetchone():
            raise RuntimeError("Finish steps 05–06 before reloading the source data.")
        for source, database in SOURCES.items():
            with connect(database) as conn:
                # Each file contains its own BEGIN/COMMIT and is repeatable for this sample.
                conn.execute((SQL_DIR / "seed" / f"{source.lower()}.sql").read_text())
            print(f"Loaded {source}: {database}")
        warehouse.execute((SQL_DIR / "seed/registry.sql").read_text())
        warehouse.execute("UPDATE boa_audit.batch_manifest SET input_directory=%s WHERE batch_id=%s",
                          (str(DATA_DIR), manifest["batch_id"]))
    print("Loaded the verified identity crosswalk. Continue with 03_profile_sources.py.")


if __name__ == "__main__":
    main()

