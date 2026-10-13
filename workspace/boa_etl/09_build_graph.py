"""Project the latest published Gold date into Neo4j, then reconcile nodes and edges."""
from boa_etl.config import OUTPUT_DIR
from boa_etl.graph_model import export_graph
from boa_etl.graph_validation import validate_graph


def main():
    result = export_graph(output=OUTPUT_DIR / "graph_export.json")
    print(f"Graph exported for {result['business_date']}: {result['nodes']}")
    validation = validate_graph(business_date=result["business_date"],
                                output=OUTPUT_DIR / "graph_validation.json")
    print(f"Graph validation: {validation['status']}")
    if validation["status"] != "PASSED":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
