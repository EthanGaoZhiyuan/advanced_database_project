"""Independently reconcile the complete Graph with published Gold facts.

This read-only check deliberately reads dimensions/facts instead of the exporter's
reporting views. Equal counts alone cannot detect ownership or amount corruption.
"""
from collections import Counter
from datetime import date, datetime, timezone
from decimal import Decimal
import json
from pathlib import Path

from boa_etl.database import connect
from boa_etl.graph_model import GraphError, LABELS, RELATIONSHIPS, Neo4jClient, node_identity, run_query

FIELDS = {
    "Customer": ("enterprise_customer_id", "name", "state", "postcode", "street_address"),
    "Account": ("source_system", "source_account_id", "status", "balance_cents", "balance"),
    "Product": ("code",), "Address": ("street_address", "postcode"), "Merchant": ("name", "mcc"),
}


def _gold_graph(business_date, namespace):
    """Build expected identities, properties and directed relationships from facts."""
    selected = date.fromisoformat(business_date) if isinstance(business_date, str) else business_date
    with connect() as conn, conn.transaction():
        conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        publication = conn.execute("""SELECT business_date,published_run_id FROM boa_audit.published_day
            WHERE (%s::date IS NULL OR business_date=%s) ORDER BY business_date DESC LIMIT 1""",
            (selected, selected)).fetchone()
        if not publication:
            raise GraphError("No published Gold date is available for graph validation")
        selected = publication["business_date"]
        customers = conn.execute("""SELECT enterprise_customer_id,full_name AS name,state,postcode,street_address
            FROM boa_gold.dim_customer""").fetchall()
        products = conn.execute("SELECT product_code AS code FROM boa_gold.dim_product").fetchall()
        accounts = conn.execute("""SELECT c.enterprise_customer_id,a.source_system,a.source_account_id,
            p.product_code,f.account_status AS status,
            f.savings_balance+f.card_outstanding+f.loan_principal_outstanding AS amount
            FROM boa_gold.fact_account_daily_snapshot f
            JOIN boa_gold.dim_account a USING(account_sk)
            JOIN boa_gold.dim_customer c ON c.customer_sk=f.customer_sk
            JOIN boa_gold.dim_product p ON p.product_sk=f.product_sk
            JOIN boa_gold.dim_date d USING(date_sk)
            JOIN boa_audit.published_day pub ON pub.business_date=d.full_date AND pub.published_run_id=f.load_run_id
            WHERE d.full_date=%s""", (selected,)).fetchall()
        purchases = conn.execute("""SELECT a.source_system,a.source_account_id,f.counterparty AS name,
            coalesce(f.category_code,'') AS mcc,count(*) AS count,sum(f.signed_amount) AS amount
            FROM boa_gold.fact_transaction f
            JOIN boa_gold.dim_account a USING(account_sk)
            JOIN boa_gold.dim_product p ON p.product_sk=f.product_sk
            JOIN boa_gold.dim_transaction_type t USING(transaction_type_sk)
            JOIN boa_gold.dim_date d USING(date_sk)
            JOIN boa_audit.published_day pub ON pub.business_date=d.full_date AND pub.published_run_id=f.load_run_id
            WHERE d.full_date<=%s AND p.product_code='CREDIT_CARD' AND t.transaction_type_code='PURCHASE'
              AND f.signed_amount>0 AND f.counterparty IS NOT NULL AND f.counterparty<>'Opening balance'
            GROUP BY a.source_system,a.source_account_id,f.counterparty,coalesce(f.category_code,'')""", (selected,)).fetchall()
    metadata = {"business_date": selected.isoformat(), "published_run_id": str(publication["published_run_id"])}
    nodes, edges = {}, []

    def node(label, properties):
        value = {"labels": [label], "properties": {**properties, **metadata, "namespace": namespace}}
        nodes[node_identity(value)] = value
        return value

    def money(amount):
        scaled = Decimal(amount) * 100
        if scaled != scaled.to_integral_value():
            raise GraphError("Gold contains a non-cent monetary amount")
        return format(amount, ".2f"), int(scaled)

    def edge(source, kind, target, properties=None):
        edges.append({"source": source, "kind": kind, "target": target,
                      "properties": {"namespace": namespace, **(properties or {})}})

    people = {row["enterprise_customer_id"]: node("Customer", row) for row in customers}
    categories = {row["code"]: node("Product", row) for row in products}
    for row in customers:
        if row["street_address"] and row["postcode"]:
            address = node("Address", {key: row[key] for key in ("street_address", "postcode")})
            edge(people[row["enterprise_customer_id"]], "LIVES_AT", address)
    owned = {}
    for row in accounts:
        balance, cents = money(row["amount"])
        account = node("Account", {key: row[key] for key in ("source_system", "source_account_id", "status")} |
                       {"balance": balance, "balance_cents": cents})
        owned[row["source_system"], row["source_account_id"]] = account
        edge(people[row["enterprise_customer_id"]], "HOLDS", account)
        edge(account, "OF_PRODUCT", categories[row["product_code"]])
    for row in purchases:
        merchant = node("Merchant", {"name": row["name"], "mcc": row["mcc"]})
        amount, cents = money(row["amount"])
        edge(owned[row["source_system"], row["source_account_id"]], "TRANSACTED_AT", merchant,
             {"count": row["count"], "total_amount": amount, "total_amount_cents": cents})
    return {"nodes": list(nodes.values()), "edges": edges, **metadata}


def _node_row(node):
    label = node_identity(node)[0]
    fields = (*FIELDS[label], "business_date", "published_run_id")
    return [node_identity(node), {key: node["properties"].get(key) for key in fields}]


def _edge_row(edge):
    properties = edge["properties"]
    fields = ("namespace", "count", "total_amount", "total_amount_cents") if edge["kind"] == "TRANSACTED_AT" else ("namespace",)
    return [node_identity(edge["source"]), edge["kind"], node_identity(edge["target"]),
            {key: properties.get(key) for key in fields}]


def reconcile(expected, actual):
    """Compare complete multisets; detect equal-count corruption and duplicates."""
    checks = []
    for collection, groups, normalize in (("nodes", LABELS, _node_row), ("edges", RELATIONSHIPS, _edge_row)):
        for group in groups:
            def rows(population):
                return Counter(json.dumps(normalize(row), sort_keys=True, ensure_ascii=False)
                    for row in population[collection]
                    if (node_identity(row)[0] if collection == "nodes" else row["kind"]) == group)
            wanted, found = rows(expected), rows(actual)
            checks.append({"name": group, "status": "PASSED" if wanted == found else "FAILED",
                           "expected": sum(wanted.values()), "actual": sum(found.values()),
                           "missing_or_changed": sum((wanted - found).values()),
                           "unexpected_or_changed": sum((found - wanted).values())})
    # Unknown managed relationship types must not silently fall outside the groups.
    unexpected = sum(edge["kind"] not in RELATIONSHIPS for edge in actual["edges"])
    checks.append({"name": "managed_relationship_types", "status": "PASSED" if not unexpected else "FAILED",
                   "unexpected": unexpected})
    return checks


def validate_graph(business_date=None, namespace="boa", url=None, auth=None,
                   output=Path(__file__).resolve().parents[1] / "output/graph_validation.json"):
    result = {"status": "FAILED", "namespace": namespace, "checked_at": datetime.now(timezone.utc).isoformat()}
    try:
        expected = _gold_graph(business_date, namespace)
        result.update(business_date=expected["business_date"], published_run_id=expected["published_run_id"])
        client = Neo4jClient(url=url, auth=auth, timeout=60)
        nodes, edges = client.transaction([
            ("""MATCH (n {namespace:$namespace}) WHERE n.boa_managed=true
                RETURN labels(n) AS labels,properties(n) AS properties""", {"namespace": namespace}),
            ("""MATCH (a)-[r]->(b) WHERE r.namespace=$namespace AND r.boa_managed=true
                RETURN {labels:labels(a),properties:properties(a)} AS source,type(r) AS kind,
                  {labels:labels(b),properties:properties(b)} AS target,properties(r) AS properties""", {"namespace": namespace})])
        result["checks"] = reconcile(expected, {"nodes": nodes, "edges": edges})
        # Execute the classroom queries as part of acceptance, even for empty results.
        customer = next(node["properties"]["enterprise_customer_id"] for node in expected["nodes"]
                        if "Customer" in node["labels"])
        result["query_rows"] = {name: len(run_query(name, {"enterprise_customer_id": customer},
                                                  namespace=namespace, client=client))
                                for name in ("borrowing_customers", "household_borrowing", "shared_merchants", "related_customers")}
        result["status"] = "PASSED" if all(check["status"] == "PASSED" for check in result["checks"]) else "FAILED"
        return result
    except Exception as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        if output is not None:
            path = Path(output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
