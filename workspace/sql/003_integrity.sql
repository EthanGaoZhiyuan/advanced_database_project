/*
Design layers: Silver, Vault and Gold integrity, checked against Bronze and Audit.
Reads: Bronze payloads, Audit raw-run membership/verified registry, Silver accounts,
       Vault account hubs/balance versions/events and Gold account/date/type dimensions.
Writes: Validation functions and triggers; this script does not load business rows.
Execution order: run after 001_schema.sql and 002_reports.sql in 02_create_schemas.py,
                 before source ingestion and downstream warehouse loading.
Context: NEW/OLD trigger rows; no external session variables.
Foreign keys alone cannot prove source-record provenance or account semantics.
*/

-- Reject changes to fixed account identity/ownership/product/limit and mismatched raw lineage.
CREATE OR REPLACE FUNCTION boa_silver.enforce_account_contract() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r boa_bronze.source_record%ROWTYPE; mapped_customer text;
BEGIN
  IF TG_OP='UPDATE' AND (OLD.source_system,OLD.source_account_id,OLD.enterprise_customer_id,
      OLD.product_code,OLD.credit_limit) IS DISTINCT FROM
      (NEW.source_system,NEW.source_account_id,NEW.enterprise_customer_id,NEW.product_code,NEW.credit_limit) THEN
    RAISE EXCEPTION 'IMMUTABLE_ACCOUNT_CHANGE: Unsupported account identity, ownership, product, or credit-limit change [%/%]', NEW.source_system, NEW.source_account_id;
  END IF;
  SELECT * INTO r FROM boa_bronze.source_record WHERE raw_record_id=NEW.raw_record_id;
  IF NOT FOUND OR r.source_system<>NEW.source_system OR r.entity_name<>'accounts'
      OR r.source_record_key<>NEW.source_account_id OR r.business_date IS NOT NULL
      OR (r.payload->>'account_id') IS DISTINCT FROM NEW.source_account_id THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Invalid account raw provenance [%/%]', NEW.source_system, NEW.source_account_id;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM boa_audit.raw_run_record WHERE run_id=NEW.run_id AND raw_record_id=NEW.raw_record_id) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Account raw record is outside its processing run [%/%]', NEW.source_system, NEW.source_account_id;
  END IF;
  SELECT enterprise_customer_id INTO mapped_customer FROM boa_audit.identity_registry
    WHERE source_system=NEW.source_system AND source_customer_id=r.payload->>'customer_id'
      AND verification_status='VERIFIED';
  IF mapped_customer IS DISTINCT FROM NEW.enterprise_customer_id THEN
    RAISE EXCEPTION 'ILLEGAL_OWNERSHIP_CHANGE: Raw account owner does not match the verified crosswalk [%/%]', NEW.source_system, NEW.source_account_id;
  END IF;
  IF ((r.payload->>'opened_date')::date,(r.payload->>'closed_date')::date,upper(trim(r.payload->>'currency_code')),
      (r.payload->>'credit_limit')::numeric,(r.payload->>'original_principal')::numeric)
    IS DISTINCT FROM (NEW.opened_date,NEW.closed_date,NEW.currency_code,NEW.credit_limit,NEW.original_principal) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Accepted account profile differs from its original raw values [%/%]', NEW.source_system, NEW.source_account_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS account_contract ON boa_silver.account;
-- Apply the fixed account contract to every accepted Silver insert or correction.
CREATE TRIGGER account_contract BEFORE INSERT OR UPDATE ON boa_silver.account
FOR EACH ROW EXECUTE FUNCTION boa_silver.enforce_account_contract();

-- A daily observation must match opening/closure rules, its product measure and original raw row.
CREATE OR REPLACE FUNCTION boa_silver.enforce_balance_contract() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a boa_silver.account%ROWTYPE; r boa_bronze.source_record%ROWTYPE;
        expected_status text; amount_key text; expected_amount numeric;
BEGIN
  SELECT * INTO STRICT a FROM boa_silver.account WHERE account_key=NEW.account_key;
  expected_status := CASE WHEN a.closed_date IS NOT NULL AND NEW.balance_date>=a.closed_date THEN 'CLOSED' ELSE 'ACTIVE' END;
  IF NEW.balance_date<a.opened_date OR NEW.account_status<>expected_status THEN
    RAISE EXCEPTION 'UNEXPECTED_SNAPSHOT: Invalid account/date status or snapshot before opening [%/%|%]', a.source_system, a.source_account_id, NEW.balance_date;
  END IF;
  IF (a.product_code='SAVINGS' AND (NEW.card_outstanding<>0 OR NEW.loan_principal_outstanding<>0))
    OR (a.product_code='CREDIT_CARD' AND (NEW.savings_balance<>0 OR NEW.loan_principal_outstanding<>0))
    OR (a.product_code='LOAN' AND (NEW.savings_balance<>0 OR NEW.card_outstanding<>0)) THEN
    RAISE EXCEPTION 'UNSUPPORTED_PRODUCT: Balance measures disagree with product category [%/%|%]', a.source_system, a.source_account_id, NEW.balance_date;
  END IF;
  SELECT * INTO r FROM boa_bronze.source_record WHERE raw_record_id=NEW.raw_record_id;
  IF NOT FOUND OR r.source_system<>a.source_system OR r.entity_name<>'daily_balances'
    OR r.source_record_key<>a.source_account_id||'|'||NEW.balance_date::text
    OR r.business_date IS DISTINCT FROM NEW.balance_date
    OR r.payload->>'account_id' IS DISTINCT FROM a.source_account_id
    OR r.payload->>'balance_date' IS DISTINCT FROM NEW.balance_date::text THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Invalid balance raw source, key, entity, or business date [%/%|%]', a.source_system, a.source_account_id, NEW.balance_date;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM boa_audit.raw_run_record WHERE run_id=NEW.run_id AND raw_record_id=NEW.raw_record_id) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Balance raw record is outside its processing run [%/%|%]', a.source_system, a.source_account_id, NEW.balance_date;
  END IF;
  amount_key := CASE a.product_code WHEN 'SAVINGS' THEN 'closing_balance' WHEN 'CREDIT_CARD' THEN 'outstanding_balance' ELSE 'principal_outstanding' END;
  expected_amount := (r.payload->>amount_key)::numeric;
  IF expected_amount IS DISTINCT FROM (NEW.savings_balance+NEW.card_outstanding+NEW.loan_principal_outstanding) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Accepted balance differs from its original raw amount [%/%|%]', a.source_system, a.source_account_id, NEW.balance_date;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS balance_contract ON boa_silver.account_daily_balance;
-- Validate new and corrected Silver observations before they can enter historical loading.
CREATE TRIGGER balance_contract BEFORE INSERT OR UPDATE ON boa_silver.account_daily_balance
FOR EACH ROW EXECUTE FUNCTION boa_silver.enforce_balance_contract();

-- Accepted Vault keys, relationships and historical versions are append-only evidence.
CREATE OR REPLACE FUNCTION boa_vault.prevent_history_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE old_row jsonb := to_jsonb(OLD); record_system text; record_key text;
BEGIN
  SELECT source_system, source_account_id INTO record_system, record_key
  FROM boa_vault.hub_account WHERE account_hk=(old_row->>'account_hk')::bigint;
  IF record_key IS NULL THEN
    SELECT 'REGISTRY', enterprise_customer_id INTO record_system, record_key
    FROM boa_vault.hub_customer WHERE customer_hk=(old_row->>'customer_hk')::bigint;
  END IF;
  RAISE EXCEPTION 'APPEND_ONLY_VAULT: Vault business keys, relationships, and satellite versions are append-only [%/%]',
    record_system, record_key;
END $$;
-- Protect every required Vault object from in-place historical updates or deletions.
DO $vault_triggers$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['hub_customer','hub_account','link_customer_account','sat_customer_profile','sat_account_profile','sat_account_daily_balance','sat_account_transaction'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS append_only ON boa_vault.%I',tbl);
    EXECUTE format('CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON boa_vault.%I FOR EACH ROW EXECUTE FUNCTION boa_vault.prevent_history_mutation()',tbl);
  END LOOP;
END $vault_triggers$;

-- Require each Gold fact to equal its referenced Vault account/date observation and status.
CREATE OR REPLACE FUNCTION boa_gold.enforce_fact_provenance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v boa_vault.sat_account_daily_balance%ROWTYPE; a boa_gold.dim_account%ROWTYPE;
        business_day date; vault_source text; vault_account text;
BEGIN
  SELECT * INTO STRICT v FROM boa_vault.sat_account_daily_balance WHERE version_id=NEW.vault_balance_version_id;
  SELECT * INTO STRICT a FROM boa_gold.dim_account WHERE account_sk=NEW.account_sk;
  SELECT full_date INTO STRICT business_day FROM boa_gold.dim_date WHERE date_sk=NEW.date_sk;
  SELECT source_system,source_account_id INTO STRICT vault_source,vault_account
    FROM boa_vault.hub_account WHERE account_hk=v.account_hk;
  IF (vault_source,vault_account,v.balance_date,v.account_status,v.savings_balance,v.card_outstanding,v.loan_principal_outstanding)
     IS DISTINCT FROM (a.source_system,a.source_account_id,business_day,NEW.account_status,
      NEW.savings_balance,NEW.card_outstanding,NEW.loan_principal_outstanding) THEN
    RAISE EXCEPTION 'INVALID_VAULT_LINEAGE: Gold fact does not match the referenced Vault observation [%/%|%]', a.source_system, a.source_account_id, business_day;
  END IF;
  IF business_day<a.opened_date OR NEW.account_status<>
    (CASE WHEN a.closed_date IS NOT NULL AND business_day>=a.closed_date THEN 'CLOSED' ELSE 'ACTIVE' END) THEN
    RAISE EXCEPTION 'UNEXPECTED_SNAPSHOT: Gold daily account status is inconsistent with account dates [%/%|%]', a.source_system, a.source_account_id, business_day;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fact_provenance ON boa_gold.fact_account_daily_snapshot;
-- Recheck Vault lineage for initial facts and same-date republishing updates alike.
CREATE TRIGGER fact_provenance BEFORE INSERT OR UPDATE ON boa_gold.fact_account_daily_snapshot
FOR EACH ROW EXECUTE FUNCTION boa_gold.enforce_fact_provenance();


-- Immutable Silver events still refresh raw/run lineage when the same business event is reprocessed.
CREATE OR REPLACE FUNCTION boa_silver.enforce_transaction_contract() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a boa_silver.account%ROWTYPE; r boa_bronze.source_record%ROWTYPE; n record;
BEGIN
  IF TG_OP='DELETE' THEN
    SELECT * INTO STRICT a FROM boa_silver.account WHERE account_key=OLD.account_key;
    RAISE EXCEPTION 'IMMUTABLE_TRANSACTION: accepted events cannot be deleted [%/%]',a.source_system,OLD.source_transaction_id;
  END IF;
  SELECT * INTO STRICT a FROM boa_silver.account WHERE account_key=NEW.account_key;
  IF TG_OP='UPDATE' AND
    (OLD.account_key,OLD.source_transaction_id,OLD.transaction_date,OLD.transaction_type,OLD.signed_amount,OLD.counterparty,OLD.category_code)
    IS DISTINCT FROM
    (NEW.account_key,NEW.source_transaction_id,NEW.transaction_date,NEW.transaction_type,NEW.signed_amount,NEW.counterparty,NEW.category_code) THEN
    RAISE EXCEPTION 'IMMUTABLE_TRANSACTION: accepted events require compensating new IDs [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  IF NEW.transaction_date<a.opened_date OR NEW.transaction_date>=a.closed_date THEN
    RAISE EXCEPTION 'UNEXPECTED_TRANSACTION: event requires an active account [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  SELECT * INTO r FROM boa_bronze.source_record WHERE raw_record_id=NEW.raw_record_id;
  IF NOT FOUND OR r.source_system<>a.source_system OR r.entity_name<>'transactions'
    OR r.source_record_key IS DISTINCT FROM NEW.source_transaction_id
    OR r.business_date IS DISTINCT FROM NEW.transaction_date
    OR r.payload->>'account_id' IS DISTINCT FROM a.source_account_id
    OR boa_audit.transaction_key(r.source_system,r.payload) IS DISTINCT FROM NEW.source_transaction_id
    OR NOT EXISTS (SELECT 1 FROM boa_audit.raw_run_record m JOIN boa_audit.pipeline_run p USING(run_id)
      WHERE m.run_id=NEW.run_id AND m.raw_record_id=NEW.raw_record_id AND p.batch_id=r.batch_id) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: transaction source, key, date or run provenance differs [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  SELECT * INTO n FROM boa_audit.normalise_transaction(r.source_system,r.payload);
  IF (NEW.transaction_date,NEW.transaction_type,NEW.signed_amount,NEW.counterparty,NEW.category_code)
    IS DISTINCT FROM (n.transaction_date,n.transaction_type,n.signed_amount,n.counterparty,n.category_code) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: transaction values differ from the referenced raw event [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS transaction_contract ON boa_silver.account_transaction;
CREATE TRIGGER transaction_contract BEFORE INSERT OR UPDATE OR DELETE ON boa_silver.account_transaction
FOR EACH ROW EXECUTE FUNCTION boa_silver.enforce_transaction_contract();

-- Vault event lineage proves source-qualified account, immutable event content and original run membership.
CREATE OR REPLACE FUNCTION boa_vault.enforce_transaction_provenance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a boa_vault.hub_account%ROWTYPE; r boa_bronze.source_record%ROWTYPE; n record;
BEGIN
  SELECT * INTO STRICT a FROM boa_vault.hub_account WHERE account_hk=NEW.account_hk;
  SELECT * INTO r FROM boa_bronze.source_record WHERE raw_record_id=NEW.raw_record_id;
  IF NOT FOUND OR r.source_system<>a.source_system OR r.entity_name<>'transactions'
    OR NEW.record_source IS DISTINCT FROM a.source_system
    OR r.source_record_key IS DISTINCT FROM NEW.source_transaction_id
    OR r.business_date IS DISTINCT FROM NEW.transaction_date
    OR r.payload->>'account_id' IS DISTINCT FROM a.source_account_id
    OR boa_audit.transaction_key(r.source_system,r.payload) IS DISTINCT FROM NEW.source_transaction_id
    OR NOT EXISTS (SELECT 1 FROM boa_audit.raw_run_record m JOIN boa_audit.pipeline_run p USING(run_id)
      WHERE m.run_id=NEW.run_id AND m.raw_record_id=NEW.raw_record_id AND p.batch_id=r.batch_id) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Vault transaction does not match its raw event and processing run [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  SELECT * INTO n FROM boa_audit.normalise_transaction(r.source_system,r.payload);
  IF (NEW.transaction_date,NEW.transaction_type,NEW.signed_amount,NEW.counterparty,NEW.category_code)
    IS DISTINCT FROM (n.transaction_date,n.transaction_type,n.signed_amount,n.counterparty,n.category_code) THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Vault transaction values differ from the raw event [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS transaction_provenance ON boa_vault.sat_account_transaction;
CREATE TRIGGER transaction_provenance BEFORE INSERT ON boa_vault.sat_account_transaction
FOR EACH ROW EXECUTE FUNCTION boa_vault.enforce_transaction_provenance();

-- Gold must reference the exact Vault event, with matching account, date, type and signed amount.
CREATE OR REPLACE FUNCTION boa_gold.enforce_transaction_provenance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v boa_vault.sat_account_transaction%ROWTYPE; a boa_gold.dim_account%ROWTYPE;
        h boa_vault.hub_account%ROWTYPE; business_day date; type_code text;
BEGIN
  SELECT * INTO STRICT v FROM boa_vault.sat_account_transaction WHERE transaction_id=NEW.vault_transaction_id;
  SELECT * INTO STRICT a FROM boa_gold.dim_account WHERE account_sk=NEW.account_sk;
  SELECT * INTO STRICT h FROM boa_vault.hub_account WHERE account_hk=v.account_hk;
  SELECT full_date INTO STRICT business_day FROM boa_gold.dim_date WHERE date_sk=NEW.date_sk;
  SELECT transaction_type_code INTO STRICT type_code FROM boa_gold.dim_transaction_type
    WHERE transaction_type_sk=NEW.transaction_type_sk;
  IF (h.source_system,h.source_account_id,v.source_transaction_id,v.transaction_date,v.transaction_type,
      v.signed_amount,v.counterparty,v.category_code)
    IS DISTINCT FROM (a.source_system,a.source_account_id,NEW.source_transaction_id,business_day,type_code,
      NEW.signed_amount,NEW.counterparty,NEW.category_code) THEN
    RAISE EXCEPTION 'INVALID_VAULT_LINEAGE: Gold transaction differs from the referenced Vault event [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  IF business_day<a.opened_date OR business_day>=a.closed_date THEN
    RAISE EXCEPTION 'UNEXPECTED_TRANSACTION: Gold event requires an active account [%/%]',a.source_system,NEW.source_transaction_id;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS transaction_provenance ON boa_gold.fact_transaction;
CREATE TRIGGER transaction_provenance BEFORE INSERT OR UPDATE ON boa_gold.fact_transaction
FOR EACH ROW EXECUTE FUNCTION boa_gold.enforce_transaction_provenance();
