/*
Layer: Silver (cleansing, verified identity integration and daily observations).
Reads: current-run Bronze/raw_run_record, Audit identity_registry and existing Silver.
Writes: Silver customers, accounts, daily balances and immutable transactions; crosswalk is an input-registry view.
Order: step 05, after Bronze; commit together with load_vault.sql.
Context: boa.run_id (UUID), boa.dates (PostgreSQL date array), supplied by the Python step.
SQL guards enforce business rules and identify an offending source/key for failure auditing.
*/

-- Retry membership selects the current extract, even when a raw row originated in an earlier run.
CREATE TEMP TABLE silver_raw ON COMMIT DROP AS
SELECT r.* FROM boa_bronze.source_record r
JOIN boa_audit.raw_run_record m USING(raw_record_id)
WHERE m.run_id=current_setting('boa.run_id')::uuid;
-- statement-break
CREATE INDEX silver_raw_entity_key_idx ON silver_raw(source_system,entity_name,source_record_key);
-- statement-break
DO $$
DECLARE offending text;
BEGIN
  offending := (SELECT source_system||'/'||source_record_key FROM silver_raw
    GROUP BY source_system,entity_name,source_record_key HAVING count(*)>1
    ORDER BY source_system,entity_name,source_record_key LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'CONFLICTING_DUPLICATES: current run has multiple raw versions of a business key [%]', offending;
  END IF;
  offending := (
    SELECT r.source_system||'/'||r.source_record_key FROM silver_raw r
    JOIN boa_audit.pipeline_run p ON p.run_id=current_setting('boa.run_id')::uuid
    WHERE r.batch_id IS DISTINCT FROM p.batch_id OR r.source_record_key IS DISTINCT FROM
      CASE r.entity_name WHEN 'customers' THEN r.payload->>'customer_id'
        WHEN 'accounts' THEN r.payload->>'account_id'
        WHEN 'transactions' THEN boa_audit.transaction_key(r.source_system,r.payload)
        WHEN 'crosswalk' THEN (r.payload->>'source_system')||'|'||(r.payload->>'source_customer_id')
        ELSE (r.payload->>'account_id')||'|'||(r.payload->>'balance_date') END
      OR (r.entity_name='daily_balances' AND
          r.business_date IS DISTINCT FROM boa_audit.boa_date(r.payload->>'balance_date','SAVINGS',
            r.source_system||'/'||r.source_record_key))
      OR (r.entity_name='transactions' AND r.business_date IS DISTINCT FROM boa_audit.transaction_date(r.source_system,r.payload))
      OR (r.entity_name='crosswalk') IS DISTINCT FROM (r.source_system='REGISTRY')
    ORDER BY r.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_RAW_LINEAGE: raw source, business key, date or batch differs from its processing context [%]', offending;
  END IF;
  offending := (
    SELECT r.source_system||'/'||r.source_record_key FROM silver_raw r LEFT JOIN boa_audit.identity_registry x
      ON x.source_system=r.payload->>'source_system' AND x.source_customer_id=r.payload->>'source_customer_id'
    WHERE r.entity_name='crosswalk' AND (x.enterprise_customer_id,x.mapping_method,x.verification_status)
      IS DISTINCT FROM (r.payload->>'enterprise_customer_id',r.payload->>'mapping_method',r.payload->>'verification_status')
    ORDER BY r.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'IDENTITY_CHANGE: registry differs from the current raw verified crosswalk [%]', offending;
  END IF;
END $$;
-- statement-break

-- The same inventory helper runs before typed source ingestion and on the current Bronze extract.
SELECT boa_audit.validate_source_inventory('pg_temp.silver_raw'::regclass);
-- statement-break

-- Retained registry rows cannot replace a mapping missing from the current batch.
CREATE TEMP TABLE silver_registry ON COMMIT DROP AS
SELECT payload->>'source_system' AS source_system,payload->>'source_customer_id' AS source_customer_id,
  payload->>'enterprise_customer_id' AS enterprise_customer_id
FROM silver_raw WHERE entity_name='crosswalk' AND payload->>'verification_status'='VERIFIED';
-- statement-break
CREATE UNIQUE INDEX silver_registry_key_idx ON silver_registry(source_system,source_customer_id);
-- statement-break

-- Accepted profile/account provenance prevents reassignment even if input registry data was edited.
CREATE TEMP TABLE silver_accepted_identity ON COMMIT DROP AS
SELECT c.enterprise_customer_id,p.value->>'source_system' AS source_system,
  p.value->>'source_customer_id' AS source_customer_id
FROM boa_silver.enterprise_customer c CROSS JOIN LATERAL jsonb_each(c.source_provenance) p
WHERE p.value<>'null'::jsonb
UNION
SELECT a.enterprise_customer_id,a.source_system,r.payload->>'customer_id'
FROM boa_silver.account a JOIN boa_bronze.source_record r USING(raw_record_id)
UNION
SELECT c.enterprise_customer_id,p.value->>'source_system',p.value->>'source_customer_id'
FROM boa_vault.sat_customer_profile s JOIN boa_vault.hub_customer c USING(customer_hk)
CROSS JOIN LATERAL jsonb_each(s.source_provenance) p WHERE p.value<>'null'::jsonb
UNION
SELECT c.enterprise_customer_id,a.source_system,r.payload->>'customer_id'
FROM boa_vault.sat_account_profile s JOIN boa_vault.hub_account a USING(account_hk)
JOIN boa_vault.link_customer_account l USING(account_hk)
JOIN boa_vault.hub_customer c USING(customer_hk)
JOIN boa_bronze.source_record r ON r.raw_record_id=(s.source_provenance->>'raw_record_id')::bigint
UNION
SELECT x.enterprise_customer_id,x.source_system,x.source_customer_id
FROM boa_audit.identity_registry x JOIN boa_silver.enterprise_customer c USING(enterprise_customer_id);
-- statement-break
DO $$
DECLARE offending text;
BEGIN
  offending := (
    SELECT r.source_system||'/'||r.source_record_key FROM silver_raw r LEFT JOIN silver_registry x
      ON x.source_system=r.source_system AND x.source_customer_id=r.payload->>'customer_id'
    WHERE r.entity_name IN ('customers','accounts') AND x.enterprise_customer_id IS NULL
    ORDER BY r.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'MISSING_CUSTOMER_MAPPING: no current-batch verified source-qualified identity [%]', offending;
  END IF;
  offending := (
    SELECT old.source_system||'/'||old.source_customer_id FROM silver_accepted_identity old
    JOIN silver_registry x USING(source_system,source_customer_id)
    WHERE x.enterprise_customer_id IS DISTINCT FROM old.enterprise_customer_id
    ORDER BY old.source_system,old.source_customer_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'IDENTITY_CHANGE: verified mapping differs from previously accepted identity provenance [%]', offending;
  END IF;
  offending := (
    SELECT old.source_system||'/'||old.source_customer_id FROM silver_accepted_identity old
    LEFT JOIN silver_raw c ON c.source_system=old.source_system AND c.entity_name='customers'
      AND c.source_record_key=old.source_customer_id
    WHERE c.raw_record_id IS NULL ORDER BY old.source_system,old.source_customer_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_CUSTOMER_INVENTORY: all accepted source customers must remain in the batch [%]', offending;
  END IF;
END $$;
-- statement-break

-- Clean each optional attribute independently; invalid contact/address values are unavailable for precedence.
CREATE TEMP TABLE silver_profiles ON COMMIT DROP AS
WITH trimmed AS (
  SELECT r.source_system,r.raw_record_id,r.payload->>'customer_id' AS source_customer_id,
    x.enterprise_customer_id,
    boa_audit.boa_trim(r.payload->>'full_name') AS full_name,
    lower(boa_audit.boa_trim(r.payload->>'email')) AS email,
    translate(boa_audit.boa_trim(r.payload->>'phone'),boa_audit.boa_whitespace()||'().-','') AS phone,
    boa_audit.boa_date(r.payload->>'date_of_birth_text',r.source_system,r.source_system||'/'||r.source_record_key) AS date_of_birth,
    boa_audit.boa_trim(r.payload->>'street_address') AS street_address,
    upper(boa_audit.boa_trim(r.payload->>'state')) AS state,
    boa_audit.boa_trim(r.payload->>'postcode') AS postcode,
    upper(boa_audit.boa_trim(r.payload->>'country')) AS country
  FROM silver_raw r JOIN boa_audit.identity_registry x
    ON x.source_system=r.source_system AND x.source_customer_id=r.payload->>'customer_id'
    AND x.verification_status='VERIFIED'
  WHERE r.entity_name='customers'
), normalised AS (
  SELECT *, CASE WHEN phone ~ '^0[23478][0-9]{8}$' THEN '+61'||substring(phone,2)
      WHEN phone ~ '^\+61[23478][0-9]{8}$' THEN phone END AS accepted_phone,
    CASE state WHEN 'NEW SOUTH WALES' THEN 'NSW' WHEN 'VICTORIA' THEN 'VIC'
      WHEN 'QUEENSLAND' THEN 'QLD' WHEN 'SOUTH AUSTRALIA' THEN 'SA'
      WHEN 'WESTERN AUSTRALIA' THEN 'WA' WHEN 'TASMANIA' THEN 'TAS'
      WHEN 'NORTHERN TERRITORY' THEN 'NT' WHEN 'AUSTRALIAN CAPITAL TERRITORY' THEN 'ACT'
      ELSE CASE WHEN state IN ('NSW','VIC','QLD','SA','WA','TAS','NT','ACT') THEN state END
    END AS accepted_state
  FROM trimmed
)
SELECT enterprise_customer_id,source_system,source_customer_id,raw_record_id,
  jsonb_build_object('full_name',full_name,
    'email',CASE WHEN email ~ ('^[^'||boa_audit.boa_whitespace()||'@]+@[^'||
      boa_audit.boa_whitespace()||'@]+\.[^'||boa_audit.boa_whitespace()||'@]+$') THEN email END,
    'phone',accepted_phone,'date_of_birth',date_of_birth,'street_address',street_address,
    'state',accepted_state,'postcode',CASE WHEN postcode ~ '^[0-9]{4}$' THEN postcode END,
    'country',CASE WHEN country IN ('AU','AUS','AUSTRALIA') THEN 'AU' END) AS attributes
FROM normalised;
-- statement-break

-- Each attribute has deterministic source precedence, with local customer ID as the tie-breaker.
WITH selected AS (
  SELECT DISTINCT ON (p.enterprise_customer_id,a.key)
    p.enterprise_customer_id,a.key,a.value,
    CASE WHEN a.value<>'null'::jsonb THEN jsonb_build_object('source_system',p.source_system,
      'source_customer_id',p.source_customer_id,'raw_record_id',p.raw_record_id) END AS provenance
  FROM silver_profiles p CROSS JOIN LATERAL jsonb_each(p.attributes) a
  ORDER BY p.enterprise_customer_id,a.key,(a.value='null'::jsonb),
    CASE p.source_system WHEN 'SAVINGS' THEN 1 WHEN 'CARDS' THEN 2 ELSE 3 END,p.source_customer_id COLLATE "C"
), combined AS (
  SELECT enterprise_customer_id,jsonb_object_agg(key,value) AS values,
    jsonb_object_agg(key,provenance) AS provenance FROM selected GROUP BY enterprise_customer_id
)
INSERT INTO boa_silver.enterprise_customer(enterprise_customer_id,full_name,email,phone,date_of_birth,
  street_address,state,postcode,country,source_provenance)
SELECT enterprise_customer_id,values->>'full_name',values->>'email',values->>'phone',
  (values->>'date_of_birth')::date,values->>'street_address',values->>'state',values->>'postcode',
  values->>'country',provenance FROM combined
ON CONFLICT(enterprise_customer_id) DO UPDATE SET full_name=EXCLUDED.full_name,email=EXCLUDED.email,
  phone=EXCLUDED.phone,date_of_birth=EXCLUDED.date_of_birth,street_address=EXCLUDED.street_address,
  state=EXCLUDED.state,postcode=EXCLUDED.postcode,country=EXCLUDED.country,
  source_provenance=EXCLUDED.source_provenance,updated_at=clock_timestamp();
-- statement-break

-- The input registry loads before Silver, so accepted-profile references are checked here rather than by a view FK.
DO $$
DECLARE offending text;
BEGIN
  offending := (
    SELECT r.source_system||'/'||r.source_record_key FROM silver_raw r JOIN boa_audit.identity_registry x
      ON r.payload->>'source_system'=x.source_system AND r.payload->>'source_customer_id'=x.source_customer_id
    LEFT JOIN boa_silver.enterprise_customer c USING(enterprise_customer_id)
    WHERE r.entity_name='crosswalk' AND c.enterprise_customer_id IS NULL
    ORDER BY r.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'MISSING_CUSTOMER: current-run verified mapping has no accepted enterprise profile [%]', offending;
  END IF;
END $$;
-- statement-break

-- Accounts retain source-qualified identities; only their source's fixed product and AUD are accepted.
CREATE TEMP TABLE silver_accounts ON COMMIT DROP AS
SELECT r.source_system,r.payload->>'account_id' AS source_account_id,x.enterprise_customer_id,
  CASE r.source_system WHEN 'SAVINGS' THEN 'SAVINGS' WHEN 'CARDS' THEN 'CREDIT_CARD' ELSE 'LOAN' END AS product_code,
  boa_audit.boa_date(r.payload->>'opened_date','SAVINGS',r.source_system||'/'||r.source_record_key) AS opened_date,
  boa_audit.boa_date(r.payload->>'closed_date','SAVINGS',r.source_system||'/'||r.source_record_key) AS closed_date,
  upper(boa_audit.boa_trim(r.payload->>'currency_code')) AS currency_code,
  CASE WHEN r.source_system='CARDS' THEN boa_audit.boa_money(r.payload->>'credit_limit',r.source_system||'/'||r.source_record_key) END AS credit_limit,
  CASE WHEN r.source_system='LOANS' THEN boa_audit.boa_money(r.payload->>'original_principal',r.source_system||'/'||r.source_record_key) END AS original_principal,
  r.raw_record_id
FROM silver_raw r JOIN boa_audit.identity_registry x
  ON x.source_system=r.source_system AND x.source_customer_id=r.payload->>'customer_id'
  AND x.verification_status='VERIFIED'
WHERE r.entity_name='accounts';
-- statement-break
DO $$
DECLARE offending text;
BEGIN
  offending := (SELECT source_system||'/'||source_account_id FROM silver_accounts
    WHERE currency_code IS DISTINCT FROM 'AUD' ORDER BY source_system,source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'UNSUPPORTED_CURRENCY: only AUD is supported [%]', offending;
  END IF;
  offending := (SELECT source_system||'/'||source_account_id FROM silver_accounts
    WHERE opened_date IS NULL OR closed_date<opened_date ORDER BY source_system,source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INVALID_DATE: opening is required and closure cannot precede opening [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id FROM silver_accounts a
    JOIN silver_raw r USING(raw_record_id)
    WHERE r.payload ? 'product_code' AND r.payload->>'product_code' IS DISTINCT FROM a.product_code
    ORDER BY a.source_system,a.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'UNSUPPORTED_PRODUCT: product category is fixed by the source system [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id FROM silver_accounts a
    JOIN boa_silver.account old USING(source_system,source_account_id)
    JOIN silver_raw current_raw ON current_raw.raw_record_id=a.raw_record_id
    JOIN boa_bronze.source_record old_raw ON old_raw.raw_record_id=old.raw_record_id
    WHERE a.enterprise_customer_id IS DISTINCT FROM old.enterprise_customer_id
      OR current_raw.payload->>'customer_id' IS DISTINCT FROM old_raw.payload->>'customer_id'
    ORDER BY a.source_system,a.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'ILLEGAL_OWNERSHIP_CHANGE: source-local and enterprise account ownership cannot change [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id FROM silver_accounts a
    JOIN boa_silver.account old USING(source_system,source_account_id)
    WHERE (a.product_code,a.opened_date,a.currency_code,a.credit_limit,a.original_principal)
      IS DISTINCT FROM (old.product_code,old.opened_date,old.currency_code,old.credit_limit,old.original_principal)
      OR (old.closed_date IS NOT NULL AND a.closed_date IS DISTINCT FROM old.closed_date)
    ORDER BY a.source_system,a.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'IMMUTABLE_ACCOUNT_CHANGE: product, opening, currency, limit, principal or accepted closure changed [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id FROM silver_accounts a
      JOIN boa_silver.account old USING(source_system,source_account_id)
      JOIN boa_silver.account_daily_balance b ON b.account_key=old.account_key AND b.balance_date>=a.closed_date
      WHERE old.closed_date IS NULL AND a.closed_date IS NOT NULL
        AND NOT(b.balance_date=ANY(current_setting('boa.dates')::date[]))
      ORDER BY a.source_system,a.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_CLOSURE_CORRECTION: supply every historical date affected by the closure [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id FROM silver_accounts a
      LEFT JOIN boa_silver.account old USING(source_system,source_account_id)
      JOIN boa_audit.published_day d ON d.business_date>=a.opened_date
      WHERE old.account_key IS NULL AND NOT(d.business_date=ANY(current_setting('boa.dates')::date[]))
      ORDER BY a.source_system,a.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_NEW_ACCOUNT_HISTORY: new account requires every published date since opening [%]', offending;
  END IF;
  offending := (SELECT old.source_system||'/'||old.source_account_id FROM boa_silver.account old
    LEFT JOIN silver_accounts a USING(source_system,source_account_id)
    WHERE a.source_account_id IS NULL ORDER BY old.source_system,old.source_account_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_ACCOUNT_INVENTORY: all accepted accounts must remain in the batch [%]', offending;
  END IF;
END $$;
-- statement-break

-- Provenance triggers verify the raw owner, account attributes and processing-run membership.
INSERT INTO boa_silver.account(source_system,source_account_id,enterprise_customer_id,product_code,
  opened_date,closed_date,currency_code,credit_limit,original_principal,raw_record_id,run_id)
SELECT source_system,source_account_id,enterprise_customer_id,product_code,opened_date,closed_date,
  currency_code,credit_limit,original_principal,raw_record_id,current_setting('boa.run_id')::uuid
FROM silver_accounts
ON CONFLICT(source_system,source_account_id) DO UPDATE SET enterprise_customer_id=EXCLUDED.enterprise_customer_id,
  product_code=EXCLUDED.product_code,opened_date=EXCLUDED.opened_date,closed_date=EXCLUDED.closed_date,
  currency_code=EXCLUDED.currency_code,credit_limit=EXCLUDED.credit_limit,original_principal=EXCLUDED.original_principal,
  raw_record_id=EXCLUDED.raw_record_id,run_id=EXCLUDED.run_id,updated_at=clock_timestamp();
-- statement-break

-- Monetary input stays NUMERIC throughout; no cast may round an unvalidated value.
CREATE TEMP TABLE silver_balances ON COMMIT DROP AS
SELECT r.source_system,r.payload->>'account_id' AS source_account_id,
  boa_audit.boa_date(r.payload->>'balance_date','SAVINGS',r.source_system||'/'||r.source_record_key) AS balance_date,
  boa_audit.boa_money(r.payload->>CASE r.source_system WHEN 'SAVINGS' THEN 'closing_balance'
    WHEN 'CARDS' THEN 'outstanding_balance' ELSE 'principal_outstanding' END,r.source_system||'/'||r.source_record_key) AS amount,r.raw_record_id
FROM silver_raw r WHERE r.entity_name='daily_balances';
-- statement-break
CREATE UNIQUE INDEX silver_balances_key_idx ON silver_balances(source_system,source_account_id,balance_date);
-- statement-break
DO $$
DECLARE offending text;
BEGIN
  offending := (SELECT r.source_system||'/'||r.source_record_key
    FROM silver_balances b JOIN boa_silver.account a USING(source_system,source_account_id)
      JOIN silver_raw r ON r.raw_record_id=b.raw_record_id
      WHERE b.balance_date IS NULL OR b.balance_date<a.opened_date
        OR NOT(b.balance_date=ANY(current_setting('boa.dates')::date[]))
      ORDER BY b.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'UNEXPECTED_SNAPSHOT: date is outside the batch or precedes account opening [%]', offending;
  END IF;
  offending := (SELECT b.source_system||'/'||b.source_account_id||'|'||b.balance_date::text
    FROM silver_balances b JOIN boa_silver.account a USING(source_system,source_account_id)
    WHERE b.balance_date>=a.closed_date AND b.amount<>0 ORDER BY b.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'NONZERO_CLOSED_BALANCE: closed accounts must have zero balances [%]', offending;
  END IF;
  offending := (SELECT b.source_system||'/'||b.source_account_id||'|'||b.balance_date::text
    FROM silver_balances b JOIN boa_silver.account a USING(source_system,source_account_id)
    WHERE a.product_code='LOAN' AND b.amount>a.original_principal ORDER BY b.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'PRINCIPAL_EXCEEDED: outstanding principal exceeds original principal [%]', offending;
  END IF;
  offending := (SELECT b.source_system||'/'||b.source_account_id||'|'||b.balance_date::text
    FROM silver_balances b JOIN boa_silver.account a USING(source_system,source_account_id)
    WHERE a.product_code='CREDIT_CARD' AND b.amount>a.credit_limit ORDER BY b.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'CARD_LIMIT_EXCEEDED: card debt exceeds its fixed credit limit [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||a.source_account_id||'|'||d.business_date::text
      FROM boa_silver.account a CROSS JOIN unnest(current_setting('boa.dates')::date[]) d(business_date)
      LEFT JOIN silver_balances b ON b.source_system=a.source_system AND b.source_account_id=a.source_account_id
        AND b.balance_date=d.business_date
      WHERE a.opened_date<=d.business_date AND b.raw_record_id IS NULL
      ORDER BY a.source_system,a.source_account_id,d.business_date LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'MISSING_ACCOUNT_DATE: missing required snapshot is never interpreted as zero [%]', offending;
  END IF;
END $$;
-- statement-break

-- Grain is one source-qualified account/date; closure is inclusive and only its product's measure is populated.
INSERT INTO boa_silver.account_daily_balance(account_key,balance_date,account_status,savings_balance,
  card_outstanding,loan_principal_outstanding,raw_record_id,run_id)
SELECT a.account_key,b.balance_date,CASE WHEN b.balance_date>=a.closed_date THEN 'CLOSED' ELSE 'ACTIVE' END,
  CASE WHEN a.product_code='SAVINGS' THEN b.amount ELSE 0 END,
  CASE WHEN a.product_code='CREDIT_CARD' THEN b.amount ELSE 0 END,
  CASE WHEN a.product_code='LOAN' THEN b.amount ELSE 0 END,b.raw_record_id,current_setting('boa.run_id')::uuid
FROM silver_balances b JOIN boa_silver.account a USING(source_system,source_account_id)
ON CONFLICT(account_key,balance_date) DO UPDATE SET account_status=EXCLUDED.account_status,
  savings_balance=EXCLUDED.savings_balance,card_outstanding=EXCLUDED.card_outstanding,
  loan_principal_outstanding=EXCLUDED.loan_principal_outstanding,raw_record_id=EXCLUDED.raw_record_id,run_id=EXCLUDED.run_id;

-- statement-break
-- Source-specific dates, types, signs and counterparties share one inspectable database mapping.
CREATE TEMP TABLE silver_transactions ON COMMIT DROP AS
SELECT a.account_key,r.source_system,a.source_account_id,
  boa_audit.transaction_key(r.source_system,r.payload) AS source_transaction_id,
  n.transaction_date,n.transaction_type,n.signed_amount::numeric(18,2),n.counterparty,n.category_code,
  r.raw_record_id
FROM silver_raw r JOIN boa_silver.account a
  ON a.source_system=r.source_system AND a.source_account_id=r.payload->>'account_id'
CROSS JOIN LATERAL boa_audit.normalise_transaction(r.source_system,r.payload) n
WHERE r.entity_name='transactions';
-- statement-break
CREATE UNIQUE INDEX silver_transactions_identity_idx ON silver_transactions(source_system,source_transaction_id);
CREATE INDEX silver_transactions_date_idx ON silver_transactions(account_key,transaction_date);
-- statement-break
DO $transaction_dates$
DECLARE offending text;
BEGIN
  offending := (SELECT t.source_system||'/'||t.source_transaction_id FROM silver_transactions t
    JOIN boa_silver.account a USING(account_key)
    WHERE t.transaction_date<a.opened_date OR t.transaction_date>=a.closed_date
      OR NOT(t.transaction_date=ANY(current_setting('boa.dates')::date[]))
    ORDER BY t.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'UNEXPECTED_TRANSACTION: events require an active account and a declared business date [%]', offending;
  END IF;
END $transaction_dates$;
-- statement-break

-- Replace the proposed dates in a temporary event population before checking financial reconciliation.
-- Existing events outside the batch remain relevant to prior/next-day balances.
CREATE TEMP TABLE silver_proposed_transactions ON COMMIT DROP AS
SELECT account_key,source_transaction_id,transaction_date,transaction_type,signed_amount,counterparty,category_code
FROM silver_transactions
UNION ALL
SELECT old.account_key,old.source_transaction_id,old.transaction_date,old.transaction_type,
  old.signed_amount,old.counterparty,old.category_code FROM boa_silver.account_transaction old
WHERE NOT(old.transaction_date=ANY(current_setting('boa.dates')::date[]))
  AND NOT EXISTS (SELECT 1 FROM silver_transactions t
    WHERE t.account_key=old.account_key AND t.source_transaction_id=old.source_transaction_id);
-- statement-break
DO $transaction_reconciliation$
DECLARE offending text;
BEGIN
  offending := (SELECT a.source_system||'/'||a.source_account_id||'|'||m.balance_date::text
    FROM boa_audit.transaction_balance_mismatches('pg_temp.silver_proposed_transactions'::regclass) m
    JOIN boa_silver.account a USING(account_key)
    ORDER BY a.source_system,a.source_account_id,m.balance_date LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'BALANCE_TXN_MISMATCH: balance change differs from net signed transaction movement [%]', offending;
  END IF;
  offending := (SELECT t.source_system||'/'||t.source_transaction_id FROM silver_transactions t
    JOIN boa_silver.account old_account ON old_account.source_system=t.source_system
    JOIN boa_silver.account_transaction old ON old.account_key=old_account.account_key
      AND old.source_transaction_id=t.source_transaction_id
    WHERE (old.account_key,old.transaction_date,old.transaction_type,old.signed_amount,old.counterparty,old.category_code)
      IS DISTINCT FROM (t.account_key,t.transaction_date,t.transaction_type,t.signed_amount,t.counterparty,t.category_code)
    ORDER BY t.raw_record_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'IMMUTABLE_TRANSACTION: accepted events require compensating new IDs instead of modification [%]', offending;
  END IF;
  offending := (SELECT a.source_system||'/'||old.source_transaction_id FROM boa_silver.account_transaction old
    JOIN boa_silver.account a USING(account_key)
    LEFT JOIN silver_transactions t ON t.account_key=old.account_key AND t.source_transaction_id=old.source_transaction_id
    WHERE old.transaction_date=ANY(current_setting('boa.dates')::date[]) AND t.raw_record_id IS NULL
    ORDER BY a.source_system,old.source_transaction_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_TRANSACTION_INVENTORY: every accepted event on the supplied dates must remain present [%]', offending;
  END IF;
END $transaction_reconciliation$;
-- statement-break

-- Unchanged events refresh their processing lineage; genuine business changes were rejected above.
INSERT INTO boa_silver.account_transaction(account_key,source_transaction_id,transaction_date,
  transaction_type,signed_amount,counterparty,category_code,raw_record_id,run_id)
SELECT account_key,source_transaction_id,transaction_date,transaction_type,signed_amount,counterparty,
  category_code,raw_record_id,current_setting('boa.run_id')::uuid FROM silver_transactions
ON CONFLICT(account_key,source_transaction_id) DO UPDATE SET raw_record_id=EXCLUDED.raw_record_id,
  run_id=EXCLUDED.run_id,loaded_at=clock_timestamp();
