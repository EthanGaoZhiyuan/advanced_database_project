# Bank of Australia — Assignment 2 Prototype

Integrates savings, credit-card and loan data into a customer warehouse. Includes Data Vault history, dimensional reporting, a Neo4j graph and a Streamlit dashboard.

## Project layout

```text
docker-compose.yml          # One tutorial environment
python/
  Dockerfile
  requirements.txt
workspace/
  boa_etl/                  # Executable steps 01–09 and shared helpers
  load_sample_data.py        # Load the SQL INSERT scripts
  test_pipeline.py           # One complete acceptance test
  sql/                      # Source DDL, sample INSERTs, warehouse DDL and ETL
  data/                     # Fictional source records and independent expected results
  graph/                    # Cypher queries
  dashboard/                # Streamlit app
  output/                   # Profiles, validation results and exported reports
docs/                       # Architecture and ERDs
```

## 1. Start Docker

Run these commands from the project directory with Docker Desktop running:

```bash
docker compose up -d --build
docker compose exec python bash
```

The second command opens the Python container at `/workspace`. Run the following commands there. PostgreSQL, Neo4j, CloudBeaver and ClickHouse match the tutorial service layout; ClickHouse is available for exercises but is not part of the BoA ETL.

## 2. Run the prototype

```bash
python boa_etl/01_check_environment.py
python boa_etl/02_create_schemas.py
python load_sample_data.py
python boa_etl/03_profile_sources.py
python boa_etl/04_load_bronze.py
python boa_etl/05_build_silver_etl.py
python boa_etl/06_build_gold_etl.py
python boa_etl/07_validate_warehouse.py
python boa_etl/08_run_analytics.py
python boa_etl/09_build_graph.py
```

If 01 reports a service still starting, wait briefly and rerun it. Step 02 creates tables; `load_sample_data.py` inserts the data. Neither is required again for an ordinary ETL rerun. The included dataset contains 500 enterprise customers, 857 source customer records and 90 business dates.

Steps 04–06 share a run ID stored in PostgreSQL. Each step commits its own completed layer. After an error, fix the cause and restart from 04; starting 04 again marks an unfinished attempt as failed. An unchanged rerun does not duplicate business records or Vault versions. Gold and its publication status commit together in 06, so reports continue to use the previous publication until it succeeds.

Step 07 compares identities, financial values and lineage with independent expected results. Step 08 exports Customer 360, product combinations, borrowing trends, transaction summaries and merchant spend. Step 09 exports and validates the Graph. Results appear in `workspace/output/` on the host.

## 3. Open the dashboard

Inside the Python container:

```bash
streamlit run dashboard/app.py --server.address=0.0.0.0 --server.port=8501 --browser.gatherUsageStats=false
```

Open [the dashboard](http://localhost:8501). Keep this terminal open; use another terminal for further commands. Press Ctrl+C to stop the dashboard.

| Tool | Address | Connection |
|---|---|---|
| CloudBeaver | http://localhost:8978 | PostgreSQL host `postgres`, port `5432`, database `boa`, user/password `student` |
| Neo4j Browser | http://localhost:7474 | `bolt://localhost:7687`, user `neo4j`, password `password` |
| PostgreSQL from the host | `localhost:55432` | Database `boa`, user/password `student` |

CloudBeaver's initial administrator account is separate from the PostgreSQL account. The three source databases are `boa_savings`, `boa_cards` and `boa_loans`. These credentials are for this local fictional tutorial dataset.

For a step-by-step CloudBeaver demonstration, see the [Manual demo guide](docs/manual-demo.md) (Chinese).

To replace the report's 22 original screenshots, follow the [Report screenshot guide](docs/report-screenshot-guide.md) (Chinese), with queries, expected results and English captions for each figure.

For manual warehouse setup, first create the source tables with the matching files in `workspace/sql/sources/`. Connect the SQL editor to `boa`, set the actual **PostgreSQL** login password below, then execute all of `workspace/sql/001_schema.sql` in the same editor:

```sql
SET boa.source_password = 'your actual PostgreSQL login password';
```

The SQL uses the current database login and the three source database names above on `127.0.0.1:5432` inside PostgreSQL. Existing `boa.source_user`, `boa.source_host`, `boa.savings_db`, `boa.cards_db` and `boa.loans_db` session settings override these defaults. If you previously set an incorrect account, correct `boa.source_user` or use a fresh connection. Missing passwords, missing local login roles and missing local source databases produce explicit errors. Continue with `002_reports.sql`, `003_integrity.sql` and `004_input_contract.sql`. Step 02 supplies connection settings automatically when using Python.

Warehouse DDL supports a fresh database or rerunning the current schema; it no longer migrates older table layouts. If a source database's `public` schema was deleted, recreate it in that source database before its source DDL. Sample data is loaded separately.

## 4. Test or stop

Inside the Python container, one command runs all steps, validates the warehouse and graph, then repeats the ETL to check for duplicates:

```bash
python test_pipeline.py
```

From the host project directory, stop the services while retaining database volumes:

```bash
docker compose down
```

See [Architecture](docs/architecture.md) for the implemented models and business rules, and [Refactor notes](docs/refactor-notes.md) for the changes and verification limits.
