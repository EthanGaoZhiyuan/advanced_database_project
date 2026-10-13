/*
Layer: Vault.
Reads: validated Silver entities and Bronze lineage.
Writes: Vault hubs, ownership links, versioned balance/profile satellites and immutable transaction events.
Order: step 05, in the same transaction as build_silver.sql. Gold runs in step 06.
Context: boa.run_id (UUID); boa.dates (PostgreSQL date array for Gold).
05_build_silver_etl.py supplies the transaction and run context.
*/
-- Fixed ownership and attribute provenance must also hold for manual SQL loads.
DO $vault_guards$
DECLARE offending_key text;
BEGIN
 SELECT a.source_system||'/'||a.source_account_id INTO offending_key
 FROM boa_silver.account a
  JOIN boa_vault.hub_account h USING(source_system,source_account_id)
  JOIN boa_vault.link_customer_account l USING(account_hk)
  JOIN boa_vault.hub_customer c USING(customer_hk)
  WHERE c.enterprise_customer_id<>a.enterprise_customer_id
 LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'ILLEGAL_OWNERSHIP_CHANGE: Unsupported Vault account ownership change [%]', offending_key; END IF;
 SELECT coalesce(attr.value->>'source_system','REGISTRY')||'/'||
  coalesce(attr.value->>'source_customer_id',c.enterprise_customer_id) INTO offending_key
 FROM boa_silver.enterprise_customer c
  CROSS JOIN LATERAL jsonb_each(c.source_provenance) attr
  LEFT JOIN boa_bronze.source_record r ON r.raw_record_id=(attr.value->>'raw_record_id')::bigint
  LEFT JOIN boa_audit.raw_run_record rr ON rr.raw_record_id=r.raw_record_id
   AND rr.run_id=current_setting('boa.run_id')::uuid
  LEFT JOIN boa_silver.customer_crosswalk x ON x.source_system=r.source_system
   AND x.source_customer_id=r.payload->>'customer_id'
  WHERE attr.value<>'null'::jsonb AND (
   r.raw_record_id IS NULL OR rr.run_id IS NULL OR r.entity_name<>'customers'
   OR r.source_system IS DISTINCT FROM attr.value->>'source_system'
   OR r.source_record_key IS DISTINCT FROM attr.value->>'source_customer_id'
   OR r.payload->>'customer_id' IS DISTINCT FROM attr.value->>'source_customer_id'
   OR r.business_date IS NOT NULL
   OR x.enterprise_customer_id IS DISTINCT FROM c.enterprise_customer_id)
 LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'INVALID_RAW_LINEAGE: Invalid selected customer profile provenance [%]', offending_key; END IF;
END $vault_guards$;
-- statement-break
-- Each statement participates in step 05's Silver + Vault transaction.
-- Each verified enterprise identity has exactly one hub business key.
INSERT INTO boa_vault.hub_customer(enterprise_customer_id,record_source,run_id)
SELECT enterprise_customer_id,'VERIFIED_REGISTRY',current_setting('boa.run_id')::uuid
FROM boa_silver.enterprise_customer
ON CONFLICT(enterprise_customer_id) DO NOTHING;
-- statement-break
-- Source-qualified account keys prevent local ID collisions across systems.
INSERT INTO boa_vault.hub_account(source_system,source_account_id,record_source,run_id)
SELECT source_system,source_account_id,source_system,current_setting('boa.run_id')::uuid FROM boa_silver.account
ON CONFLICT(source_system,source_account_id) DO NOTHING;
-- statement-break
-- A fixed single owner is represented by exactly one link per account.
INSERT INTO boa_vault.link_customer_account(customer_hk,account_hk,record_source,run_id)
SELECT c.customer_hk,h.account_hk,a.source_system,current_setting('boa.run_id')::uuid
FROM boa_silver.account a
JOIN boa_vault.hub_customer c USING(enterprise_customer_id)
JOIN boa_vault.hub_account h USING(source_system,source_account_id)
ON CONFLICT(account_hk) DO NOTHING;
-- statement-break
-- Technical raw IDs are retained as evidence, but never make unchanged business content a new version.
WITH candidate AS (
 SELECT h.customer_hk,c.*,
  md5(jsonb_build_array(c.full_name,c.email,c.phone,c.date_of_birth,c.street_address,
    c.state,c.postcode,c.country,
    (SELECT coalesce(jsonb_object_agg(key,jsonb_build_object('source_system',value->>'source_system',
       'source_customer_id',value->>'source_customer_id')),'{}'::jsonb)
     FROM jsonb_each(c.source_provenance)))::text) AS hashdiff
 FROM boa_silver.enterprise_customer c JOIN boa_vault.hub_customer h USING(enterprise_customer_id)
)
-- Append a profile only when the latest accepted canonical content differs.
INSERT INTO boa_vault.sat_customer_profile(customer_hk,full_name,email,phone,date_of_birth,street_address,
 state,postcode,country,hashdiff,record_source,run_id,source_provenance)
SELECT c.customer_hk,c.full_name,c.email,c.phone,c.date_of_birth,c.street_address,c.state,c.postcode,
 c.country,c.hashdiff,'SILVER_PRECEDENCE',current_setting('boa.run_id')::uuid,c.source_provenance
FROM candidate c LEFT JOIN LATERAL (
 SELECT s.hashdiff FROM boa_vault.sat_customer_profile s WHERE s.customer_hk=c.customer_hk
 ORDER BY s.version_id DESC LIMIT 1
) latest ON true
WHERE c.hashdiff IS DISTINCT FROM latest.hashdiff;
-- statement-break
WITH candidate AS (
 SELECT h.account_hk,a.*,
  md5(jsonb_build_array(a.product_code,a.opened_date,a.closed_date,a.currency_code,
    a.credit_limit,a.original_principal)::text) AS hashdiff
 FROM boa_silver.account a JOIN boa_vault.hub_account h USING(source_system,source_account_id)
)
-- Append changed account metadata while retaining earlier accepted versions.
INSERT INTO boa_vault.sat_account_profile(account_hk,product_code,opened_date,closed_date,currency_code,
 credit_limit,original_principal,hashdiff,record_source,run_id,source_provenance)
SELECT c.account_hk,c.product_code,c.opened_date,c.closed_date,c.currency_code,c.credit_limit,
 c.original_principal,c.hashdiff,c.source_system,current_setting('boa.run_id')::uuid,
 jsonb_build_object('raw_record_id',c.raw_record_id,'source_system',c.source_system,
  'source_account_id',c.source_account_id)
FROM candidate c LEFT JOIN LATERAL (
 SELECT s.hashdiff FROM boa_vault.sat_account_profile s WHERE s.account_hk=c.account_hk
 ORDER BY s.version_id DESC LIMIT 1
) latest ON true
WHERE c.hashdiff IS DISTINCT FROM latest.hashdiff;
-- statement-break
-- Compare only the latest observation for the same account/date: A -> B -> A keeps three versions.
WITH candidate AS (
 SELECT h.account_hk,a.source_system,b.*,
  md5(jsonb_build_array(b.balance_date,b.account_status,b.savings_balance,b.card_outstanding,
    b.loan_principal_outstanding)::text) AS hashdiff
 FROM boa_silver.account_daily_balance b
 JOIN boa_silver.account a USING(account_key)
 JOIN boa_vault.hub_account h USING(source_system,source_account_id)
 WHERE b.run_id=current_setting('boa.run_id')::uuid
)
-- Each business date is an observation; corrections append versions at that grain.
INSERT INTO boa_vault.sat_account_daily_balance(account_hk,balance_date,account_status,savings_balance,
 card_outstanding,loan_principal_outstanding,hashdiff,raw_record_id,record_source,run_id)
SELECT c.account_hk,c.balance_date,c.account_status,c.savings_balance,c.card_outstanding,
 c.loan_principal_outstanding,c.hashdiff,c.raw_record_id,c.source_system,current_setting('boa.run_id')::uuid
FROM candidate c LEFT JOIN LATERAL (
 SELECT s.hashdiff FROM boa_vault.sat_account_daily_balance s
 WHERE s.account_hk=c.account_hk AND s.balance_date=c.balance_date
 ORDER BY s.version_id DESC LIMIT 1
) latest ON true
WHERE c.hashdiff IS DISTINCT FROM latest.hashdiff;

-- statement-break
-- Accepted events have one immutable Vault identity; unchanged reruns append no event copies.
INSERT INTO boa_vault.sat_account_transaction(account_hk,source_transaction_id,transaction_date,
  transaction_type,signed_amount,counterparty,category_code,raw_record_id,record_source,run_id)
SELECT h.account_hk,t.source_transaction_id,t.transaction_date,t.transaction_type,t.signed_amount,
  t.counterparty,t.category_code,t.raw_record_id,a.source_system,current_setting('boa.run_id')::uuid
FROM boa_silver.account_transaction t JOIN boa_silver.account a USING(account_key)
JOIN boa_vault.hub_account h USING(source_system,source_account_id)
WHERE t.run_id=current_setting('boa.run_id')::uuid
ON CONFLICT(account_hk,source_transaction_id) DO NOTHING;
