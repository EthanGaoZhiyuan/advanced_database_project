"""Relationship exploration using the actual exported Neo4j nodes and edges."""
from decimal import Decimal
import json

import streamlit as st

from boa_etl.graph_model import (GraphError, Neo4jClient, customer_network, graph_customers,
                       graph_status, node_identity, run_query)
from dashboard.queries import csv_bytes

ANALYSES = {
    "Customers with cards and loans": "borrowing_customers",
    "Shared-address borrowing": "household_borrowing",
    "Merchants used by customers with all three products": "shared_merchants",
    "Customers connected through addresses or merchants": "related_customers",
}
COLOURS = {"Customer": "#dbeafe", "Account": "#dcfce7", "Product": "#fef3c7",
           "Address": "#ede9fe", "Merchant": "#ffedd5"}


def network_dot(network):
    """Encode text as quoted DOT labels; duplicate display names remain separate."""
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    lines = ['digraph BoA {', 'graph [rankdir=LR, bgcolor="transparent"];',
             'node [shape=box, style="rounded,filled", fontname="Arial", color="#64748b"];',
             'edge [fontname="Arial", fontsize=10, color="#64748b"];']
    ids = {node_identity(n): f"n{i}" for i, n in enumerate(network["nodes"])}
    for node in network["nodes"]:
        key = node_identity(node)
        label, p = key[0], node["properties"]
        if label == "Customer":
            text = f"Customer\n{p.get('name') or 'Name unavailable'}\n{p['enterprise_customer_id']}"
        elif label == "Account":
            amount = Decimal(p["balance_cents"]) / 100
            text = f"Account · {p['source_system']}\n{p['source_account_id']}\nAUD {amount:,.2f} · {p['status']}"
        elif label == "Product":
            text = f"Product\n{p['code']}"
        elif label == "Address":
            text = f"Address\n{p['street_address']}\n{p['postcode']}"
        else:
            text = f"Merchant\n{p['name']}\nMCC {p['mcc']}"
        lines.append(f'{ids[key]} [label={quote(text)}, fillcolor={quote(COLOURS[label])}];')
    for edge in network["edges"]:
        source, target = ids[node_identity(edge["source"])], ids[node_identity(edge["target"])]
        label = edge["kind"]
        if label == "TRANSACTED_AT":
            p = edge["properties"]
            label += f"\n{p['count']} purchases · AUD {Decimal(p['total_amount_cents']) / 100:,.2f}"
        lines.append(f"{source} -> {target} [label={quote(label)}];")
    return "\n".join([*lines, "}"])


def display_rows(rows):
    """Keep cents exact until formatting the downloadable and visible AUD fields."""
    return [{(key[:-6] + "_aud" if key.endswith("_cents") else key):
             (f"{Decimal(value) / 100:.2f}" if key.endswith("_cents") else value)
             for key, value in row.items()} for row in rows]


def render_relationships(business_date, published_run_id):
    st.header("Relationships")
    st.caption("Explore account ownership, shared addresses and card merchants from the published banking data.")
    try:
        client = Neo4jClient(timeout=15)
        metadata = graph_status(client=client)
        if not metadata:
            st.info("No graph export is available. Run 09_build_graph.py, then refresh.")
            return
        st.caption(f"Graph business date: {metadata['business_date']} · Exported: {metadata['exported_at']}")
        if str(business_date) != str(metadata["business_date"]):
            st.warning("The graph export date differs from the selected PostgreSQL business date. Relationship results use the graph export date.")
        elif str(published_run_id) != str(metadata["published_run_id"]):
            st.warning("The warehouse has been republished since this graph export. Refresh Graph before relying on these results.")
        people = graph_customers(client=client)
        if not people:
            st.info("The graph contains no customers.")
            return
        labels = {r["enterprise_customer_id"]: f"{r['enterprise_customer_id']} · {r['customer_name'] or 'Name unavailable'}"
                  for r in people}
        selected = st.selectbox("Relationship customer", list(labels), format_func=labels.get, key="graph_customer")
        network = customer_network(selected, client=client)
        st.subheader("Customer relationship map")
        st.graphviz_chart(network_dot(network), use_container_width=True)
        st.caption(f"{len(network['nodes'])} nodes · {len(network['edges'])} relationships. "
                   "Blue: customer · Green: account · Yellow: product · Purple: address · Orange: merchant.")
        if network["truncated"]:
            st.info("The map shows the first 60 paths for readability. Analysis results below use the complete graph.")
        st.caption("Shared addresses and merchants indicate common context; they do not prove a personal relationship or merge customer identities.")
        analysis = st.selectbox("Relationship analysis", list(ANALYSES), key="graph_analysis")
        rows = run_query(ANALYSES[analysis], {"enterprise_customer_id": selected}, client=client)
        shown = display_rows(rows)
        st.subheader(analysis)
        if shown:
            st.dataframe(shown, use_container_width=True, hide_index=True)
        else:
            st.info("No matching relationships were found.")
        st.download_button("Download relationship analysis CSV", csv_bytes(shown),
                           file_name=f"boa_{ANALYSES[analysis]}_{metadata['business_date']}.csv",
                           mime="text/csv", key="graph_csv", disabled=not shown, on_click="ignore")
        st.caption("Borrowing includes card debt and loan principal, excluding savings. "
                   "Merchant purchases cover published history through the graph date. "
                   "Related customers are at most two shared-context steps away; each step can span several graph edges.")
    except GraphError:
        st.info("Relationships are unavailable. Start Neo4j and export the published warehouse data, then refresh.")
