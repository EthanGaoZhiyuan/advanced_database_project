"""Optional property-graph projection of a consistent published Gold snapshot.

The relational pipeline never depends on Neo4j. HTTP transactions use only
stdlib urllib; financial graph properties preserve decimal text and exact cents.
"""
from __future__ import annotations

import base64
from datetime import date, datetime, timezone
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid

from boa_etl.database import connect

ROOT = Path(__file__).resolve().parents[1]
LABELS = ("Customer", "Account", "Product", "Merchant", "Address")
RELATIONSHIPS = ("HOLDS", "OF_PRODUCT", "LIVES_AT", "TRANSACTED_AT")
NODE_KEYS = {"Customer": ("enterprise_customer_id",), "Account": ("source_system", "source_account_id"),
             "Product": ("code",), "Merchant": ("name", "mcc"), "Address": ("street_address", "postcode")}


class GraphError(RuntimeError):
    """The optional graph service rejected or could not complete a request."""


def _json_value(value):
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    raise TypeError(f"Unsupported graph JSON value: {type(value).__name__}")


class Neo4jClient:
    def __init__(self, url=None, auth=None, timeout=10):
        self.url = (url or os.environ.get("NEO4J_URL") or "http://neo4j:7474").rstrip("/")
        credentials = auth or os.environ.get("NEO4J_AUTH", "neo4j/boa_local_graph")
        if "/" not in credentials:
            raise GraphError("NEO4J_AUTH must contain username/password")
        username, password = credentials.split("/", 1)
        self.authorization = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
        self.timeout = timeout

    def transaction(self, statements):
        """Commit all parameterized statements atomically, or raise on any server error."""
        body = json.dumps({"statements": [
            {"statement": statement, "parameters": parameters or {}, "resultDataContents": ["row"]}
            for statement, parameters in statements]}, ensure_ascii=False, allow_nan=False,
            default=_json_value).encode("utf-8")
        request = Request(self.url + "/db/neo4j/tx/commit", data=body, method="POST",
                          headers={"Content-Type": "application/json", "Accept": "application/json",
                                   "Authorization": self.authorization})
        try:
            with urlopen(request, timeout=self.timeout) as response:
                result = json.load(response, parse_float=Decimal)
        except HTTPError as exc:
            try:
                errors = json.loads(exc.read()).get("errors", [])
                detail = "; ".join(row.get("message", "Request rejected") for row in errors)
            except (ValueError, AttributeError):
                detail = exc.reason
            raise GraphError(f"Neo4j HTTP {exc.code}: {detail}") from None
        except (URLError, TimeoutError, OSError, ValueError) as exc:
            raise GraphError(f"Neo4j is unavailable: {getattr(exc, 'reason', exc)}") from None
        if result.get("errors"):
            detail = "; ".join(f"{row.get('code', 'Neo4jError')}: {row.get('message', '')}" for row in result["errors"])
            raise GraphError(detail)
        return [[dict(zip(item["columns"], row["row"])) for row in item.get("data", [])]
                for item in result.get("results", [])]

    def query(self, statement, parameters=None):
        return self.transaction([(statement, parameters or {})])[0]


def load_queries():
    """Load the same named Cypher examples used in Neo4j Browser and the dashboard."""
    text = (ROOT / "graph" / "queries.cypher").read_text(encoding="utf-8")
    sections = re.split(r"(?m)^// query:\s*([a-z_]+)\s*$", text)
    return {sections[index]: sections[index + 1].strip().rstrip(";")
            for index in range(1, len(sections), 2)}


def run_query(name, parameters=None, namespace="boa", client=None):
    statements = load_queries()
    if name not in statements:
        raise ValueError(f"Unknown graph query: {name}")
    return (client or Neo4jClient()).query(statements[name], {**(parameters or {}), "namespace": namespace})


def graph_status(namespace="boa", client=None):
    rows = (client or Neo4jClient()).query("""
        MATCH (p:Product {namespace:$namespace,code:'SAVINGS',boa_managed:true})
        RETURN p.business_date AS business_date,p.exported_at AS exported_at,
          p.published_run_id AS published_run_id
    """, {"namespace": namespace})
    return rows[0] if rows else {}


def node_identity(node):
    """Use business keys, never display names or transient Neo4j element IDs."""
    labels = [label for label in node["labels"] if label in NODE_KEYS]
    if len(labels) != 1:
        raise GraphError("Expected exactly one BoA entity label on a graph node")
    label = labels[0]
    properties = node["properties"]
    return (label, properties["namespace"], *(properties[key] for key in NODE_KEYS[label]))


def graph_customers(namespace="boa", client=None):
    return (client or Neo4jClient()).query("""MATCH (c:Customer {namespace:$namespace})
        WHERE c.boa_managed=true
        RETURN c.enterprise_customer_id AS enterprise_customer_id,c.name AS customer_name
        ORDER BY enterprise_customer_id""", {"namespace": namespace})


def customer_network(enterprise_customer_id, namespace="boa", client=None, max_paths=60):
    """Return a bounded visual neighbourhood, retaining exact business identities."""
    if type(max_paths) is not int or not 1 <= max_paths <= 200:
        raise ValueError("max_paths must be an integer from 1 to 200")
    statement = (ROOT / "graph" / "customer_network.cypher").read_text(encoding="utf-8")
    rows = (client or Neo4jClient()).query(statement, {"namespace": namespace,
        "enterprise_customer_id": enterprise_customer_id, "path_limit": max_paths + 1})
    nodes, edges = {}, {}
    for row in rows[:max_paths]:
        for node in row["nodes"]:
            nodes[node_identity(node)] = node
        for edge in row["edges"]:
            key = (node_identity(edge["source"]), edge["kind"], node_identity(edge["target"]))
            edges[key] = edge
    return {"nodes": list(nodes.values()), "edges": list(edges.values()),
            "truncated": len(rows) > max_paths, "displayed_paths": min(len(rows), max_paths)}


def _money(value):
    amount = value if isinstance(value, Decimal) else Decimal(str(value))
    cents = amount * 100
    if not amount.is_finite() or cents != cents.to_integral_value() or abs(cents) > 9223372036854775807:
        raise ValueError("Graph money must have exact cents within the signed 64-bit integer range")
    return format(amount, ".2f"), int(cents)


def _snapshot(business_date):
    selected = date.fromisoformat(business_date) if isinstance(business_date, str) else business_date
    with connect() as conn, conn.transaction():
        conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        publication = conn.execute("""SELECT * FROM boa_audit.published_day
            WHERE (%s::date IS NULL OR business_date=%s) ORDER BY business_date DESC LIMIT 1""",
            (selected, selected)).fetchone()
        if not publication:
            raise GraphError("No successful common publication exists for the requested business date")
        selected = publication["business_date"]
        customers = conn.execute("""SELECT enterprise_customer_id,full_name AS name,state,postcode,street_address
            FROM boa_gold.v_customer_360 WHERE business_date=%s ORDER BY enterprise_customer_id""", (selected,)).fetchall()
        accounts = conn.execute("""SELECT source_system,source_account_id,enterprise_customer_id,product_code,
            account_status AS status,savings_balance+card_outstanding+loan_principal_outstanding AS balance
            FROM boa_gold.v_account_snapshot WHERE business_date=%s ORDER BY source_system,source_account_id""", (selected,)).fetchall()
        products = conn.execute("""SELECT product_code AS code FROM boa_gold.v_product_holdings
            WHERE business_date=%s ORDER BY product_code""", (selected,)).fetchall()
        activity = conn.execute("""SELECT source_system,source_account_id,counterparty AS name,
            coalesce(category_code,'') AS mcc,count(*)::bigint AS count,sum(signed_amount) AS total_amount
            FROM boa_gold.v_customer_transactions
            WHERE business_date<=%s AND product_code='CREDIT_CARD' AND transaction_type_code='PURCHASE'
              AND signed_amount>0 AND counterparty IS NOT NULL AND counterparty<>'Opening balance'
            GROUP BY source_system,source_account_id,counterparty,coalesce(category_code,'')
            ORDER BY source_system,source_account_id,counterparty,coalesce(category_code,'')""", (selected,)).fetchall()
    if not customers or not accounts or len(products) != 3:
        raise GraphError("The published warehouse has no complete customer/account/product population")
    addresses = sorted({(row["street_address"], row["postcode"]) for row in customers
                        if row["street_address"] and row["postcode"]})
    merchants = sorted({(row["name"], row["mcc"]) for row in activity})
    for row in accounts:
        row["balance"], row["balance_cents"] = _money(row["balance"])
    for row in activity:
        row["total_amount"], row["total_amount_cents"] = _money(row["total_amount"])
    return {"publication": publication, "customers": customers, "accounts": accounts, "products": products,
            "merchants": [{"name": name, "mcc": mcc} for name, mcc in merchants],
            "addresses": [{"street_address": street, "postcode": postcode} for street, postcode in addresses],
            "activity": activity}


def export_graph(business_date=None, namespace="boa", url=None, auth=None, output=Path(__file__).resolve().parents[1] / "output/graph_export.json"):
    """Publish an atomic namespaced graph projection, retaining other namespaces.

    Balances describe the selected day. Merchant edges aggregate positive card
    purchases on all published dates through that day, excluding opening funding.
    """
    if not isinstance(namespace, str) or not namespace.strip():
        raise ValueError("Graph namespace must be nonempty text")
    started = time.perf_counter()
    result = {"status": "FAILED", "namespace": namespace,
              "started_at": datetime.now(timezone.utc).isoformat()}
    try:
        snapshot = _snapshot(business_date)
        publication = snapshot["publication"]
        parameters = {"namespace": namespace, "export_token": uuid.uuid4().hex,
                      "business_date": publication["business_date"].isoformat(),
                      "exported_at": datetime.now(timezone.utc).isoformat(),
                      "published_run_id": str(publication["published_run_id"])}
        result.update(business_date=parameters["business_date"], published_run_id=parameters["published_run_id"],
                      exported_at=parameters["exported_at"])
        client = Neo4jClient(url=url, auth=auth, timeout=60)
        result["neo4j"] = client.query("CALL dbms.components() YIELD name,versions,edition "
                                       "RETURN name,versions[0] AS version,edition")
        keys = NODE_KEYS
        # Neo4j separates schema transactions from data transactions. Composite
        # uniqueness includes namespace, so test and classroom graphs cannot merge.
        client.transaction([(f"CREATE CONSTRAINT boa_{label.lower()}_identity IF NOT EXISTS "
                             f"FOR (n:{label}) REQUIRE (n.namespace," + ",".join(f"n.{key}" for key in fields) + ") IS UNIQUE", {})
                            for label, fields in keys.items()])
        statements = [("""MERGE (p:Product {namespace:$namespace,code:'SAVINGS'})
            SET p.export_token=$export_token,p.boa_managed=true""", parameters)]
        metadata = """SET n.boa_managed=true,n.export_token=$export_token,n.business_date=$business_date,
            n.exported_at=$exported_at,n.published_run_id=$published_run_id"""

        def batch(statement, rows):
            for offset in range(0, len(rows), 500):
                statements.append((statement, {**parameters, "rows": rows[offset:offset + 500]}))

        for label, collection in (("Customer", "customers"), ("Account", "accounts"), ("Product", "products"),
                                  ("Merchant", "merchants"), ("Address", "addresses")):
            identity = ",".join(f"{key}:row.{key}" for key in keys[label])
            # Additional source link keys remain useful for inspection but are not
            # graph identity; all values enter Cypher as parameters.
            batch(f"UNWIND $rows AS row MERGE (n:{label} {{namespace:$namespace,{identity}}}) "
                  f"SET n += row {metadata}", snapshot[collection])
        edge_metadata = "SET r.namespace=$namespace,r.boa_managed=true,r.export_token=$export_token"
        batch("""UNWIND $rows AS row
            MATCH (c:Customer {namespace:$namespace,enterprise_customer_id:row.enterprise_customer_id})
            MATCH (a:Account {namespace:$namespace,source_system:row.source_system,source_account_id:row.source_account_id})
            MERGE (c)-[r:HOLDS]->(a) """ + edge_metadata, snapshot["accounts"])
        batch("""UNWIND $rows AS row
            MATCH (a:Account {namespace:$namespace,source_system:row.source_system,source_account_id:row.source_account_id})
            MATCH (p:Product {namespace:$namespace,code:row.product_code})
            MERGE (a)-[r:OF_PRODUCT]->(p) """ + edge_metadata, snapshot["accounts"])
        residents = [row for row in snapshot["customers"] if row["street_address"] and row["postcode"]]
        batch("""UNWIND $rows AS row
            MATCH (c:Customer {namespace:$namespace,enterprise_customer_id:row.enterprise_customer_id})
            MATCH (a:Address {namespace:$namespace,street_address:row.street_address,postcode:row.postcode})
            MERGE (c)-[r:LIVES_AT]->(a) """ + edge_metadata, residents)
        batch("""UNWIND $rows AS row
            MATCH (a:Account {namespace:$namespace,source_system:row.source_system,source_account_id:row.source_account_id})
            MATCH (m:Merchant {namespace:$namespace,name:row.name,mcc:row.mcc})
            MERGE (a)-[r:TRANSACTED_AT]->(m)
            SET r.count=row.count,r.total_amount=row.total_amount,r.total_amount_cents=row.total_amount_cents
            """ + edge_metadata, snapshot["activity"])
        expected = {"nodes": {label: len(snapshot[collection]) for label, collection in
                    (("Customer", "customers"), ("Account", "accounts"), ("Product", "products"),
                     ("Merchant", "merchants"), ("Address", "addresses"))},
                    "relationships": {"HOLDS": len(snapshot["accounts"]), "OF_PRODUCT": len(snapshot["accounts"]),
                                      "LIVES_AT": len(residents), "TRANSACTED_AT": len(snapshot["activity"])}}
        # Stale relationships/nodes belong to this exporter and namespace only.
        # MERGE preserves existing identities on an unchanged or corrected export.
        statements.extend([
            ("""MATCH (a {namespace:$namespace})-[r]->(b {namespace:$namespace})
                WHERE r.namespace=$namespace AND r.boa_managed=true AND r.export_token<>$export_token
                DELETE r""", parameters),
            ("""MATCH (n {namespace:$namespace}) WHERE n.boa_managed=true AND n.export_token<>$export_token
                AND NOT EXISTS { MATCH (n)--() } DELETE n""", parameters),
            # A failed count assertion raises inside Neo4j, rolling back the entire
            # export. It also protects stale nodes attached to unrelated graphs.
            ("""CALL {
                  MATCH (n {namespace:$namespace}) WHERE n.boa_managed=true
                  RETURN collect(labels(n)) AS node_labels
                }
                CALL {
                  MATCH (a {namespace:$namespace})-[r]->(b {namespace:$namespace})
                  WHERE r.namespace=$namespace AND r.boa_managed=true
                  RETURN collect(type(r)) AS relationship_types
                }
                RETURN 1 / CASE WHEN size(node_labels)=$node_total AND size(relationship_types)=$relationship_total
                  AND all(label IN $labels WHERE size([names IN node_labels WHERE label IN names])=$expected_nodes[label])
                  AND all(kind IN $relationships WHERE size([name IN relationship_types WHERE name=kind])=$expected_relationships[kind])
                  THEN 1 ELSE 0 END AS counts_valid""",
             {**parameters, "labels": LABELS, "relationships": RELATIONSHIPS,
              "expected_nodes": expected["nodes"], "expected_relationships": expected["relationships"],
              "node_total": sum(expected["nodes"].values()), "relationship_total": sum(expected["relationships"].values())}),
            ("""MATCH (n {namespace:$namespace}) WHERE n.boa_managed=true
                UNWIND labels(n) AS label RETURN label,count(*) AS count ORDER BY label""", parameters),
            ("""MATCH (a {namespace:$namespace})-[r]->(b {namespace:$namespace})
                WHERE r.namespace=$namespace AND r.boa_managed=true
                RETURN type(r) AS relationship,count(*) AS count ORDER BY relationship""", parameters)])
        committed = client.transaction(statements)
        nodes = {label: 0 for label in LABELS}
        nodes.update({row["label"]: row["count"] for row in committed[-2]})
        relationships = {kind: 0 for kind in RELATIONSHIPS}
        relationships.update({row["relationship"]: row["count"] for row in committed[-1]})
        result.update(nodes=nodes, relationships=relationships, source_counts=expected,
                      http_data_statements=len(statements), merchant_history="All published dates through business_date")
        if nodes != expected["nodes"] or relationships != expected["relationships"]:
            raise GraphError("Exported graph counts differ from the selected Gold population")
        result["status"] = "PASSED"
        return result
    except Exception as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        result["elapsed_seconds"] = round(time.perf_counter() - started, 3)
        if output is not None:
            path = Path(output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(result, indent=2, default=_json_value) + "\n", encoding="utf-8")
