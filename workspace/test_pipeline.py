"""One full tutorial acceptance run, including a repeat-run check; requires running Docker services."""
from datetime import datetime, timezone
import subprocess
import sys

from psycopg import sql

from boa_etl.config import OUTPUT_DIR, WORKSPACE
from boa_etl.database import connect, write_json

STEPS = (
    "boa_etl/01_check_environment.py",
    "boa_etl/02_create_schemas.py",
    "load_sample_data.py",
    "boa_etl/03_profile_sources.py",
    "boa_etl/04_load_bronze.py",
    "boa_etl/05_build_silver_etl.py",
    "boa_etl/06_build_gold_etl.py",
    "boa_etl/07_validate_warehouse.py",
    "boa_etl/08_run_analytics.py",
    "boa_etl/09_build_graph.py",
)


def business_counts():
    with connect() as conn:
        tables = conn.execute("""SELECT table_schema,table_name FROM information_schema.tables
            WHERE table_schema IN ('boa_bronze','boa_vault','boa_gold') AND table_type='BASE TABLE'
            ORDER BY table_schema,table_name""").fetchall()
        return {f"{t['table_schema']}.{t['table_name']}": conn.execute(
            sql.SQL("SELECT count(*) AS n FROM {}").format(sql.Identifier(t["table_schema"], t["table_name"]))
            ).fetchone()["n"] for t in tables}


def main():
    result = {"status": "FAILED", "started_at": datetime.now(timezone.utc).isoformat(), "steps": []}
    try:
        # Run real standalone scripts, so imports and the connection boundary are exercised too.
        for path in STEPS:
            print(f"\nRunning {path}", flush=True)
            subprocess.run([sys.executable, str(WORKSPACE / path)], cwd=WORKSPACE, check=True)
            result["steps"].append(path)
        before = business_counts()
        for path in STEPS[4:]:
            subprocess.run([sys.executable, str(WORKSPACE / path)], cwd=WORKSPACE, check=True)
        after = business_counts()
        result["counts_before_rerun"], result["counts_after_rerun"] = before, after
        if before != after:
            raise RuntimeError("Unchanged input created duplicate business/history rows on rerun.")
        # Both passes include independent whole-dataset amount/identity/lineage checks (07)
        # and complete Graph node/edge/property reconciliation (09), not counts alone.
        result["status"] = "PASSED"
        print("PASS full pipeline, independent reconciliation and repeat-run checks")
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        result["finished_at"] = datetime.now(timezone.utc).isoformat()
        write_json(OUTPUT_DIR / "pipeline_test.json", result)


if __name__ == "__main__":
    main()
