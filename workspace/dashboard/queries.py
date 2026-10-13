"""Read-only reporting queries shared by the UI and integration checks."""
from __future__ import annotations

import csv
from datetime import date, timedelta
from decimal import Decimal
import io
from typing import Any

from boa_etl.database import connect


def query(sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    with connect() as conn:
        return conn.execute(sql, params).fetchall()


def publications() -> list[dict]:
    return query("SELECT * FROM boa_audit.published_day ORDER BY business_date DESC")


def customers(business_date: date) -> list[dict]:
    return query("SELECT enterprise_customer_id, full_name FROM boa_gold.v_customer_360 "
                 "WHERE business_date = %s ORDER BY enterprise_customer_id", (business_date,))


def customer_360(business_date: date, customer_id: str) -> dict:
    rows = query("SELECT * FROM boa_gold.v_customer_360 WHERE business_date = %s "
                 "AND enterprise_customer_id = %s", (business_date, customer_id))
    return rows[0] if rows else {}


def accounts(business_date: date, customer_id: str) -> list[dict]:
    return query("SELECT source_system, source_account_id, product_code, account_status, "
                 "savings_balance, card_outstanding, loan_principal_outstanding, credit_limit_amount "
                 "FROM boa_gold.v_account_snapshot WHERE business_date = %s AND enterprise_customer_id = %s "
                 "ORDER BY product_code, source_system, source_account_id", (business_date, customer_id))


def customer_trend(customer_id: str) -> list[dict]:
    return query("SELECT business_date, total_savings, total_card_outstanding, total_loan_principal, "
                 "total_borrowing FROM boa_gold.v_customer_360 WHERE enterprise_customer_id = %s "
                 "ORDER BY business_date", (customer_id,))


def product_categories(business_date: date) -> list[dict]:
    return query("SELECT product_code, customer_count, percentage AS percentage_of_customers FROM boa_gold.v_product_holdings "
                 "WHERE business_date = %s ORDER BY CASE product_code "
                 "WHEN 'SAVINGS' THEN 1 WHEN 'CREDIT_CARD' THEN 2 ELSE 3 END", (business_date,))


def product_combinations(business_date: date) -> list[dict]:
    return query("SELECT product_combination, customer_count, percentage AS percentage_of_customers FROM boa_gold.v_product_combinations "
                 "WHERE business_date = %s ORDER BY customer_count DESC, product_combination", (business_date,))


def customer_population(business_date: date) -> int:
    rows = query("SELECT population_count FROM boa_gold.v_product_holdings WHERE business_date = %s LIMIT 1",
                 (business_date,))
    return rows[0]["population_count"] if rows else 0


def category_distribution(business_date: date) -> list[dict]:
    return query("SELECT category_count AS active_product_category_count, customer_count "
                 "FROM boa_gold.v_product_category_distribution WHERE business_date = %s ORDER BY category_count",
                 (business_date,))


def holding_customers(business_date: date) -> list[dict]:
    return query("SELECT enterprise_customer_id, full_name, active_account_count, active_product_category_count, "
                 "product_combination FROM boa_gold.v_customer_360 WHERE business_date = %s "
                 "ORDER BY enterprise_customer_id", (business_date,))


def cross_product(business_date: date) -> list[dict]:
    return query("SELECT product_a AS first_product, product_b AS second_product, customer_count "
                 "FROM boa_gold.v_cross_product_ownership WHERE business_date = %s AND product_a < product_b "
                 "ORDER BY product_a, product_b", (business_date,))


def borrowing_daily() -> list[dict]:
    return query("SELECT * FROM boa_gold.v_borrowing_daily ORDER BY business_date")


def borrowing_customers(business_date: date) -> list[dict]:
    return query("SELECT enterprise_customer_id, full_name, total_card_outstanding, total_loan_principal, "
                 "total_borrowing, credit_card_utilisation FROM boa_gold.v_customer_360 "
                 "WHERE business_date = %s ORDER BY total_borrowing DESC, enterprise_customer_id", (business_date,))


def borrowing_split(business_date: date) -> list[dict]:
    return query("SELECT product_code, borrowing_amount FROM boa_gold.v_borrowing_by_product "
                 "WHERE business_date = %s ORDER BY product_code",
                 (business_date,))


def transactions(business_date: date, customer_id: str | None = None) -> list[dict]:
    return query("SELECT business_date, enterprise_customer_id, full_name, source_system, source_account_id, "
                 "source_transaction_id, product_code, transaction_type_code, signed_amount, counterparty, category_code "
                 "FROM boa_gold.v_customer_transactions WHERE business_date = %s "
                 "AND (%s::text IS NULL OR enterprise_customer_id = %s) "
                 "ORDER BY enterprise_customer_id, source_system, source_account_id, source_transaction_id",
                 (business_date, customer_id, customer_id))


def transaction_summary(business_date: date, customer_id: str | None = None) -> dict:
    return query("SELECT coalesce(sum(transaction_count),0)::bigint AS transaction_count, "
                 "coalesce(sum(total_signed_amount) FILTER(WHERE product_code='SAVINGS'),0) AS savings_movement, "
                 "coalesce(sum(total_signed_amount) FILTER(WHERE product_code='CREDIT_CARD'),0) AS card_movement, "
                 "coalesce(sum(total_signed_amount) FILTER(WHERE product_code='LOAN'),0) AS loan_movement "
                 "FROM boa_gold.v_customer_transaction_daily WHERE business_date = %s "
                 "AND (%s::text IS NULL OR enterprise_customer_id = %s)",
                 (business_date, customer_id, customer_id))[0]


def transaction_types(business_date: date, customer_id: str | None = None) -> list[dict]:
    return query("SELECT transaction_type_code, sum(transaction_count)::bigint AS transaction_count, "
                 "sum(total_signed_amount) AS total_signed_amount "
                 "FROM boa_gold.v_customer_transaction_daily WHERE business_date = %s "
                 "AND (%s::text IS NULL OR enterprise_customer_id = %s) "
                 "GROUP BY transaction_type_code ORDER BY transaction_type_code",
                 (business_date, customer_id, customer_id))


def transaction_trend(business_date: date, customer_id: str | None = None) -> list[dict]:
    return query("SELECT p.business_date, coalesce(sum(t.transaction_count),0)::bigint AS transaction_count "
                 "FROM boa_audit.published_day p LEFT JOIN boa_gold.v_customer_transaction_daily t "
                 "ON t.business_date=p.business_date AND (%s::text IS NULL OR t.enterprise_customer_id=%s) "
                 "WHERE p.business_date BETWEEN %s AND %s GROUP BY p.business_date ORDER BY p.business_date",
                 (customer_id, customer_id, business_date - timedelta(days=29), business_date))


def top_merchants(business_date: date, customer_id: str | None = None) -> list[dict]:
    return query("SELECT merchant_name, merchant_category_code, sum(purchase_count)::bigint AS purchase_count, "
                 "sum(spend_amount) AS spend_amount FROM boa_gold.v_customer_merchant_spend "
                 "WHERE business_date BETWEEN %s AND %s AND (%s::text IS NULL OR enterprise_customer_id=%s) "
                 "GROUP BY merchant_name, merchant_category_code ORDER BY spend_amount DESC, merchant_name, merchant_category_code LIMIT 20",
                 (business_date - timedelta(days=29), business_date, customer_id, customer_id))


def csv_bytes(rows: list[dict]) -> bytes:
    """Preserve exact decimal amounts in downloads; chart conversion is presentation only."""
    if not rows:
        return b""
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue().encode("utf-8")


def aud(value: Any) -> str:
    return f"AUD {Decimal(str(value or 0)):,.2f}"
