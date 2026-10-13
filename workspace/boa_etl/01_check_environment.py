"""Check the tutorial services and supplied data before creating any tables."""
from urllib.request import urlopen

from boa_etl.database import connect
from boa_etl.graph_model import Neo4jClient
from boa_etl.sample_data import read_manifest


def main():
    failures = []
    checks = {
        "PostgreSQL": check_postgres,
        "Neo4j": lambda: Neo4jClient().query("RETURN 1 AS ready"),
        "CloudBeaver": lambda: check_http("http://cloudbeaver:8978/"),
        "ClickHouse (tutorial service)": lambda: check_http("http://clickhouse:8123/ping"),
        "Sample dataset": read_manifest,
    }
    for name, check in checks.items():
        try:
            check()
            print(f"PASS {name}")
        except Exception as exc:
            failures.append(name)
            print(f"FAIL {name}: {exc}")
    if failures:
        raise SystemExit("Services may still be starting. Check Docker and rerun 01.")


def check_postgres():
    with connect() as conn:
        version = int(conn.execute("SHOW server_version_num").fetchone()["server_version_num"])
        if version < 150000:
            raise RuntimeError("PostgreSQL 15 or later is required")


def check_http(url):
    with urlopen(url, timeout=5) as response:
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status}")


if __name__ == "__main__":
    main()

