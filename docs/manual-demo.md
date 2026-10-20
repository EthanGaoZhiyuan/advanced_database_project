# BoA Prototype: Tutor Run and Demonstration Guide

This guide runs the current `boa-tutorial` Docker environment and demonstrates how three banking systems feed an integrated warehouse, reports and a relationship graph.

```text
Savings / Cards / Loans -> Bronze -> Silver -> Data Vault -> Gold
                                                            |
                                              Reports, Dashboard and Neo4j
```

Choose **one** route for loading the warehouse:

- **Python route:** follow sections 1 and 2, then continue with section 4. Run each script yourself and inspect the results between steps.
- **Manual SQL route:** follow sections 1 and 3, then continue with section 4. Execute the SQL files in CloudBeaver.

Both routes use the same SQL transformations. Sections 4-7 cover validation, business queries, Neo4j and the Dashboard. Do not run the two ETL routes concurrently.

**Command locations:** run every `bash` command below in a host terminal at the project root, beside `docker-compose.yml`. These commands already enter the Python container; do not first open a container shell. Run `sql` blocks in CloudBeaver and `cypher` blocks in Neo4j Browser. SQL file names in the manual route are relative to `workspace/sql/`.

## 1. Start the environment

With Docker running, execute:

```bash
docker compose up -d --build
docker compose ps
```

Wait for PostgreSQL to be healthy and the other services to start. If using the Ubuntu virtual machine, run these commands and open the browser inside that virtual machine.

| Service | Browser address or endpoint | Purpose |
|---|---|---|
| CloudBeaver | [http://localhost:8978](http://localhost:8978) | Execute SQL and inspect PostgreSQL tables |
| Neo4j Browser | [http://localhost:7474/browser/](http://localhost:7474/browser/) | Query and display the relationship graph |
| Dashboard | [http://localhost:8501](http://localhost:8501) | View reports after starting Streamlit in section 7 |
| PostgreSQL from the host | `localhost:55432` | Optional connection from a desktop database client |

ClickHouse is included to match the tutorial environment, but it is not used by the BoA ETL.

For CloudBeaver, complete its initial administrator setup if prompted, then create a PostgreSQL connection:

| Setting | Value |
|---|---|
| Host | `postgres` |
| Port | `5432` |
| Database | `boa` |
| Username | `student` |
| Password | `student` |

CloudBeaver runs inside Docker, so it uses `postgres:5432`, not the host port `55432`. Its web administrator account is separate from the PostgreSQL login.

Use these PostgreSQL credentials for all four databases. They match the Compose configuration and the existing `001_schema.sql`, which sets the source user to the current login and the source password to `student`. Changing Compose settings alone does not reset credentials in an existing database volume.

## 2. Python route: run the numbered scripts

Run these commands **one at a time**, in this order. Check that each command finishes without an error before continuing.

```bash
docker compose exec python python boa_etl/01_check_environment.py
docker compose exec python python boa_etl/02_create_schemas.py
docker compose exec python python load_sample_data.py
docker compose exec python python boa_etl/03_profile_sources.py
docker compose exec python python boa_etl/04_load_bronze.py
docker compose exec python python boa_etl/05_build_silver_etl.py
docker compose exec python python boa_etl/06_build_gold_etl.py
```

| Step | What the script does | What to inspect |
|---|---|---|
| `01_check_environment.py` | Checks PostgreSQL, Neo4j, CloudBeaver, ClickHouse and the supplied dataset | Successful checks in the terminal; retry if a service is still starting |
| `02_create_schemas.py` | Creates missing source databases, runs their source DDL, then runs warehouse SQL files `001`-`004` | Three source databases with four tables each; warehouse schemas in `boa` |
| `load_sample_data.py` | Executes the three source INSERT scripts and the warehouse registry script | Savings: 286 customer rows; Cards: 286; Loans: 285 |
| `03_profile_sources.py` | Examines source counts, columns, missing values, formatting and overlapping local IDs | `workspace/output/source_profile.json` |
| `04_load_bronze.py` | Starts a run and extracts source records into Bronze with provenance | Audit stage `bronze-ready` |
| `05_build_silver_etl.py` | Cleans and integrates Silver, then loads Data Vault history | Audit stage `silver-vault-ready`; populated Silver and Vault tables |
| `06_build_gold_etl.py` | Loads Gold dimensions and facts, checks publication completeness and finishes the run | Audit status `SUCCEEDED` and stage `build-gold` |

Step 05 executes **both** `build_silver.sql` and `load_vault.sql`. Step 06 executes **both** `build_gold.sql` and `finish_run.sql`. There is no separate numbered Python step for Vault or publication.

The scripts restore the batch and run context from PostgreSQL. You do not need to set `boa.batch_id`, `boa.run_id` or `boa.dates` manually for this route. Steps 04-06 share a run ID and commit their completed layers separately; Gold data and its publication status commit together in step 06.

After step 06 succeeds, go directly to **section 4** for Python steps 07-09. Do not repeat the manual SQL route.

### Rerunning or recovering the Python route

For an ordinary rerun with unchanged source data, run **04, 05, 06, 07, 08 and 09** again. There is no need to rerun schema creation or sample loading. An unchanged rerun should not duplicate business records or Vault versions.

If a command fails, stop and fix the first reported error. For an ETL failure, restart from **04**, then continue with 05 and 06. Step 04 marks an unfinished attempt as failed and starts a new run. Earlier committed layers can remain after a failure; rerunning only 06 is not the recovery sequence.

## 3. Manual SQL route: load the warehouse in CloudBeaver

Skip this section if you used the Python route. It is the alternative way to demonstrate the same warehouse transformations.

### 3.1 Execute a complete SQL file

1. Open the file from `workspace/sql/` in a text editor.
2. Open a CloudBeaver SQL editor connected to the database specified below.
3. Replace the old editor contents with the **entire file**, then clear any text selection.
4. Choose **Execute SQL script**, so all statements run. Do not execute only the statement at the cursor.
5. Wait for completion and check for errors before proceeding.

Keep each `DO $$ ... $$` block intact. A file name typed into the SQL editor does not execute that file.

**Selecting a database in the navigation tree does not necessarily change an existing SQL editor's connection.** Before running a source script, confirm the editor's database with:

```sql
SELECT current_database();
```

The three source systems use the same table names but different columns. Execute each script in its matching database.

### 3.2 Create the source databases

Docker initializes `boa`. In an editor connected to `boa`, check which databases already exist:

```sql
SELECT datname
FROM pg_database
WHERE datname IN ('boa', 'boa_savings', 'boa_cards', 'boa_loans')
ORDER BY datname;
```

Create **only the missing databases**. Execute each statement separately with Auto-commit enabled and no open transaction:

```sql
CREATE DATABASE boa_savings;
```

```sql
CREATE DATABASE boa_cards;
```

```sql
CREATE DATABASE boa_loans;
```

PostgreSQL does not support `CREATE DATABASE IF NOT EXISTS`, and database creation cannot run inside `BEGIN` / `COMMIT`.

For the clearest demonstration, create four named CloudBeaver connections, one per database. Use the settings in section 1 and change only Database. Alternatively, enable **Show all databases**, refresh the connection and switch databases in the SQL editor; verify each switch with `SELECT current_database();`.

### 3.3 Create the source tables, then the warehouse

Execute the following complete files:

| Order | Editor database | SQL file |
|---|---|---|
| 1 | `boa_savings` | `sources/savings.sql` |
| 2 | `boa_cards` | `sources/cards.sql` |
| 3 | `boa_loans` | `sources/loans.sql` |

If a source database's `public` schema was previously deleted, first recreate it **in that source database**:

```sql
CREATE SCHEMA IF NOT EXISTS public;
```

After running each source DDL file, check the four tables in the same editor:

```sql
SELECT
    current_database() AS database_name,
    to_regclass('public.customers') AS customers_table,
    to_regclass('public.accounts') AS accounts_table,
    to_regclass('public.daily_balances') AS balances_table,
    to_regclass('public.transactions') AS transactions_table;
```

All four table results should be non-null. A `NULL` means the table has not been found in that database; finish creating the tables before loading data.

| Source database | Transaction ID column | Transaction date column |
|---|---|---|
| `boa_savings` | `txn_id` | `txn_timestamp` |
| `boa_cards` | `auth_id` | `posted_date` |
| `boa_loans` | `event_id` | `event_date` |

`CREATE TABLE IF NOT EXISTS` skips existing tables; it does not repair an incompatible old layout. Do not run another source's DDL in the same database to resolve a missing-column error.

Next, open an editor connected to **`boa`** and execute these complete files in order:

| Order | SQL file | Purpose |
|---|---|---|
| 1 | `001_schema.sql` | Creates source foreign tables, warehouse tables, constraints and reference dimension rows |
| 2 | `002_reports.sql` | Creates reporting views |
| 3 | `003_integrity.sql` | Creates integrity checks and triggers |
| 4 | `004_input_contract.sql` | Creates input validation and normalization functions |

Use the `student` / `student` login from section 1. `001_schema.sql` already contains the source credential settings; no separate password command is needed for this environment. Execute the **whole file**, including the reference rows for product and transaction-type dimensions near its end.

Refresh `boa` to see `boa_src_savings`, `boa_src_cards`, `boa_src_loans`, `boa_bronze`, `boa_silver`, `boa_vault`, `boa_gold` and `boa_audit`. The source schemas contain foreign tables pointing to the three separate source databases. Reporting views exist at this stage but have no published results yet.

If you corrected source table definitions after running `001_schema.sql`, rerun that complete file to refresh its foreign-table definitions.

### 3.4 Load the sample records

Execute these files in their respective databases:

| Order | Editor database | SQL file |
|---|---|---|
| 1 | `boa_savings` | `seed/savings.sql` |
| 2 | `boa_cards` | `seed/cards.sql` |
| 3 | `boa_loans` | `seed/loans.sql` |
| 4 | `boa` | `seed/registry.sql` |

The seed files include their own `BEGIN` and `COMMIT`; do not wrap them in an additional transaction. They are large, so wait for each to finish. Files under `sources/` create tables; files under `seed/` insert data.

The registry loads the verified cross-system customer mapping and batch metadata. **From `seed/registry.sql` until the final ETL commit, keep the same `boa` editor and database session.** The registry also sets the session's batch ID. Check it with:

```sql
SELECT current_database(), current_setting('boa.batch_id');
```

### 3.5 Prepare and execute the ETL

With Auto-commit enabled and no open transaction, execute the complete **`000_manual.sql`** file in that same `boa` editor.

Despite its name, this file belongs **here, after schema creation and registry loading**. It sets the source credentials, creates a run ID, obtains the batch dates, records `/workspace/data` as the input directory, inserts the `RUNNING` audit record, and starts the ETL transaction with an advisory lock.

The file already ends with `BEGIN` and `pg_advisory_xact_lock(32113001)`. Do not create a second run record or issue another `BEGIN`.

Now execute these complete files in the same editor and transaction:

| Order | SQL file | Purpose |
|---|---|---|
| 1 | `extract_bronze.sql` | Extract original source records with provenance |
| 2 | `build_silver.sql` | Normalize fields and integrate customers, accounts, balances and transactions |
| 3 | `load_vault.sql` | Load Hubs, the customer-account Link and Satellite history |
| 4 | `build_gold.sql` | Load dimensions, daily snapshot facts and transaction facts |
| 5 | `finish_run.sql` | Check publication completeness and mark the run successful |

**Do not commit between these files, change sessions, or run Python ETL concurrently.** Temporary tables are needed across the SQL files. Do not enable an execution option that commits after every file.

After all five files succeed, execute:

```sql
COMMIT;
```

`finish_run.sql` does not commit by itself. This manual route uses one transaction for the ETL; the Python route commits its layers separately. Both require a successful final publication before reports display the new results.

### 3.6 Recover from a manual SQL error

Stop at the first error. In the same editor, execute this statement **on its own**:

```sql
ROLLBACK;
```

Then record the failed attempt:

```sql
UPDATE boa_audit.pipeline_run
SET status = 'FAILED',
    finished_at = clock_timestamp(),
    error_message = 'Manual ETL failed'
WHERE run_id = current_setting('boa.run_id')::uuid
  AND status = 'RUNNING';
```

Fix the original error, then repeat section 3.5, starting with `000_manual.sql` to create a new run. Do not resume from the middle of the ETL: rollback removes the temporary tables.

If the connection was lost, the session variables are also lost. Identify the abandoned run in `boa_audit.pipeline_run` and mark that specific run failed before starting again. Restore the batch context by rerunning `seed/registry.sql`, then follow section 3.5.

## 4. Validate, export reports and build the graph

Complete either route through successful Gold publication before running these commands. They work after both the Python route and the manual SQL route.

### 4.1 Validate the warehouse: Python step 07

```bash
docker compose exec python python boa_etl/07_validate_warehouse.py
```

The current validator contains 32 checks. It compares expected identities, account ownership, financial values, customer profiles and report totals with independent expected datasets, and checks business rules, publication and lineage. Matching row counts alone is insufficient. This is not a comparison of every historical field in every warehouse layer.

Look for:

```text
Warehouse validation: PASSED; details in /workspace/output
```

Review these files on the host:

| File under `workspace/output/` | Contents |
|---|---|
| `validation.txt` | Readable check results |
| `validation.json` | Detailed checks, counts and mismatches |
| `explain_analyze.json` | Query plans and execution times measured during this run |

If validation fails, inspect the failed checks before presenting the results as correct. A successful ETL run and successful independent validation are separate checks.

### 4.2 Export analytics: Python step 08

```bash
docker compose exec python python boa_etl/08_run_analytics.py
```

The terminal shows row counts and the first five rows of each report. Full exports appear in `workspace/output/`:

| File | Contents |
|---|---|
| `customer_360.csv` | Unified customer profiles, holdings and balances |
| `product_combinations.csv` | Customer counts by product combination |
| `borrowing_daily.csv` | Daily card and loan balances across published dates |
| `transaction_types.csv` | Transaction counts and movements for the selected date |
| `top_merchants.csv` | Merchant purchase totals for the reporting window |
| `analytics.json` | Analysis date and report row counts |

The script selects the latest published business date. The Dashboard queries the database directly; it does not load these CSV files.

### 4.3 Export and validate Neo4j: Python step 09

```bash
docker compose exec python python boa_etl/09_build_graph.py
```

This script projects the latest published Gold date into Neo4j and reconciles node and relationship identities, properties, amounts and counts. The current graph validator has **10 checks**: five node groups, four relationship groups and an unexpected relationship-type check.

Look for the export date and node counts, followed by:

```text
Graph validation: PASSED
```

Evidence is saved in `workspace/output/graph_export.json` and `workspace/output/graph_validation.json`. Rerun step 09 after publishing new Gold data to update the graph.

## 5. Inspect the data and demonstrate the business results

Run the following queries in a CloudBeaver editor connected to **`boa`**. Sections 5.1 and 5.2 can also be used as checkpoints during the Python demonstration, after source loading and step 05 respectively.

### 5.1 Show the three sources and the customer identity problem

```sql
SELECT 'Savings' AS source_system, count(*) AS customers
FROM boa_src_savings.customers
UNION ALL
SELECT 'Cards', count(*) FROM boa_src_cards.customers
UNION ALL
SELECT 'Loans', count(*) FROM boa_src_loans.customers;
```

For the supplied dataset, expect 286, 286 and 285 source customer records: 857 in total. They represent 500 enterprise customers after applying the verified crosswalk.

Show how Lucas appears under different local IDs and formats:

```sql
SELECT 'Savings' AS source_system, customer_id, full_name,
       date_of_birth_text, state
FROM boa_src_savings.customers WHERE customer_id = 'C000001'
UNION ALL
SELECT 'Cards', customer_id, full_name, date_of_birth_text, state
FROM boa_src_cards.customers WHERE customer_id = 'C000286'
UNION ALL
SELECT 'Loans', customer_id, full_name, date_of_birth_text, state
FROM boa_src_loans.customers WHERE customer_id = 'C000144';
```

These records map to enterprise customer `EC000001`. Identity integration uses the supplied verified mapping, rather than inferring that matching names or addresses prove two records are the same person.

### 5.2 Compare original and cleaned fields

```sql
SELECT 'Bronze (raw)' AS layer,
       payload->>'full_name' AS full_name,
       payload->>'email' AS email,
       payload->>'phone' AS phone,
       payload->>'state' AS state,
       payload->>'country' AS country
FROM boa_bronze.source_record
WHERE source_system = 'SAVINGS'
  AND entity_name = 'customers'
  AND source_record_key = 'C000001'
UNION ALL
SELECT 'Silver (clean)', full_name, email, phone, state, country
FROM boa_silver.enterprise_customer
WHERE enterprise_customer_id = 'EC000001';
```

Explain the retained raw values and normalized customer fields. If changed source versions have been loaded, Bronze may return more than one raw version.

### 5.3 Confirm publication and record counts

```sql
SELECT run_id, status, current_stage,
       records_read, records_written, records_rejected
FROM boa_audit.pipeline_run
ORDER BY started_at DESC
LIMIT 5;
```

The completed run should be `SUCCEEDED`, at stage `build-gold`. For the supplied sample, expect 174,643 input records processed and accepted, with zero rejections. **`records_written` counts accepted input records processed downstream; it is not the number of newly inserted Bronze rows.** Unchanged reruns can reuse existing raw records.

The sample's expected warehouse results are 500 enterprise customers, 900 accounts, 78,958 daily snapshots, 93,071 transactions and 90 published dates, from 1 January to 31 March 2026. Use the validation output to confirm these results for the actual run.

### 5.4 Show three business analyses

```sql
-- One customer's savings, credit-card and loan position.
SELECT *
FROM boa_gold.v_customer_360
WHERE enterprise_customer_id = 'EC000001'
  AND business_date = DATE '2026-03-31';

-- Customers grouped by their active product combinations.
SELECT *
FROM boa_gold.v_product_combinations
WHERE business_date = DATE '2026-03-31'
ORDER BY customer_count DESC;

-- Daily borrowing balances across published dates.
SELECT *
FROM boa_gold.v_borrowing_daily
ORDER BY business_date;
```

For Lucas on 31 March, the supplied sample shows AUD 10,000 savings, AUD 2,000 card debt and AUD 300,000 loan principal. Total borrowing is AUD 302,000; savings are not subtracted from this measure.

Product combinations count customers, not accounts. `NONE` means no active product category on the selected date; an active account with zero balance still counts as a holding. Borrowing values are daily closing balances, so adding them across dates would double count debt.

Gold stores the three balance measures as non-negative amounts in separate columns. Transaction `signed_amount` represents an increase or decrease in the relevant account balance; it is not a universal customer net-worth sign convention.

## 6. Display the graph in Neo4j Browser

### 6.1 Connect and view the model

Open [Neo4j Browser](http://localhost:7474/browser/) after step 09 succeeds:

| Setting | Value |
|---|---|
| Connect URL | `bolt://localhost:7687` |
| Username | `neo4j` |
| Password | `password` |
| Database | `neo4j` |

Execute:

```cypher
CALL db.schema.visualization();
```

Select **Graph** in the result. This displays a metadata-based overview of node labels and relationship types. Use the following queries to show actual records.

```text
Customer --HOLDS---------> Account
Account  --OF_PRODUCT----> Product
Customer --LIVES_AT------> Address
Account  --TRANSACTED_AT-> Merchant
```

CloudBeaver's PostgreSQL editor displays relational tables and SQL results. Use Neo4j Browser for these Cypher queries and interactive node-and-relationship results.

### 6.2 Show Lucas's accounts and products

```cypher
MATCH path =
  (c:Customer {namespace: 'boa', enterprise_customer_id: 'EC000001'})
  -[:HOLDS]->(a:Account {namespace: 'boa'})
  -[:OF_PRODUCT]->(p:Product {namespace: 'boa'})
RETURN path;
```

Select **Graph**. For the supplied sample this returns one customer, three accounts and three products: seven nodes and six relationships. This query does not include the address or merchants.

Click a node to inspect its properties and drag nodes to arrange them. If a Product node displays `TRUE`, its caption is showing a Boolean property. Set the Product caption to `code`. Useful captions for actual data are:

| Label | Caption property |
|---|---|
| `Customer` | `name` |
| `Account` | `source_account_id` |
| `Product` | `code` |
| `Address` | `street_address` |
| `Merchant` | `name` |

### 6.3 Show all five node types in one small example

```cypher
MATCH p1 = (c:Customer {namespace: 'boa'})
  -[:HOLDS]->(a:Account {namespace: 'boa'})
  -[:OF_PRODUCT]->(p:Product {namespace: 'boa'})
MATCH p2 = (c)-[:LIVES_AT]->(address:Address {namespace: 'boa'})
MATCH p3 = (a)-[:TRANSACTED_AT]->(merchant:Merchant {namespace: 'boa'})
RETURN p1, p2, p3
LIMIT 1;
```

This selects a customer-account example that has both an address and merchant activity. It demonstrates the five node types and four relationship types with actual data. It is not restricted to Lucas.

### 6.4 Explore shared addresses and merchants

Open `workspace/graph/browser.cypher`. In Neo4j Browser, first execute these parameter commands separately:

```text
:param namespace => 'boa'
```

```text
:param enterprise_customer_id => 'EC000001'
```

Copy and execute one complete query at a time from the file. It contains customer-account-product paths, shared addresses and shared card merchants. Change the customer parameter to explore another customer; a shared-relationship query may legitimately return no rows for a particular customer.

Shared addresses and merchants are relationship clues, not evidence that customers are the same person or that fraud occurred. Address links do not merge customer identities. Merchant relationships summarize qualifying card purchases through the graph export date, rather than only transactions on that day.

## 7. Start and demonstrate the Dashboard

In a host terminal at the project root, run:

```bash
docker compose exec python streamlit run dashboard/app.py --server.address=0.0.0.0 --server.port=8501 --browser.gatherUsageStats=false
```

Keep this terminal running and open [http://localhost:8501](http://localhost:8501). Use another terminal for further commands. Press `Ctrl+C` to stop Streamlit.

Select the published business date **31 March 2026** for the supplied sample, then demonstrate these tabs:

| Tab | Action | What it demonstrates |
|---|---|---|
| Customer 360 | Select Lucas / `EC000001`; inspect his profile, accounts and balance trend | A unified customer view across three source systems |
| Product Holdings | Inspect category counts, combinations and the customer list | Active product ownership, cross-product overlap and customers with no active products |
| Borrowing Balances | Inspect the card/loan split, borrower list and daily trend | Total customer borrowing without offsetting savings or adding balances across dates |
| Transaction Activity | Inspect transaction types, individual transactions and merchant totals | Account movements and spending activity |
| Relationships | Select a customer and inspect the graph | Customer-account-product links and available address/merchant connections |

The first four tabs query Gold. The Relationships tab queries the most recent Neo4j export. Changing the Dashboard date **does not rebuild the graph**. The page warns if its export date or publication run differs from the selected warehouse publication. For an aligned demonstration, use the latest published date and rerun step 09 after a new publication.

Use **Refresh from database** after updating the data. Use the available CSV download buttons to show that report results can be exported.

## 8. Optional full test and shutdown

To run the complete automated acceptance sequence from a running Docker environment:

```bash
docker compose exec python python test_pipeline.py
```

This runs setup, sample loading and steps 01-09, then repeats steps 04-09. It validates both passes and compares table counts to check that an unchanged rerun does not add duplicate records or Vault versions. Results are written to `workspace/output/pipeline_test.json`.

This command loads sample data and creates new ETL runs. Run it separately from a manual demonstration, not while a SQL ETL transaction is open.

To stop the environment while retaining database volumes:

```bash
docker compose down
```

Do not add `-v` when you want to retain the demonstration data.

## 9. Common problems

| Symptom | What to check or do |
|---|---|
| Docker reports that a port is already allocated | Run `docker ps`. An older BoA environment may still own ports 7474, 7687 or 8978. Stop only the conflicting BoA containers before starting `boa-tutorial`. |
| Step 01 reports an unavailable service | Wait for startup, rerun 01, and inspect the relevant service with `docker compose logs postgres`, `docker compose logs neo4j` or `docker compose logs cloudbeaver`. |
| `role "student" does not exist` or authentication fails | Confirm that CloudBeaver and the scripts are using the current tutorial PostgreSQL instance. Old volumes can retain old credentials. The guide and existing warehouse DDL use `student` / `student`. |
| The navigation tree shows one database but SQL affects another | Run `SELECT current_database();` in the actual editor. Switch its connection, not only the tree selection. |
| `public.customers` or `public.transactions` does not exist | Create the source tables in the correct source database using the complete `sources/*.sql` file before executing its seed file. |
| `posted_date` or `event_date` does not exist | Check the current database and its actual transaction columns against section 3.3. An old or wrong source layout is not changed by `CREATE TABLE IF NOT EXISTS`. |
| `current transaction is aborted` | Execute `ROLLBACK;` on its own, then address the first error. Repeating later statements cannot repair an aborted transaction. |
| Manual ETL reports a missing batch/run setting | Keep the same `boa` session from `seed/registry.sql` through `000_manual.sql` and the final commit. Follow section 3.6 if the session was lost. |
| Python step 05 or 06 reports the wrong stage or a missing active run | Complete the prerequisite steps. After fixing an ETL error, restart from 04, then run 05 and 06. |
| `INCOMPLETE_TRANSACTION_PUBLICATION` | Inspect the first reported event and its dimension mappings. Confirm that all of `001_schema.sql` ran, including the transaction-type reference rows. Fix the cause and restart the ETL; do not bypass the publication check. |
| Reporting views or Dashboard have no data | Confirm step 06 succeeded, or that the manual route completed `finish_run.sql` followed by `COMMIT`. Check the audit status. |
| Neo4j is empty or shows an old export | Complete Gold publication, then run 09. Use the `boa` namespace for actual-data queries. |
| Dashboard cannot be opened | Start Streamlit with the command in section 7 and keep its terminal running. Docker startup alone does not start the Dashboard application. |
