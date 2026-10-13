"""Connections, SQL execution and the small amount of state shared by steps 04–06."""
from contextlib import contextmanager
import json
import re
import uuid

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from boa_etl.config import DATABASE, PG_SETTINGS, SOURCES, SQL_DIR


def connect(database=None):
    return psycopg.connect(**PG_SETTINGS, dbname=database or DATABASE,
                          autocommit=True, row_factory=dict_row)


def execute_sql(conn, filename):
    """Execute a warehouse SQL file inside the caller's transaction."""
    for statement in (SQL_DIR / filename).read_text().split("-- statement-break"):
        if statement.strip():
            conn.execute(statement)


@contextmanager
def writer_connection():
    """Do not allow two tutorial steps to change the warehouse concurrently."""
    with connect() as conn:
        acquired = conn.execute("SELECT pg_try_advisory_lock(32113001) AS ok").fetchone()["ok"]
        if not acquired:
            raise RuntimeError("Another ETL step is running. Wait for it to finish.")
        try:
            yield conn
        finally:
            # Seed scripts contain explicit transactions; retain their original error if one aborts.
            conn.rollback()
            conn.execute("SELECT pg_advisory_unlock(32113001)")


def create_schemas():
    with writer_connection() as conn:
        # CREATE DATABASE cannot run inside a transaction.
        for source, database in SOURCES.items():
            if not conn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (database,)).fetchone():
                conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database)))
            with connect(database) as source_conn, source_conn.transaction():
                execute_sql(source_conn, f"sources/{source.lower()}.sql")
            print(f"Source database ready: {database}")
            conn.execute("SELECT set_config(%s,%s,false)", (f"boa.{source.lower()}_db", database))
        # FDW connects to the other three databases within the same PostgreSQL service.
        for setting, value in (("source_host", "127.0.0.1"),
                               ("source_user", conn.info.user), ("source_password", conn.info.password or "")):
            conn.execute("SELECT set_config(%s,%s,false)", ("boa." + setting, value))
        with conn.transaction():
            for filename in ("001_schema.sql", "002_reports.sql", "003_integrity.sql", "004_input_contract.sql"):
                execute_sql(conn, filename)
        print("Warehouse ready: boa_bronze, boa_silver, boa_vault, boa_gold, boa_audit")


def set_run_context(conn, run):
    """Each Python process restores its run context from the audit tables."""
    conn.execute("SELECT set_config('boa.run_id',%s,true)", (str(run["run_id"]),))
    dates = "{" + ",".join(run["manifest"]["dates"]) + "}"
    conn.execute("SELECT set_config('boa.dates',%s,true)", (dates,))


def start_run(conn, manifest):
    loaded = conn.execute("SELECT manifest FROM boa_audit.batch_manifest WHERE batch_id=%s",
                          (manifest["batch_id"],)).fetchone()
    if not loaded or loaded["manifest"] != manifest:
        raise RuntimeError("Load this dataset first: python load_sample_data.py")
    # Starting 04 again explicitly abandons an interrupted attempt; completed layers remain inspectable.
    abandoned = conn.execute("""UPDATE boa_audit.pipeline_run SET status='FAILED',
        finished_at=clock_timestamp(),error_message='Restarted from 04_load_bronze.py'
        WHERE status='RUNNING'""").rowcount
    if abandoned:
        print(f"Restarting from Bronze; marked {abandoned} unfinished run(s) as failed.")
    run_id = uuid.uuid4()
    conn.execute("""INSERT INTO boa_audit.pipeline_run
        (run_id,batch_id,status,current_stage,execution_metadata)
        VALUES (%s,%s,'RUNNING','ingest-bronze',%s)""",
        (run_id, manifest["batch_id"], Jsonb({"entrypoint": "04_load_bronze.py"})))
    return {"run_id": run_id, "manifest": manifest}


def active_run(conn, expected_stage):
    run = conn.execute("""SELECT r.run_id,r.current_stage,b.manifest
        FROM boa_audit.pipeline_run r JOIN boa_audit.batch_manifest b USING(batch_id)
        WHERE r.status='RUNNING' ORDER BY r.started_at DESC LIMIT 1""").fetchone()
    if not run:
        raise RuntimeError("No unfinished ETL run. Start with 04_load_bronze.py.")
    if run["current_stage"] != expected_stage:
        required = {"bronze-ready": "04_load_bronze.py", "silver-vault-ready": "05_build_silver_etl.py"}
        raise RuntimeError(f"Run {required[expected_stage]} first; current stage is {run['current_stage']}.")
    return run


def record_failure(conn, run_id, stage, exc):
    """Save the original error after the failed layer transaction has rolled back."""
    message = str(exc)
    match = re.match(r"([A-Z][A-Z0-9_]+):", message)
    with conn.transaction():
        conn.execute("""UPDATE boa_audit.pipeline_run SET status='FAILED',current_stage=%s,
            finished_at=clock_timestamp(),error_message=%s WHERE run_id=%s""", (stage, message, run_id))
        conn.execute("""INSERT INTO boa_audit.data_quality_issue
            (run_id,source_system,entity_name,source_record_key,rule_code,severity,issue_description)
            VALUES (%s,'ALL',%s,'*',%s,'ERROR',%s)""",
            (run_id, stage, match.group(1) if match else "STEP_FAILED", message))


@contextmanager
def layer_transaction(conn, run, stage, completed_stage):
    """Commit a completed layer; on error retain earlier layers and record a failed run."""
    try:
        with conn.transaction():
            set_run_context(conn, run)
            yield
            conn.execute("UPDATE boa_audit.pipeline_run SET current_stage=%s WHERE run_id=%s",
                         (completed_stage, run["run_id"]))
    except Exception as exc:
        record_failure(conn, run["run_id"], stage, exc)
        raise
    print(f"Completed {stage}; run {run['run_id']}")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, default=str) + "\n")
