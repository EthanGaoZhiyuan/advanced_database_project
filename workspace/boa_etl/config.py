"""Paths and local tutorial connection settings; Compose supplies the same values."""
import os
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[1]
DATA_DIR = WORKSPACE / "data"
SQL_DIR = WORKSPACE / "sql"
OUTPUT_DIR = WORKSPACE / "output"

DATABASE = os.environ.get("PGDATABASE", "boa")
SOURCES = {"SAVINGS": "boa_savings", "CARDS": "boa_cards", "LOANS": "boa_loans"}
ENTITIES = ("customers", "accounts", "daily_balances", "transactions")
PG_SETTINGS = {
    "host": os.environ.get("PGHOST", "postgres"),
    "port": os.environ.get("PGPORT", "5432"),
    "user": os.environ.get("PGUSER", "student"),
    "password": os.environ.get("PGPASSWORD", "student"),
    "connect_timeout": 5,
}

