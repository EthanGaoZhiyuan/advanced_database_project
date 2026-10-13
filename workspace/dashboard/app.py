"""Banking portfolio and transaction analysis over atomically published warehouse data."""
from __future__ import annotations

from decimal import Decimal
from datetime import timedelta
import os

import pandas as pd
import streamlit as st

from dashboard import queries as q

st.set_page_config(page_title="BoA Banking Analytics", layout="wide")
st.title("Bank of Australia · Banking Analytics")
st.caption("Fictional retail banking data · AUD · Illustrative analytics, not a regulatory capital or credit risk model")


def chart_frame(rows: list[dict], index: str) -> pd.DataFrame:
    # PostgreSQL and exports retain Decimal. Float conversion is confined to plotting.
    return pd.DataFrame([{k: float(v) if isinstance(v, Decimal) else v for k, v in row.items()}
                         for row in rows]).set_index(index)


def table(rows: list[dict]) -> None:
    if rows:
        st.dataframe(pd.DataFrame([{k: f"{v:,.2f}" if isinstance(v, Decimal) else v
                                   for k, v in row.items()} for row in rows]),
                     use_container_width=True, hide_index=True)
    else:
        st.info("No matching records are available for this selection.")


def main() -> None:
    pubs = q.publications()
    if not pubs:
        st.info("No business dates have been published. Run the numbered ETL steps in README.md to publish the sample data.")
        return
    dates = [r["business_date"] for r in pubs]
    business_date = st.sidebar.selectbox("Published business date", dates, key="report_date",
                                        format_func=lambda value: value.isoformat())
    selected_publication = next(r for r in pubs if r["business_date"] == business_date)
    st.sidebar.caption("The default is the latest common date successfully published across all three sources.")
    st.sidebar.button("Refresh from database", key="refresh")
    st.caption(f"Selected business date: {business_date} · Published: {selected_publication['published_at']} · "
               f"Run: {selected_publication['published_run_id']}")
    st.caption(f"Latest available common business date: {dates[0]} · "
               f"Selected-date account snapshots: {selected_publication['actual_account_count']:,}")
    people = q.customers(business_date)
    if not people:
        st.warning("This published date has no customer records. Check the warehouse validation report.")
        return

    tab_labels = ["Customer 360", "Product Holdings", "Borrowing Balances", "Transaction Activity"]
    graph_enabled = bool(os.environ.get("NEO4J_URL", "").strip())
    if graph_enabled:
        tab_labels.append("Relationships")
    tabs = st.tabs(tab_labels)
    customer_tab, products_tab, borrowing_tab, transactions_tab = tabs[:4]
    with customer_tab:
        st.header("Customer 360")
        labels = {r["enterprise_customer_id"]: f"{r['enterprise_customer_id']} · {r['full_name'] or 'Name unavailable'}"
                  for r in people}
        selected = st.selectbox("Enterprise customer", list(labels), format_func=labels.get, key="customer_id")
        profile = q.customer_360(business_date, selected)
        st.subheader(profile.get("full_name") or selected)
        profile_columns = ["enterprise_customer_id", "email", "phone", "date_of_birth", "age", "street_address",
                           "state", "postcode", "country"]
        table([{field: profile.get(field) for field in profile_columns}])
        a, b, c = st.columns(3)
        a.metric("Active accounts", profile["active_account_count"])
        b.metric("Active product categories", profile["active_product_category_count"])
        c.metric("Product combination", profile["product_combination"])
        a, b, c, d = st.columns(4)
        a.metric("Savings", q.aud(profile["total_savings"]))
        b.metric("Card outstanding", q.aud(profile["total_card_outstanding"]))
        c.metric("Loan principal", q.aud(profile["total_loan_principal"]))
        d.metric("Total borrowing", q.aud(profile["total_borrowing"]))
        utilisation = profile["credit_card_utilisation"]
        st.metric("Credit card utilisation", "Not applicable" if utilisation is None else f"{utilisation:.2%}")
        st.caption("Utilisation = outstanding on active cards / limits on active cards; undefined for a zero limit. "
                   "Age is calculated on the selected business date. Profile descriptions show current accepted values.")
        st.subheader("Accounts on the selected date")
        account_rows = q.accounts(business_date, selected)
        table(account_rows)
        st.download_button("Download customer accounts CSV", q.csv_bytes(account_rows),
                           file_name=f"boa_accounts_{selected}_{business_date}.csv", mime="text/csv", key="accounts_csv", on_click="ignore",
                           disabled=not account_rows)
        st.subheader("Daily balance observations (AUD)")
        trend = q.customer_trend(selected)
        if trend:
            st.line_chart(chart_frame(trend, "business_date"), use_container_width=True)
        st.caption("Each point is a daily closing balance. Values across dates are not added together.")

    with products_tab:
        st.header("Product Holdings")
        st.write("A holding means at least one active account in a category on the selected date, including active zero balances.")
        denominator = q.customer_population(business_date)
        st.metric("Customer population", f"{denominator:,}")
        st.caption("Percentage denominator: all accepted enterprise customers, including customers with no active accounts "
                   "or accounts that have not yet opened. Category percentages can overlap.")
        categories = q.product_categories(business_date)
        st.subheader("Customers by product category")
        table(categories)
        if categories:
            st.bar_chart(pd.DataFrame(categories).set_index("product_code")[["customer_count"]])
        st.subheader("Customers by product combination")
        combinations = q.product_combinations(business_date)
        table(combinations)
        st.subheader("Number of active categories")
        distribution = q.category_distribution(business_date)
        st.bar_chart(chart_frame(distribution, "active_product_category_count"))
        st.subheader("Cross-product ownership")
        table(q.cross_product(business_date))
        st.caption("Each pair counts distinct customers holding both categories. A customer holding all three appears in three pairs.")
        holding_rows = q.holding_customers(business_date)
        st.subheader("Customer holdings detail")
        table(holding_rows)
        st.download_button("Download product holdings CSV", q.csv_bytes(holding_rows),
                           file_name=f"boa_holdings_{business_date}.csv", mime="text/csv", key="holdings_csv", on_click="ignore")

    with borrowing_tab:
        st.header("Borrowing Balances")
        all_borrowing = q.borrowing_daily()
        daily = next((r for r in all_borrowing if r["business_date"] == business_date), None)
        if not daily:
            st.info("No borrowing observations are available for this date.")
            return
        a, b, c = st.columns(3)
        a.metric("Total credit card outstanding", q.aud(daily["total_card_outstanding"]))
        b.metric("Total loan principal outstanding", q.aud(daily["total_loan_principal"]))
        c.metric("Total borrowing", q.aud(daily["total_borrowing"]))
        st.caption("Total borrowing = card outstanding + outstanding loan principal. Savings are excluded. All values are AUD.")
        st.subheader("Borrowing split by product (AUD)")
        split = q.borrowing_split(business_date)
        st.bar_chart(chart_frame(split, "product_code"))
        st.subheader("Borrowing by customer (AUD)")
        borrowers = q.borrowing_customers(business_date)
        table(borrowers)
        st.download_button("Download borrowing CSV", q.csv_bytes(borrowers),
                           file_name=f"boa_borrowing_{business_date}.csv", mime="text/csv", key="borrowing_csv", on_click="ignore")
        st.subheader("Daily borrowing observations (AUD)")
        st.line_chart(chart_frame(all_borrowing, "business_date"))
        st.download_button("Download daily borrowing trend CSV", q.csv_bytes(all_borrowing),
                           file_name="boa_borrowing_daily.csv", mime="text/csv", key="borrowing_trend_csv", on_click="ignore")
        st.caption("These are daily point-in-time balances. Summing observations across dates would double count debt.")

    with transactions_tab:
        st.header("Transaction Activity")
        transaction_labels = {None: "All customers", **labels}
        transaction_customer = st.selectbox("Transaction customer", list(transaction_labels),
            format_func=transaction_labels.get, key="transaction_customer_id")
        activity = q.transaction_summary(business_date, transaction_customer)
        a, b, c, d = st.columns(4)
        a.metric("Transactions on selected date", f"{activity['transaction_count']:,}")
        b.metric("Savings movement", q.aud(activity["savings_movement"]))
        c.metric("Card debt movement", q.aud(activity["card_movement"]))
        d.metric("Loan principal movement", q.aud(activity["loan_movement"]))
        st.caption("Positive signed amounts increase the relevant savings balance or debt; negative amounts reduce it. "
                   "Opening funding is an explicit transaction. All amounts are AUD; these movements are separate from daily balances.")
        st.subheader("Transactions by type on the selected date")
        types = q.transaction_types(business_date, transaction_customer)
        if types:
            counts_chart, amounts_chart = st.columns(2)
            frame = chart_frame(types, "transaction_type_code")
            with counts_chart:
                st.caption("Number of transactions")
                st.bar_chart(frame[["transaction_count"]])
            with amounts_chart:
                st.caption("Signed balance movements (AUD)")
                st.bar_chart(frame[["total_signed_amount"]])
        else:
            st.info("No transactions occurred for this customer selection on the published date.")
        st.subheader("Transaction detail")
        transaction_rows = q.transactions(business_date, transaction_customer)
        table(transaction_rows)
        st.download_button("Download transactions CSV", q.csv_bytes(transaction_rows),
                           file_name=f"boa_transactions_{transaction_customer or 'all'}_{business_date}.csv",
                           mime="text/csv", key="transactions_csv", on_click="ignore", disabled=not transaction_rows)
        start_date = business_date - timedelta(days=29)
        st.subheader("Transaction count over the last 30 calendar days")
        st.caption(f"Window: {start_date} to {business_date}, inclusive. Published days without events appear as zero.")
        transaction_trend = q.transaction_trend(business_date, transaction_customer)
        if transaction_trend:
            st.line_chart(chart_frame(transaction_trend, "business_date"))
        st.subheader("Top card merchants over the last 30 calendar days (AUD)")
        table(q.top_merchants(business_date, transaction_customer))
        st.caption("Top 20 merchants by gross positive card purchase amounts for the selected customers and window. "
                   "Merchant category codes remain text. Opening funding, payments, refunds and fees are excluded; this is not net card debt.")

    if graph_enabled:
        with tabs[4]:
            from dashboard.graph_view import render_relationships

            render_relationships(business_date, selected_publication["published_run_id"])


try:
    main()
except Exception as exc:
    st.error("The dashboard could not read the reporting database. Confirm that services are healthy and the pipeline has published a date.")
    with st.expander("Technical error"):
        st.code(f"{type(exc).__name__}: {exc}")
