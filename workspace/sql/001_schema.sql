/*
Design layers: Source, Bronze, Silver, Vault, Gold and Audit.
Reads: the three source databases and PostgreSQL catalog definitions.
Writes: BoA schemas, tables, keys, constraints, indexes and the three Gold products;
        no generated customer, account, balance or transaction business rows are loaded.
Execution order: 02_create_schemas.py runs this before the remaining warehouse DDL.
                 load_sample_data.py then inserts the supplied source dataset.
Manual use: connect to boa and run this whole file in the same editor after:
    SET boa.source_password = 'your actual PostgreSQL login password';
Defaults: boa_savings / boa_cards / boa_loans on 127.0.0.1:5432,
          using the current PostgreSQL login (not the CloudBeaver web account).
Optional session overrides: boa.savings_db, boa.cards_db, boa.loans_db,
                           boa.source_host, boa.source_user.
Python step 02 supplies these settings and the password automatically.
Create the four public source tables in each source database first.
Fresh setup and repeat runs of this schema are supported; old schema migrations are not.
*/
-- Configure all three source connections together. Do not overwrite Python/session settings.

SELECT set_config('boa.source_user', session_user, false);
SET boa.source_password = 'student';

DO $source_connections$
DECLARE
  source text; source_database text; source_schema text; server_name text; entity text;
  source_host text := coalesce(nullif(current_setting('boa.source_host', true), ''), '127.0.0.1');
  source_user text := coalesce(nullif(current_setting('boa.source_user', true), ''), session_user);
  source_password text := nullif(current_setting('boa.source_password', true), '');
BEGIN
  IF source_password IS NULL THEN
    RAISE EXCEPTION 'MISSING_SOURCE_PASSWORD: boa.source_password is not set in this session.'
      USING HINT = 'Set boa.source_password to the actual PostgreSQL login password, then run this whole file in the same editor.';
  END IF;
  -- Catalog checks apply to the tutorial's local PostgreSQL instance only.
  IF source_host IN ('127.0.0.1', 'localhost', '::1') AND current_setting('port') = '5432'
      AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=source_user AND rolcanlogin) THEN
    RAISE EXCEPTION 'INVALID_SOURCE_USER: PostgreSQL login role "%" does not exist or cannot log in.', source_user
      USING HINT = 'Check the connected PostgreSQL instance and boa.source_user. No database role is created by this script.';
  END IF;

  CREATE SCHEMA IF NOT EXISTS public;
  CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;

  FOREACH source IN ARRAY ARRAY['savings','cards','loans'] LOOP
    source_database := coalesce(nullif(current_setting('boa.'||source||'_db', true), ''), 'boa_'||source);
    source_schema := 'boa_src_'||source;
    server_name := 'boa_fdw_'||source;
    IF source_host IN ('127.0.0.1', 'localhost', '::1') AND current_setting('port') = '5432'
        AND NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=source_database) THEN
      RAISE EXCEPTION 'MISSING_SOURCE_DATABASE: database "%" does not exist.', source_database
        USING HINT = 'Create all three source databases and run their sql/sources scripts before this file.';
    END IF;
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', source_schema);
    IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname=server_name) THEN
      EXECUTE format('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, dbname %L)',
        server_name, source_host, source_database);
    ELSE
      EXECUTE format('ALTER SERVER %I OPTIONS (SET host %L, SET dbname %L)',
        server_name, source_host, source_database);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_user_mappings
        WHERE srvname=server_name AND usename=current_user) THEN
      EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER %I OPTIONS (user %L, password %L)',
        server_name, source_user, source_password);
    ELSE
      EXECUTE format('ALTER USER MAPPING FOR CURRENT_USER SERVER %I OPTIONS (SET user %L, SET password %L)',
        server_name, source_user, source_password);
    END IF;
    -- Refresh foreign-table definitions only; an ordinary local table causes an error.
    FOREACH entity IN ARRAY ARRAY['transactions','daily_balances','accounts','customers'] LOOP
      EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.%I', source_schema, entity);
    END LOOP;
    EXECUTE format('IMPORT FOREIGN SCHEMA public LIMIT TO (customers, accounts, daily_balances, transactions)
      FROM SERVER %I INTO %I', server_name, source_schema);
  END LOOP;
END $source_connections$;

CREATE SCHEMA IF NOT EXISTS boa_bronze;
CREATE SCHEMA IF NOT EXISTS boa_silver;
CREATE SCHEMA IF NOT EXISTS boa_vault;
CREATE SCHEMA IF NOT EXISTS boa_gold;
CREATE SCHEMA IF NOT EXISTS boa_audit;

-- Audit every attempt separately; terminal run states require a completion timestamp.
CREATE TABLE IF NOT EXISTS boa_audit.pipeline_run (
  run_id uuid PRIMARY KEY,
  batch_id text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at timestamptz,
  status text NOT NULL CHECK(status IN ('RUNNING','SUCCEEDED','FAILED')),
  current_stage text NOT NULL,
  records_read bigint NOT NULL DEFAULT 0 CHECK(records_read>=0),
  records_written bigint NOT NULL DEFAULT 0 CHECK(records_written>=0),
  records_rejected bigint NOT NULL DEFAULT 0 CHECK(records_rejected>=0),
  error_message text,
  execution_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CHECK((status='RUNNING' AND finished_at IS NULL) OR (status<>'RUNNING' AND finished_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS run_status_idx ON boa_audit.pipeline_run(status,started_at DESC);
-- Retain the declared batch coverage, checksums and supplied input directory for evidence.
CREATE TABLE IF NOT EXISTS boa_audit.batch_manifest (
  batch_id text PRIMARY KEY, manifest jsonb NOT NULL,
  input_directory text NOT NULL, loaded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- Every input row must reconcile to accepted, identical-deduplicated or rejected input.
CREATE TABLE IF NOT EXISTS boa_audit.source_file (
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id), path text NOT NULL,
  source_system text NOT NULL, entity_name text NOT NULL,
  expected_count bigint NOT NULL DEFAULT 0, input_count bigint NOT NULL DEFAULT 0,
  accepted_count bigint NOT NULL DEFAULT 0, deduplicated_count bigint NOT NULL DEFAULT 0,
  rejected_count bigint NOT NULL DEFAULT 0, sha256 text NOT NULL,
  PRIMARY KEY(run_id,path),
  CHECK(expected_count>=0 AND input_count>=0 AND accepted_count>=0 AND deduplicated_count>=0 AND rejected_count>=0),
  CHECK(input_count=accepted_count+deduplicated_count+rejected_count)
);
-- Only explicitly verified, source-qualified crosswalk entries can resolve a customer.
CREATE TABLE IF NOT EXISTS boa_audit.identity_registry (
  source_system text NOT NULL CHECK(source_system IN ('SAVINGS','CARDS','LOANS')),
  source_customer_id text NOT NULL, enterprise_customer_id text NOT NULL,
  mapping_method text NOT NULL, verification_status text NOT NULL CHECK(verification_status='VERIFIED'),
  PRIMARY KEY(source_system,source_customer_id)
);
CREATE INDEX IF NOT EXISTS identity_registry_enterprise_idx ON boa_audit.identity_registry(enterprise_customer_id);
-- Preserve rule-specific rejection evidence independently of downstream publication.
CREATE TABLE IF NOT EXISTS boa_audit.data_quality_issue (
  issue_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  source_system text, entity_name text, source_record_key text, business_date date,
  rule_code text NOT NULL, severity text NOT NULL CHECK(severity IN ('INFO','WARNING','ERROR')),
  issue_description text NOT NULL, rejected_payload jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS quality_run_idx ON boa_audit.data_quality_issue(run_id);
-- Preserve raw payload/provenance and deduplicate unchanged content within a batch.
CREATE TABLE IF NOT EXISTS boa_bronze.source_record (
  raw_record_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  batch_id text NOT NULL REFERENCES boa_audit.batch_manifest(batch_id),
  source_system text NOT NULL CHECK(source_system IN ('SAVINGS','CARDS','LOANS','REGISTRY')),
  entity_name text NOT NULL CONSTRAINT raw_entity_contract
    CHECK(entity_name IN ('customers','accounts','daily_balances','transactions','crosswalk')),
  source_record_key text NOT NULL, business_date date, payload jsonb NOT NULL,
  payload_hash text NOT NULL,
  extracted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(batch_id,source_system,entity_name,source_record_key,payload_hash),
  CONSTRAINT raw_business_date_contract
    CHECK((entity_name IN ('daily_balances','transactions'))=(business_date IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS raw_source_key_idx ON boa_bronze.source_record(source_system,entity_name,source_record_key);
CREATE INDEX IF NOT EXISTS raw_batch_idx ON boa_bronze.source_record(batch_id);
-- A retry can reuse immutable Bronze content while proving its own processing membership.
CREATE TABLE IF NOT EXISTS boa_audit.raw_run_record (
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  PRIMARY KEY(run_id,raw_record_id)
);

-- Store the current accepted profile and attribute-level precedence provenance.
CREATE TABLE IF NOT EXISTS boa_silver.enterprise_customer (
  enterprise_customer_id text PRIMARY KEY, full_name text, email text, phone text,
  date_of_birth date, street_address text, state text, postcode text, country text,
  source_provenance jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK(state IS NULL OR state IN ('ACT','NSW','NT','QLD','SA','TAS','VIC','WA')),
  CHECK(country IS NULL OR country='AU'), CHECK(postcode IS NULL OR postcode ~ '^[0-9]{4}$')
);
-- Expose the single verified input registry; publication still depends on accepted Silver profiles and accounts.
CREATE OR REPLACE VIEW boa_silver.customer_crosswalk AS
SELECT source_system,source_customer_id,enterprise_customer_id,mapping_method,verification_status
FROM boa_audit.identity_registry;
-- Qualify each account by source and enforce its AUD/product-specific metadata contract.
CREATE TABLE IF NOT EXISTS boa_silver.account (
  account_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_system text NOT NULL CHECK(source_system IN ('SAVINGS','CARDS','LOANS')),
  source_account_id text NOT NULL,
  enterprise_customer_id text NOT NULL REFERENCES boa_silver.enterprise_customer(enterprise_customer_id),
  product_code text NOT NULL CHECK(product_code IN ('SAVINGS','CREDIT_CARD','LOAN')),
  opened_date date NOT NULL, closed_date date, currency_code text NOT NULL CHECK(currency_code='AUD'),
  credit_limit numeric(18,2), original_principal numeric(18,2),
  raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(source_system,source_account_id),
  CHECK(closed_date IS NULL OR closed_date>=opened_date),
  CHECK((product_code='SAVINGS' AND source_system='SAVINGS') OR
        (product_code='CREDIT_CARD' AND source_system='CARDS') OR (product_code='LOAN' AND source_system='LOANS')),
  CHECK((product_code='CREDIT_CARD' AND credit_limit IS NOT NULL AND credit_limit BETWEEN 0 AND 9999999999999999.99)
       OR (product_code<>'CREDIT_CARD' AND credit_limit IS NULL)),
  CHECK((product_code='LOAN' AND original_principal IS NOT NULL AND original_principal BETWEEN 0 AND 9999999999999999.99)
       OR (product_code<>'LOAN' AND original_principal IS NULL))
);
CREATE INDEX IF NOT EXISTS silver_account_customer_idx ON boa_silver.account(enterprise_customer_id);
-- Keep one accepted account/date balance; closed accounts must have three zero measures.
CREATE TABLE IF NOT EXISTS boa_silver.account_daily_balance (
  account_key bigint NOT NULL REFERENCES boa_silver.account(account_key), balance_date date NOT NULL,
  account_status text NOT NULL CHECK(account_status IN ('ACTIVE','CLOSED')),
  savings_balance numeric(18,2) NOT NULL CHECK(savings_balance BETWEEN 0 AND 9999999999999999.99),
  card_outstanding numeric(18,2) NOT NULL CHECK(card_outstanding BETWEEN 0 AND 9999999999999999.99),
  loan_principal_outstanding numeric(18,2) NOT NULL CHECK(loan_principal_outstanding BETWEEN 0 AND 9999999999999999.99),
  raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(account_key,balance_date),
  CHECK(account_status<>'CLOSED' OR (savings_balance=0 AND card_outstanding=0 AND loan_principal_outstanding=0))
);
CREATE INDEX IF NOT EXISTS silver_balance_date_idx ON boa_silver.account_daily_balance(balance_date);

-- Deduplicate customer hubs by the verified enterprise business key.
CREATE TABLE IF NOT EXISTS boa_vault.hub_customer (
  customer_hk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  enterprise_customer_id text NOT NULL UNIQUE,
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id)
);
-- Deduplicate account hubs by source plus source-local account ID.
CREATE TABLE IF NOT EXISTS boa_vault.hub_account (
  account_hk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_system text NOT NULL CHECK(source_system IN ('SAVINGS','CARDS','LOANS')), source_account_id text NOT NULL,
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id), UNIQUE(source_system,source_account_id)
);
-- One unique account link enforces the fixed single-owner assumption.
CREATE TABLE IF NOT EXISTS boa_vault.link_customer_account (
  customer_account_lk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_hk bigint NOT NULL REFERENCES boa_vault.hub_customer(customer_hk),
  account_hk bigint NOT NULL UNIQUE REFERENCES boa_vault.hub_account(account_hk),
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id), UNIQUE(customer_hk,account_hk)
);
CREATE INDEX IF NOT EXISTS link_customer_idx ON boa_vault.link_customer_account(customer_hk);
-- Append genuine profile changes with canonical hashdiffs and selected source provenance.
CREATE TABLE IF NOT EXISTS boa_vault.sat_customer_profile (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_hk bigint NOT NULL REFERENCES boa_vault.hub_customer(customer_hk),
  full_name text, email text, phone text, date_of_birth date, street_address text,
  state text, postcode text, country text, hashdiff text NOT NULL,
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id), source_provenance jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS sat_customer_latest_idx ON boa_vault.sat_customer_profile(customer_hk,version_id DESC);
-- Version accepted account descriptions while retaining AUD and product metadata checks.
CREATE TABLE IF NOT EXISTS boa_vault.sat_account_profile (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_hk bigint NOT NULL REFERENCES boa_vault.hub_account(account_hk),
  product_code text NOT NULL CHECK(product_code IN ('SAVINGS','CREDIT_CARD','LOAN')),
  opened_date date NOT NULL, closed_date date, currency_code text NOT NULL CHECK(currency_code='AUD'),
  credit_limit numeric(18,2), original_principal numeric(18,2), hashdiff text NOT NULL,
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id), source_provenance jsonb NOT NULL,
  CHECK(closed_date IS NULL OR closed_date>=opened_date),
  CHECK((product_code='CREDIT_CARD' AND credit_limit IS NOT NULL AND credit_limit BETWEEN 0 AND 9999999999999999.99)
    OR (product_code<>'CREDIT_CARD' AND credit_limit IS NULL)),
  CHECK((product_code='LOAN' AND original_principal IS NOT NULL AND original_principal BETWEEN 0 AND 9999999999999999.99)
    OR (product_code<>'LOAN' AND original_principal IS NULL))
);
CREATE INDEX IF NOT EXISTS sat_account_latest_idx ON boa_vault.sat_account_profile(account_hk,version_id DESC);
-- Preserve new dates and same-date corrections as ordered, traceable balance versions.
CREATE TABLE IF NOT EXISTS boa_vault.sat_account_daily_balance (
  version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_hk bigint NOT NULL REFERENCES boa_vault.hub_account(account_hk), balance_date date NOT NULL,
  account_status text NOT NULL CHECK(account_status IN ('ACTIVE','CLOSED')),
  savings_balance numeric(18,2) NOT NULL CHECK(savings_balance BETWEEN 0 AND 9999999999999999.99),
  card_outstanding numeric(18,2) NOT NULL CHECK(card_outstanding BETWEEN 0 AND 9999999999999999.99),
  loan_principal_outstanding numeric(18,2) NOT NULL CHECK(loan_principal_outstanding BETWEEN 0 AND 9999999999999999.99),
  hashdiff text NOT NULL, raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  CHECK(account_status<>'CLOSED' OR (savings_balance=0 AND card_outstanding=0 AND loan_principal_outstanding=0))
);
CREATE INDEX IF NOT EXISTS sat_balance_latest_idx ON boa_vault.sat_account_daily_balance(account_hk,balance_date,version_id DESC);
CREATE INDEX IF NOT EXISTS sat_balance_date_idx ON boa_vault.sat_account_daily_balance(balance_date,account_hk,version_id DESC);

-- SCD Type 1 customer descriptions show current accepted values; history remains in Vault.
CREATE TABLE IF NOT EXISTS boa_gold.dim_customer (
  customer_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, enterprise_customer_id text NOT NULL UNIQUE,
  full_name text, email text, phone text, date_of_birth date, street_address text,
  state text, postcode text, country text, updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- The analytical warehouse supports exactly the three agreed product categories.
CREATE TABLE IF NOT EXISTS boa_gold.dim_product (
  product_sk integer PRIMARY KEY, product_code text NOT NULL UNIQUE, product_name text NOT NULL,
  CHECK((product_sk=1 AND product_code='SAVINGS') OR (product_sk=2 AND product_code='CREDIT_CARD') OR (product_sk=3 AND product_code='LOAN'))
);
-- Stable product surrogate keys keep fact-measure checks repeatable across initialization.
INSERT INTO boa_gold.dim_product(product_sk,product_code,product_name)
VALUES (1,'SAVINGS','Savings account'),(2,'CREDIT_CARD','Credit card'),(3,'LOAN','Loan')
ON CONFLICT(product_sk) DO NOTHING;
-- A source-qualified account fixes its customer/product pair for matching fact references.
CREATE TABLE IF NOT EXISTS boa_gold.dim_account (
  account_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_system text NOT NULL CHECK(source_system IN ('SAVINGS','CARDS','LOANS')), source_account_id text NOT NULL,
  customer_sk bigint NOT NULL REFERENCES boa_gold.dim_customer(customer_sk),
  product_sk integer NOT NULL REFERENCES boa_gold.dim_product(product_sk),
  opened_date date NOT NULL, closed_date date, currency_code text NOT NULL CHECK(currency_code='AUD'),
  UNIQUE(source_system,source_account_id), UNIQUE(account_sk,customer_sk,product_sk),
  CHECK(closed_date IS NULL OR closed_date>=opened_date)
);
CREATE INDEX IF NOT EXISTS gold_account_customer_idx ON boa_gold.dim_account(customer_sk);
-- Calendar attributes derive from the business date, separate from ETL timestamps.
CREATE TABLE IF NOT EXISTS boa_gold.dim_date (
  date_sk integer PRIMARY KEY, full_date date NOT NULL UNIQUE,
  day_of_month integer NOT NULL CHECK(day_of_month BETWEEN 1 AND 31),
  month_number integer NOT NULL CHECK(month_number BETWEEN 1 AND 12), month_name text NOT NULL,
  quarter_number integer NOT NULL CHECK(quarter_number BETWEEN 1 AND 4), year_number integer NOT NULL,
  day_of_week integer NOT NULL CHECK(day_of_week BETWEEN 1 AND 7), is_weekend boolean NOT NULL,
  CHECK(date_sk=extract(year FROM full_date)::integer*10000+extract(month FROM full_date)::integer*100+extract(day FROM full_date)::integer)
);
-- Enforce one account/date fact, correct customer/product ownership and separate AUD measures.
CREATE TABLE IF NOT EXISTS boa_gold.fact_account_daily_snapshot (
  snapshot_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  date_sk integer NOT NULL REFERENCES boa_gold.dim_date(date_sk),
  customer_sk bigint NOT NULL REFERENCES boa_gold.dim_customer(customer_sk),
  account_sk bigint NOT NULL REFERENCES boa_gold.dim_account(account_sk),
  product_sk integer NOT NULL REFERENCES boa_gold.dim_product(product_sk),
  account_status text NOT NULL CHECK(account_status IN ('ACTIVE','CLOSED')),
  savings_balance numeric(18,2) NOT NULL CHECK(savings_balance BETWEEN 0 AND 9999999999999999.99),
  card_outstanding numeric(18,2) NOT NULL CHECK(card_outstanding BETWEEN 0 AND 9999999999999999.99),
  loan_principal_outstanding numeric(18,2) NOT NULL CHECK(loan_principal_outstanding BETWEEN 0 AND 9999999999999999.99),
  credit_limit_amount numeric(18,2) NOT NULL CHECK(credit_limit_amount BETWEEN 0 AND 9999999999999999.99),
  vault_balance_version_id bigint NOT NULL REFERENCES boa_vault.sat_account_daily_balance(version_id),
  load_run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(), UNIQUE(account_sk,date_sk),
  FOREIGN KEY(account_sk,customer_sk,product_sk) REFERENCES boa_gold.dim_account(account_sk,customer_sk,product_sk),
  CHECK((product_sk=1 AND card_outstanding=0 AND loan_principal_outstanding=0 AND credit_limit_amount=0)
    OR (product_sk=2 AND savings_balance=0 AND loan_principal_outstanding=0)
    OR (product_sk=3 AND savings_balance=0 AND card_outstanding=0 AND credit_limit_amount=0)),
  CHECK(account_status<>'CLOSED' OR (savings_balance=0 AND card_outstanding=0 AND loan_principal_outstanding=0))
);
CREATE INDEX IF NOT EXISTS fact_date_customer_idx ON boa_gold.fact_account_daily_snapshot(date_sk,customer_sk);
CREATE INDEX IF NOT EXISTS fact_customer_date_idx ON boa_gold.fact_account_daily_snapshot(customer_sk,date_sk);
-- Publish a common date only when its complete expected account population is present.
CREATE TABLE IF NOT EXISTS boa_audit.published_day (
  business_date date PRIMARY KEY, published_run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expected_account_count bigint NOT NULL CHECK(expected_account_count>=0),
  actual_account_count bigint NOT NULL CHECK(actual_account_count=expected_account_count)
);

-- The registry is a verified input, not an entity-resolution algorithm.
COMMENT ON TABLE boa_audit.identity_registry IS 'Synthetic verified identity crosswalk; names and contact details never resolve identity.';
COMMENT ON VIEW boa_silver.customer_crosswalk IS 'View of the verified Audit input registry; no duplicate storage or physical keys. Silver loading validates accepted customer references.';
COMMENT ON TABLE boa_bronze.source_record IS 'Immutable input payload evidence; content deduplicated within batch and linked to every processing run.';
COMMENT ON TABLE boa_silver.enterprise_customer IS 'Current accepted customer profile with per-attribute SAVINGS > CARDS > LOANS precedence and provenance.';
COMMENT ON TABLE boa_vault.sat_account_daily_balance IS 'Append-only processing history at account/business-date; version_id provides deterministic order.';
COMMENT ON TABLE boa_gold.dim_customer IS 'SCD Type 1 current customer description; descriptive history remains in the Vault.';
COMMENT ON TABLE boa_gold.fact_account_daily_snapshot IS 'One account on one business date; semi-additive balances must never be summed across dates.';
COMMENT ON COLUMN boa_gold.fact_account_daily_snapshot.vault_balance_version_id IS 'Exact accepted Vault observation supplying this Gold fact.';
COMMENT ON COLUMN boa_gold.dim_date.day_of_week IS 'ISO weekday: Monday=1 and Sunday=7.';
COMMENT ON COLUMN boa_audit.published_day.published_run_id IS 'All facts on this date must carry this run ID; publication is atomic across required sources.';

-- Count logical accepted input records once, independent of downstream fan-out or unchanged versions.
CREATE OR REPLACE FUNCTION boa_audit.count_written(input_run uuid) RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(accepted_count),0)::bigint FROM boa_audit.source_file WHERE run_id=input_run;
$$;

-- One immutable accepted event per source-qualified account and local transaction ID.
CREATE TABLE IF NOT EXISTS boa_silver.account_transaction (
  account_key bigint NOT NULL REFERENCES boa_silver.account(account_key),
  transaction_date date NOT NULL, source_transaction_id text NOT NULL,
  transaction_type text NOT NULL CHECK(transaction_type IN
    ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','INTEREST','FEE','PURCHASE','PAYMENT','REFUND','REPAYMENT','DRAWDOWN','INTEREST_CHARGE')),
  signed_amount numeric(18,2) NOT NULL CHECK(signed_amount BETWEEN -9999999999999999.99 AND 9999999999999999.99),
  counterparty text, category_code text,
  raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(account_key,source_transaction_id)
);
CREATE INDEX IF NOT EXISTS silver_transaction_date_idx ON boa_silver.account_transaction(transaction_date,account_key);

-- Transactions are append-only events, without descriptive hashdiff/version history.
CREATE TABLE IF NOT EXISTS boa_vault.sat_account_transaction (
  transaction_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_hk bigint NOT NULL REFERENCES boa_vault.hub_account(account_hk),
  source_transaction_id text NOT NULL, transaction_date date NOT NULL, transaction_type text NOT NULL,
  signed_amount numeric(18,2) NOT NULL CHECK(signed_amount BETWEEN -9999999999999999.99 AND 9999999999999999.99),
  counterparty text, category_code text,
  raw_record_id bigint NOT NULL REFERENCES boa_bronze.source_record(raw_record_id),
  load_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(), record_source text NOT NULL,
  run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  UNIQUE(account_hk,source_transaction_id)
);
CREATE INDEX IF NOT EXISTS vault_transaction_date_idx ON boa_vault.sat_account_transaction(transaction_date,account_hk);

-- A shared event vocabulary supports aggregation across heterogeneous source transaction types.
CREATE TABLE IF NOT EXISTS boa_gold.dim_transaction_type (
  transaction_type_sk integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_type_code text NOT NULL UNIQUE, transaction_type_name text NOT NULL
);
INSERT INTO boa_gold.dim_transaction_type(transaction_type_code,transaction_type_name)
VALUES ('DEPOSIT','Deposit'),('WITHDRAWAL','Withdrawal'),('TRANSFER_IN','Transfer in'),
  ('TRANSFER_OUT','Transfer out'),('INTEREST','Interest'),('FEE','Fee'),('PURCHASE','Purchase'),
  ('PAYMENT','Payment'),('REFUND','Refund'),('REPAYMENT','Repayment'),('DRAWDOWN','Drawdown'),
  ('INTEREST_CHARGE','Interest charge')
ON CONFLICT(transaction_type_code) DO NOTHING;

-- Transaction amounts are additive at one account/event grain, with exact Vault provenance.
CREATE TABLE IF NOT EXISTS boa_gold.fact_transaction (
  transaction_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, source_transaction_id text NOT NULL,
  date_sk integer NOT NULL REFERENCES boa_gold.dim_date(date_sk),
  customer_sk bigint NOT NULL REFERENCES boa_gold.dim_customer(customer_sk),
  account_sk bigint NOT NULL REFERENCES boa_gold.dim_account(account_sk),
  product_sk integer NOT NULL REFERENCES boa_gold.dim_product(product_sk),
  transaction_type_sk integer NOT NULL REFERENCES boa_gold.dim_transaction_type(transaction_type_sk),
  signed_amount numeric(18,2) NOT NULL CHECK(signed_amount BETWEEN -9999999999999999.99 AND 9999999999999999.99),
  counterparty text, category_code text,
  vault_transaction_id bigint NOT NULL REFERENCES boa_vault.sat_account_transaction(transaction_id),
  load_run_id uuid NOT NULL REFERENCES boa_audit.pipeline_run(run_id),
  loaded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(account_sk,source_transaction_id),
  FOREIGN KEY(account_sk,customer_sk,product_sk) REFERENCES boa_gold.dim_account(account_sk,customer_sk,product_sk)
);
CREATE INDEX IF NOT EXISTS fact_transaction_date_customer_idx ON boa_gold.fact_transaction(date_sk,customer_sk);
CREATE INDEX IF NOT EXISTS fact_transaction_account_date_idx ON boa_gold.fact_transaction(account_sk,date_sk);
COMMENT ON TABLE boa_vault.sat_account_transaction IS 'Immutable account events; corrections require new compensating event IDs, never historical updates.';
COMMENT ON TABLE boa_gold.fact_transaction IS 'One source-qualified account transaction; signed movements are additive across dates.';
