"""Inspect source counts, missing values, whitespace and overlapping customer IDs."""
from psycopg import sql

from boa_etl.config import ENTITIES, OUTPUT_DIR, SOURCES
from boa_etl.database import connect, write_json
from boa_etl.sample_data import read_manifest


def main():
    manifest = read_manifest()
    expected = {(f["source_system"], f["entity_name"]): f["row_count"] for f in manifest["files"]}
    tables, customer_ids, customer_formats = [], {}, {}
    for source, database in SOURCES.items():
        with connect(database) as conn, conn.transaction():
            conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            for entity in ENTITIES:
                relation = sql.Identifier("public", entity)
                count = conn.execute(sql.SQL("SELECT count(*) AS n FROM {}").format(relation)).fetchone()["n"]
                columns = conn.execute("""SELECT column_name,data_type FROM information_schema.columns
                    WHERE table_schema='public' AND table_name=%s ORDER BY ordinal_position""", (entity,)).fetchall()
                missing, padded = {}, {}
                for column in columns:
                    name = column["column_name"]
                    result = conn.execute(sql.SQL("""SELECT
                        count(*) FILTER (WHERE {field} IS NULL OR btrim({field}::text)='') AS missing,
                        count(*) FILTER (WHERE {field}::text<>btrim({field}::text)) AS padded
                        FROM {table}""").format(field=sql.Identifier(name), table=relation)).fetchone()
                    missing[name] = result["missing"]
                    if column["data_type"] in ("text", "character varying"):
                        padded[name] = result["padded"]
                item = {"source": source, "table": entity, "rows": count,
                        "expected_rows": expected[source, entity], "missing_values": missing,
                        "padded_text_values": padded, "columns": columns}
                tables.append(item)
                print(f"{source:8} {entity:15} {count:>8} rows; expected {item['expected_rows']}")
            customers = conn.execute("SELECT customer_id,date_of_birth_text FROM public.customers ORDER BY customer_id").fetchall()
            customer_ids[source] = {row["customer_id"] for row in customers}
            customer_formats[source] = [row["date_of_birth_text"] for row in customers[:3]]
    with connect() as conn:
        registry = conn.execute("SELECT count(*) AS n FROM boa_audit.identity_registry").fetchone()["n"]
    overlaps = {f"{a}/{b}": len(customer_ids[a] & customer_ids[b])
                for a in SOURCES for b in SOURCES if a < b}
    complete = all(t["rows"] == t["expected_rows"] for t in tables) and registry == expected["REGISTRY", "crosswalk"]
    result = {"status": "PASSED" if complete else "FAILED", "tables": tables,
              "registry_rows": registry, "overlapping_local_customer_ids": overlaps,
              "source_date_of_birth_examples": customer_formats,
              "note": "Local ID overlap does not identify the same person. Silver uses the verified crosswalk. "
                      "Missing optional fields and padding are profiled here and cleaned in step 05."}
    write_json(OUTPUT_DIR / "source_profile.json", result)
    print(f"Cross-source local ID overlaps: {overlaps}")
    print(f"Date-of-birth examples: {customer_formats}")
    print(f"Full profile: {OUTPUT_DIR / 'source_profile.json'}")
    if not complete:
        raise SystemExit("Source counts do not match the supplied dataset. Run load_sample_data.py first.")


if __name__ == "__main__":
    main()

