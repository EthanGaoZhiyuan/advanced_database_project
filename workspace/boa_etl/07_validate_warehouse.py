"""Whole-dataset reconciliation against separately generated synthetic truth."""
from __future__ import annotations

import json
import time
from collections import Counter, defaultdict
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

from boa_etl.database import connect
from boa_etl.config import DATA_DIR, OUTPUT_DIR
from boa_etl.sample_data import PROFILE_FIELDS, read_jsonl, sha256


def _json_default(value):
    if isinstance(value, (date, datetime, Decimal)):
        return str(value)
    raise TypeError(type(value).__name__)


def validate(dataset: Path, output: Path = OUTPUT_DIR) -> dict:
    dataset, output = Path(dataset), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    manifest = json.loads((dataset / "manifest.json").read_text())
    dates = [date.fromisoformat(d) for d in manifest["dates"]]
    expected_balances = read_jsonl(dataset / "expected_balances.jsonl")
    expected_accounts = read_jsonl(dataset / "expected_accounts.jsonl")
    expected_customers = read_jsonl(dataset / "expected_customers.jsonl")
    expected_profiles = read_jsonl(dataset / "expected_profiles.jsonl")
    expected_transactions = read_jsonl(dataset / "expected_transactions.jsonl")
    checks = []

    def check(name, condition, details=None):
        checks.append({"name": name, "passed": bool(condition), "details": details})

    def compare_rows(name, expected, actual, keys, columns, decimal_columns=()):
        exp = {tuple(str(row[key]) for key in keys): row for row in expected}
        act = {tuple(str(row[key]) for key in keys): row for row in actual}
        missing, unexpected = exp.keys() - act.keys(), act.keys() - exp.keys()
        differences = []
        mismatch_count = 0
        for key in exp.keys() & act.keys():
            for column in columns:
                left, right = exp[key].get(column), act[key].get(column)
                if column in decimal_columns and left is not None and right is not None:
                    same = abs(Decimal(str(left)) - Decimal(str(right))) <= Decimal("0.000000000000000001")
                else:
                    same = (str(left) if left is not None else None) == (str(right) if right is not None else None)
                if not same:
                    mismatch_count += 1
                    if len(differences) < 8:
                        differences.append({"key": key, "column": column, "expected": left, "actual": right})
        check(name, not missing and not unexpected and not mismatch_count and len(act) == len(actual), {"expected_rows": len(expected), "actual_rows": len(actual), "missing_keys": len(missing), "unexpected_keys": len(unexpected), "duplicate_keys": len(actual) - len(act), "mismatched_values": mismatch_count, "examples": differences, "missing_examples": list(sorted(missing))[:5]})

    oracle_manifest = json.loads((dataset / "oracle_manifest.json").read_text())
    check("oracle_file_checksums", all(sha256(dataset / name) == digest for name, digest in oracle_manifest["files"].items()))
    check("input_file_checksums", all(sha256(dataset / item["path"]) == item["sha256"] for item in manifest["files"]))
    explain = []
    with connect() as conn:
        version = conn.execute("SHOW server_version").fetchone()["server_version"]
        check("postgresql_15_or_later", int(version.split(".")[0]) >= 15, version)
        accepted_run = conn.execute("""SELECT run_id,current_stage FROM boa_audit.pipeline_run
            WHERE batch_id=%s AND status='SUCCEEDED' AND current_stage='build-gold'
            ORDER BY started_at DESC LIMIT 1""", (manifest["batch_id"],)).fetchone()
        check("dataset_has_successful_complete_pipeline_run", accepted_run is not None, {"run_id": str(accepted_run["run_id"]) if accepted_run else None})
        actual_accounts = conn.execute("""SELECT a.source_system, a.source_account_id,c.enterprise_customer_id,p.product_code,a.opened_date,a.closed_date
            FROM boa_gold.dim_account a JOIN boa_gold.dim_customer c USING(customer_sk) JOIN boa_gold.dim_product p USING(product_sk)""").fetchall()
        compare_rows("all_account_identities_and_attributes", expected_accounts, actual_accounts, ("source_system", "source_account_id"), ("enterprise_customer_id", "product_code", "opened_date", "closed_date"))
        actual_balances = conn.execute("SELECT *,business_date AS balance_date FROM boa_gold.v_account_snapshot WHERE business_date = ANY(%s)", (dates,)).fetchall()
        measure_columns = ("savings_balance", "card_outstanding", "loan_principal_outstanding")
        compare_rows("entire_account_date_key_set_and_amounts", expected_balances, actual_balances, ("source_system", "source_account_id", "balance_date"), ("enterprise_customer_id", "account_status", *measure_columns), measure_columns)
        actual_transactions = conn.execute("""SELECT *,business_date AS transaction_date,
            transaction_type_code AS transaction_type FROM boa_gold.v_customer_transactions
            WHERE business_date=ANY(%s)""", (dates,)).fetchall()
        compare_rows("entire_transaction_key_set_and_values", expected_transactions, actual_transactions,
            ("source_system", "source_account_id", "source_transaction_id"),
            ("enterprise_customer_id", "transaction_date", "transaction_type", "signed_amount", "counterparty", "category_code"),
            ("signed_amount",))
        transaction_totals = defaultdict(lambda: {"transaction_count": 0, "total_signed_amount": Decimal(0)})
        merchant_totals = defaultdict(lambda: {"purchase_count": 0, "spend_amount": Decimal(0)})
        products = {"SAVINGS": "SAVINGS", "CARDS": "CREDIT_CARD", "LOANS": "LOAN"}
        for row in expected_transactions:
            key = row["transaction_date"], products[row["source_system"]], row["transaction_type"]
            transaction_totals[key]["transaction_count"] += 1
            transaction_totals[key]["total_signed_amount"] += Decimal(row["signed_amount"])
            if row["source_system"] == "CARDS" and row["transaction_type"] == "PURCHASE" and row["counterparty"] != "Opening balance" and Decimal(row["signed_amount"]) > 0:
                merchant_key = row["transaction_date"], row["counterparty"], row["category_code"]
                merchant_totals[merchant_key]["purchase_count"] += 1
                merchant_totals[merchant_key]["spend_amount"] += Decimal(row["signed_amount"])
        expected_transaction_daily = [{"business_date": d, "product_code": p, "transaction_type_code": t, **values}
            for (d, p, t), values in transaction_totals.items()]
        compare_rows("all_daily_transaction_counts_and_movements", expected_transaction_daily,
            conn.execute("SELECT * FROM boa_gold.v_transaction_daily WHERE business_date=ANY(%s)", (dates,)).fetchall(),
            ("business_date", "product_code", "transaction_type_code"), ("transaction_count", "total_signed_amount"),
            ("total_signed_amount",))
        expected_merchants = [{"business_date": d, "merchant_name": m, "merchant_category_code": c, **values}
            for (d, m, c), values in merchant_totals.items()]
        compare_rows("all_daily_merchant_purchase_totals", expected_merchants,
            conn.execute("SELECT * FROM boa_gold.v_top_merchants WHERE business_date=ANY(%s)", (dates,)).fetchall(),
            ("business_date", "merchant_name", "merchant_category_code"), ("purchase_count", "spend_amount"), ("spend_amount",))
        # Independent Gold reconciliation covers all published history, including earlier incremental batches.
        transaction_balance_mismatches = conn.execute("""WITH movements AS (
            SELECT account_sk,business_date,sum(signed_amount) AS amount
            FROM boa_gold.v_customer_transactions GROUP BY account_sk,business_date
          ), daily_changes AS (
            SELECT account_sk,business_date,
              savings_balance+card_outstanding+loan_principal_outstanding
              -lag(savings_balance+card_outstanding+loan_principal_outstanding,1,0::numeric)
                OVER(PARTITION BY account_sk ORDER BY business_date) AS amount
            FROM boa_gold.v_account_snapshot
          ) SELECT count(*) AS n FROM daily_changes b FULL JOIN movements t USING(account_sk,business_date)
          WHERE b.amount IS DISTINCT FROM coalesce(t.amount,0::numeric)""").fetchone()["n"]
        check("transactions_reconcile_to_balances", transaction_balance_mismatches == 0,
              {"mismatched_account_dates": transaction_balance_mismatches, "scope": "all published Gold history; opening balance starts at zero"})
        invalid_transaction_days = conn.execute("""SELECT count(*) AS n FROM boa_gold.v_customer_transactions t
            LEFT JOIN boa_gold.v_account_snapshot b USING(account_sk,business_date)
            WHERE b.snapshot_sk IS NULL OR b.account_status<>'ACTIVE'""").fetchone()["n"]
        check("transactions_follow_opening_and_closure_dates", invalid_transaction_days == 0,
              {"invalid_transaction_days": invalid_transaction_days})
        actual_customers = conn.execute("SELECT *,business_date AS balance_date FROM boa_gold.v_customer_360 WHERE business_date = ANY(%s)", (dates,)).fetchall()
        financial = ("total_savings", "total_card_outstanding", "total_loan_principal", "total_borrowing", "credit_card_utilisation")
        compare_rows("entire_customer_date_aggregations", expected_customers, actual_customers, ("enterprise_customer_id", "balance_date"), ("active_account_count", "active_product_category_count", "product_combination", *financial), financial)
        categories = ("SAVINGS", "CREDIT_CARD", "LOAN")
        holdings, combinations, distribution, pairs = Counter(), Counter(), Counter(), Counter()
        daily_borrowing = defaultdict(lambda: {name: Decimal(0) for name in ("total_card_outstanding", "total_loan_principal", "total_borrowing")})
        for row in expected_customers:
            business_date = row["balance_date"]
            held = [] if row["product_combination"] == "NONE" else row["product_combination"].split(" + ")
            combinations[business_date, row["product_combination"]] += 1
            distribution[business_date, row["active_product_category_count"]] += 1
            for category in held:
                holdings[business_date, category] += 1
                for other in held:
                    pairs[business_date, category, other] += 1
            for name in daily_borrowing[business_date]:
                daily_borrowing[business_date][name] += Decimal(row[name])
        expected_holdings = [{"business_date": d, "product_code": p, "customer_count": holdings[d, p], "population_count": manifest["customer_count"]} for d in manifest["dates"] for p in categories]
        compare_rows("all_product_category_counts", expected_holdings, conn.execute("SELECT * FROM boa_gold.v_product_holdings WHERE business_date=ANY(%s)", (dates,)).fetchall(), ("business_date", "product_code"), ("customer_count", "population_count"))
        expected_combinations = [{"business_date": d, "product_combination": p, "customer_count": n} for (d, p), n in combinations.items()]
        compare_rows("all_product_combination_counts", expected_combinations, conn.execute("SELECT * FROM boa_gold.v_product_combinations WHERE business_date=ANY(%s)", (dates,)).fetchall(), ("business_date", "product_combination"), ("customer_count",))
        expected_distribution = [{"business_date": d, "category_count": n, "customer_count": distribution[d, n]} for d in manifest["dates"] for n in range(4)]
        compare_rows("zero_to_three_category_distribution", expected_distribution, conn.execute("SELECT * FROM boa_gold.v_product_category_distribution WHERE business_date=ANY(%s)", (dates,)).fetchall(), ("business_date", "category_count"), ("customer_count",))
        expected_pairs = [{"business_date": d, "product_a": a, "product_b": b, "customer_count": pairs[d, a, b]} for d in manifest["dates"] for a in categories for b in categories]
        compare_rows("all_cross_product_ownership_counts", expected_pairs, conn.execute("SELECT * FROM boa_gold.v_cross_product_ownership WHERE business_date=ANY(%s)", (dates,)).fetchall(), ("business_date", "product_a", "product_b"), ("customer_count",))
        expected_daily = [{"business_date": d, "total_card_outstanding": values["total_card_outstanding"], "total_loan_principal": values["total_loan_principal"], "total_borrowing": values["total_borrowing"]} for d, values in daily_borrowing.items()]
        compare_rows("all_daily_borrowing_report_totals", expected_daily, conn.execute("SELECT * FROM boa_gold.v_borrowing_daily WHERE business_date=ANY(%s)", (dates,)).fetchall(), ("business_date",), ("total_card_outstanding", "total_loan_principal", "total_borrowing"), ("total_card_outstanding", "total_loan_principal", "total_borrowing"))
        actual_profiles = conn.execute("SELECT * FROM boa_gold.dim_customer").fetchall()
        compare_rows("deterministic_current_customer_profiles", expected_profiles, actual_profiles, ("enterprise_customer_id",), PROFILE_FIELDS)
        profile_truth = {row["enterprise_customer_id"]: row for row in expected_profiles}
        age_mismatches = 0
        for row in actual_customers:
            dob = date.fromisoformat(profile_truth[row["enterprise_customer_id"]]["date_of_birth"])
            business_date = row["business_date"]
            age = business_date.year - dob.year - ((business_date.month, business_date.day) < (dob.month, dob.day))
            if row.get("age") != age:
                age_mismatches += 1
        check("age_uses_selected_business_date", age_mismatches == 0, {"mismatched_rows": age_mismatches})
        published = conn.execute("SELECT * FROM boa_audit.published_day WHERE business_date=ANY(%s)", (dates,)).fetchall()
        check("all_requested_dates_published", {r["business_date"] for r in published} == set(dates), {"expected_dates": len(dates), "published_dates": len(published)})
        check("publication_account_population_counts", all(row["expected_account_count"] == row["actual_account_count"] for row in published))
        mixed = conn.execute("""SELECT count(*) AS n FROM boa_gold.fact_account_daily_snapshot f
            JOIN boa_gold.dim_date d USING(date_sk) JOIN boa_audit.published_day p ON p.business_date=d.full_date
            WHERE f.load_run_id<>p.published_run_id""").fetchone()["n"]
        check("consistent_publication_metadata", mixed == 0, {"inconsistent_facts": mixed})
        mixed_transactions = conn.execute("""SELECT count(*) AS n FROM boa_gold.fact_transaction f
            JOIN boa_gold.dim_date d USING(date_sk) JOIN boa_audit.published_day p ON p.business_date=d.full_date
            WHERE f.load_run_id<>p.published_run_id""").fetchone()["n"]
        check("consistent_transaction_publication_metadata", mixed_transactions == 0,
              {"inconsistent_transaction_facts": mixed_transactions})
        reconciliation = conn.execute("""SELECT count(*) AS n FROM boa_audit.source_file s JOIN boa_audit.pipeline_run r USING(run_id)
            WHERE r.status='SUCCEEDED' AND r.batch_id=%s AND s.input_count<>s.accepted_count+s.deduplicated_count+s.rejected_count""", (manifest["batch_id"],)).fetchone()["n"]
        check("successful_source_counts_reconcile", reconciliation == 0, {"unreconciled_files": reconciliation})
        fixture = [row for row in actual_customers if row["enterprise_customer_id"] == "EC000001"]
        check("known_fixture_borrowing_excludes_savings", len(fixture) == len(dates) and all(row["total_card_outstanding"] == Decimal("2000.00") and row["total_loan_principal"] == Decimal("300000.00") and row["total_borrowing"] == Decimal("302000.00") for row in fixture))
        zero_expected = sum(1 for row in expected_balances if row["account_status"] == "ACTIVE" and all(Decimal(row[c]) == 0 for c in measure_columns))
        closed_expected = sum(1 for row in expected_balances if row["account_status"] == "CLOSED")
        check("closed_balances_zero", all(all(row[c] == 0 for c in measure_columns) for row in actual_balances if row["account_status"] == "CLOSED"), {"closed_observations": closed_expected})
        zero_keys = {(row["enterprise_customer_id"], row["balance_date"]) for row in expected_balances if row["account_status"] == "ACTIVE" and all(Decimal(row[c]) == 0 for c in measure_columns)}
        actual_zero_customers = [row for row in actual_customers if (row["enterprise_customer_id"], str(row["business_date"])) in zero_keys]
        check("active_zero_balances_retain_holdings", len(actual_zero_customers) == len(zero_keys) and all(row["active_account_count"] > 0 and row["active_product_category_count"] > 0 for row in actual_zero_customers), {"active_zero_observations": zero_expected, "verified_by": "entire_customer_date_aggregations"})
        integrity_sql = """SELECT
            (SELECT count(*) FROM boa_silver.account a LEFT JOIN boa_silver.enterprise_customer c USING(enterprise_customer_id) WHERE c.enterprise_customer_id IS NULL)+
            (SELECT count(*) FROM boa_vault.link_customer_account l LEFT JOIN boa_vault.hub_customer c USING(customer_hk) LEFT JOIN boa_vault.hub_account a USING(account_hk) WHERE c.customer_hk IS NULL OR a.account_hk IS NULL)+
            (SELECT count(*) FROM boa_vault.sat_account_daily_balance b LEFT JOIN boa_vault.hub_account a USING(account_hk) WHERE a.account_hk IS NULL)+
            (SELECT count(*) FROM boa_gold.fact_account_daily_snapshot f LEFT JOIN boa_gold.dim_account a ON (a.account_sk,a.customer_sk,a.product_sk)=(f.account_sk,f.customer_sk,f.product_sk) WHERE a.account_sk IS NULL) AS n"""
        check("referential_and_account_fact_integrity", conn.execute(integrity_sql).fetchone()["n"] == 0)
        lineage = conn.execute("""SELECT count(*) AS n FROM boa_vault.sat_account_daily_balance v
            JOIN boa_vault.hub_account a USING(account_hk) LEFT JOIN boa_bronze.source_record r USING(raw_record_id)
            LEFT JOIN boa_audit.raw_run_record m ON m.raw_record_id=v.raw_record_id AND m.run_id=v.run_id
            WHERE r.raw_record_id IS NULL OR m.raw_record_id IS NULL OR r.source_system<>a.source_system
               OR r.entity_name<>'daily_balances' OR r.payload->>'account_id'<>a.source_account_id
               OR r.business_date<>v.balance_date OR r.payload->>'balance_date'<>v.balance_date::text
               OR r.source_record_key<>a.source_account_id || '|' || v.balance_date::text""").fetchone()["n"]
        check("all_vault_balance_raw_provenance", lineage == 0, {"invalid_references": lineage})
        fact_lineage = conn.execute("""SELECT count(*) AS n FROM boa_gold.fact_account_daily_snapshot f
            JOIN boa_gold.dim_account a USING(account_sk) JOIN boa_gold.dim_date d USING(date_sk)
            LEFT JOIN boa_vault.sat_account_daily_balance v ON v.version_id=f.vault_balance_version_id
            LEFT JOIN boa_vault.hub_account h ON h.account_hk=v.account_hk
            WHERE v.version_id IS NULL OR (h.source_system,h.source_account_id)<>(a.source_system,a.source_account_id)
              OR v.balance_date<>d.full_date OR (v.savings_balance,v.card_outstanding,v.loan_principal_outstanding)<>
                 (f.savings_balance,f.card_outstanding,f.loan_principal_outstanding)""").fetchone()["n"]
        check("gold_values_derive_from_referenced_vault_versions", fact_lineage == 0, {"invalid_facts": fact_lineage})
        transaction_lineage = conn.execute("""SELECT count(*) AS n FROM boa_gold.fact_transaction f
            JOIN boa_gold.dim_account a USING(account_sk) JOIN boa_gold.dim_date d USING(date_sk)
            JOIN boa_gold.dim_transaction_type t USING(transaction_type_sk)
            LEFT JOIN boa_vault.sat_account_transaction v ON v.transaction_id=f.vault_transaction_id
            LEFT JOIN boa_vault.hub_account h ON h.account_hk=v.account_hk
            WHERE v.transaction_id IS NULL OR
              (h.source_system,h.source_account_id,v.source_transaction_id,v.transaction_date,v.transaction_type,
               v.signed_amount,v.counterparty,v.category_code)
              IS DISTINCT FROM (a.source_system,a.source_account_id,f.source_transaction_id,d.full_date,
               t.transaction_type_code,f.signed_amount,f.counterparty,f.category_code)""").fetchone()["n"]
        check("gold_transactions_derive_from_referenced_vault_events", transaction_lineage == 0,
              {"invalid_transaction_facts": transaction_lineage})
        raw_transaction_lineage = conn.execute("""SELECT count(*) AS n FROM boa_vault.sat_account_transaction v
            JOIN boa_vault.hub_account a USING(account_hk)
            LEFT JOIN boa_bronze.source_record r USING(raw_record_id)
            LEFT JOIN boa_audit.raw_run_record m ON m.raw_record_id=v.raw_record_id AND m.run_id=v.run_id
            WHERE r.raw_record_id IS NULL OR m.raw_record_id IS NULL OR r.source_system<>a.source_system
              OR r.entity_name<>'transactions' OR r.payload->>'account_id' IS DISTINCT FROM a.source_account_id
              OR r.source_record_key IS DISTINCT FROM v.source_transaction_id
              OR (CASE a.source_system WHEN 'SAVINGS' THEN r.payload->>'txn_id'
                  WHEN 'CARDS' THEN r.payload->>'auth_id' ELSE r.payload->>'event_id' END) IS DISTINCT FROM v.source_transaction_id
              OR r.business_date IS DISTINCT FROM v.transaction_date
              OR (CASE a.source_system WHEN 'SAVINGS' THEN ((r.payload->>'txn_timestamp')::timestamptz AT TIME ZONE 'UTC')::date
                  WHEN 'CARDS' THEN (r.payload->>'posted_date')::date ELSE (r.payload->>'event_date')::date END)
                  IS DISTINCT FROM v.transaction_date""").fetchone()["n"]
        check("all_vault_transaction_raw_provenance", raw_transaction_lineage == 0,
              {"invalid_transaction_raw_references": raw_transaction_lineage})
        queries = [("customer_360", "SELECT * FROM boa_gold.v_customer_360 WHERE business_date=%s AND enterprise_customer_id=%s", (dates[-1], "EC000001")), ("product_combinations", "SELECT * FROM boa_gold.v_product_combinations WHERE business_date=%s", (dates[-1],)), ("borrowing_daily", "SELECT * FROM boa_gold.v_borrowing_daily ORDER BY business_date", ()),
            ("transaction_daily", "SELECT * FROM boa_gold.v_transaction_daily WHERE business_date=%s", (dates[-1],)),
            ("merchant_spend", "SELECT merchant_name,merchant_category_code,sum(spend_amount) FROM boa_gold.v_top_merchants WHERE business_date BETWEEN %s::date-29 AND %s::date GROUP BY merchant_name,merchant_category_code ORDER BY sum(spend_amount) DESC LIMIT 20", (dates[-1], dates[-1]))]
        for name, query, params in queries:
            plan = conn.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query, params).fetchone()["QUERY PLAN"][0]
            explain.append({"query": name, "sql": query, "parameters": params, "plan": plan, "execution_ms": plan["Execution Time"]})
        counts = {"enterprise_customers": len(actual_profiles), "accounts": len(actual_accounts), "snapshots": len(actual_balances), "transactions": len(actual_transactions), "customer_dates": len(actual_customers), "published_dates": len(published)}
        database_counts = {}
        for table in ("boa_bronze.source_record", "boa_silver.enterprise_customer", "boa_silver.account", "boa_silver.account_daily_balance", "boa_silver.account_transaction", "boa_vault.hub_customer", "boa_vault.hub_account", "boa_vault.link_customer_account", "boa_vault.sat_customer_profile", "boa_vault.sat_account_profile", "boa_vault.sat_account_daily_balance", "boa_vault.sat_account_transaction", "boa_gold.fact_account_daily_snapshot", "boa_gold.fact_transaction"):
            database_counts[table] = conn.execute(f"SELECT count(*) AS n FROM {table}").fetchone()["n"]
    result = {"status": "PASSED" if all(row["passed"] for row in checks) else "FAILED", "generated_at": datetime.now(timezone.utc).isoformat(), "dataset": str(dataset), "batch_id": manifest["batch_id"], "seed": manifest["seed"], "counts": counts, "database_counts": database_counts, "elapsed_seconds": round(time.perf_counter() - started, 3), "checks": checks, "performance": [{"query": row["query"], "execution_ms": row["execution_ms"]} for row in explain]}
    (output / "validation.json").write_text(json.dumps(result, indent=2, default=_json_default) + "\n")
    (output / "explain_analyze.json").write_text(json.dumps(explain, indent=2, default=_json_default) + "\n")
    summary = [f"Validation: {result['status']}", f"Dataset: {dataset}", f"Counts: {counts}", f"Measured validation time: {result['elapsed_seconds']} seconds", ""]
    summary.extend(f"{'PASS' if row['passed'] else 'FAIL'} {row['name']}: {json.dumps(row['details'], default=_json_default)}" for row in checks)
    summary.append("\nObserved query execution times (single warm/cold mixed run; no before/after claims):")
    summary.extend(f"{row['query']}: {row['execution_ms']} ms; inspect explain_analyze.json for actual plan, loops, buffers and row counts." for row in explain)
    (output / "validation.txt").write_text("\n".join(summary) + "\n")
    return result


def main():
    result = validate(DATA_DIR, OUTPUT_DIR)
    for check in result["checks"]:
        print(f"{'PASS' if check['passed'] else 'FAIL'} {check['name']}")
    print(f"Warehouse validation: {result['status']}; details in {OUTPUT_DIR}")
    if result["status"] != "PASSED":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
