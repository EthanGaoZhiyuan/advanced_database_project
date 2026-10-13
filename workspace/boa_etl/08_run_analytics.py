"""Print banking analyses and export their complete results to CSV."""
from dashboard import queries
from boa_etl.config import OUTPUT_DIR
from boa_etl.database import write_json


def main():
    publications = queries.publications()
    if not publications:
        raise RuntimeError("No published Gold data. Complete steps 04–07 first.")
    day = publications[0]["business_date"]
    reports = {
        "customer_360": queries.query("SELECT * FROM boa_gold.v_customer_360 WHERE business_date=%s ORDER BY enterprise_customer_id", (day,)),
        "product_combinations": queries.product_combinations(day),
        "borrowing_daily": queries.borrowing_daily(),
        "transaction_types": queries.transaction_types(day),
        "top_merchants": queries.top_merchants(day),
    }
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, rows in reports.items():
        (OUTPUT_DIR / f"{name}.csv").write_bytes(queries.csv_bytes(rows))
        print(f"\n{name}: {len(rows)} rows (first 5 shown)")
        for row in rows[:5]:
            print(row)
    write_json(OUTPUT_DIR / "analytics.json", {"business_date": day,
               "reports": {name: len(rows) for name, rows in reports.items()}})
    print(f"\nCSV reports saved in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()

