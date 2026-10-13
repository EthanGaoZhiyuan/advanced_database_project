/*
Layer: Gold / Audit.
Reads: Vault hubs, ownership links, latest satellites and batch manifest.
Writes: Gold Type 1 dimensions, daily balance facts, additive transaction facts and common-date publication.
Order: step 06 after the completed Silver/Vault step; commit together with run success.
Context: boa.run_id (UUID); boa.dates (PostgreSQL date array for Gold).
06_build_gold_etl.py supplies the transaction and run context.
*/
-- A common publication date requires the complete verified three-source batch.
DO $publication_manifest$
DECLARE m jsonb; requested date[] := current_setting('boa.dates')::date[]; offending_key text;
BEGIN
 IF cardinality(requested)=0 OR cardinality(requested)<>(SELECT count(DISTINCT d) FROM unnest(requested) d)
 THEN RAISE EXCEPTION 'INVALID_MANIFEST: Publication requires a nonempty list of distinct business dates [ALL/%]', current_setting('boa.run_id'); END IF;
 SELECT bm.manifest INTO m FROM boa_audit.pipeline_run r
 JOIN boa_audit.batch_manifest bm USING(batch_id)
 WHERE r.run_id=current_setting('boa.run_id')::uuid;
 IF m IS NULL OR (SELECT array_agg(DISTINCT s ORDER BY s) FROM jsonb_array_elements_text(m->'sources') s)
   IS DISTINCT FROM ARRAY['CARDS','LOANS','SAVINGS']::text[]
 THEN
  SELECT s||'/'||current_setting('boa.run_id') INTO offending_key
  FROM unnest(ARRAY['SAVINGS','CARDS','LOANS']) s
  WHERE NOT coalesce(m->'sources','[]'::jsonb) ? s LIMIT 1;
  RAISE EXCEPTION 'MISSING_SOURCE_BATCH: Publication requires every source in the verified batch manifest [%]',
    coalesce(offending_key,'ALL/'||current_setting('boa.run_id'));
 END IF;
 IF (SELECT array_agg(d ORDER BY d) FROM unnest(requested) d)
   IS DISTINCT FROM (SELECT array_agg(DISTINCT d::date ORDER BY d::date) FROM jsonb_array_elements_text(m->'dates') d)
 THEN RAISE EXCEPTION 'INVALID_MANIFEST: Publication dates must equal the validated manifest dates [ALL/%]', current_setting('boa.run_id'); END IF;
END $publication_manifest$;
-- statement-break
-- Gold reads business data exclusively through Vault hubs, links and accepted satellite versions.
WITH latest AS (
 SELECT DISTINCT ON(customer_hk) * FROM boa_vault.sat_customer_profile ORDER BY customer_hk,version_id DESC
)
-- SCD Type 1 profiles expose the current accepted Vault descriptions.
INSERT INTO boa_gold.dim_customer(enterprise_customer_id,full_name,email,phone,date_of_birth,
 street_address,state,postcode,country)
SELECT h.enterprise_customer_id,s.full_name,s.email,s.phone,s.date_of_birth,s.street_address,
 s.state,s.postcode,s.country FROM boa_vault.hub_customer h JOIN latest s USING(customer_hk)
ON CONFLICT(enterprise_customer_id) DO UPDATE SET
 full_name=EXCLUDED.full_name,email=EXCLUDED.email,phone=EXCLUDED.phone,date_of_birth=EXCLUDED.date_of_birth,
 street_address=EXCLUDED.street_address,state=EXCLUDED.state,postcode=EXCLUDED.postcode,country=EXCLUDED.country,
 updated_at=clock_timestamp()
WHERE (dim_customer.full_name,dim_customer.email,dim_customer.phone,dim_customer.date_of_birth,
 dim_customer.street_address,dim_customer.state,dim_customer.postcode,dim_customer.country)
 IS DISTINCT FROM (EXCLUDED.full_name,EXCLUDED.email,EXCLUDED.phone,EXCLUDED.date_of_birth,
 EXCLUDED.street_address,EXCLUDED.state,EXCLUDED.postcode,EXCLUDED.country);
-- statement-break
WITH latest AS (
 SELECT DISTINCT ON(account_hk) * FROM boa_vault.sat_account_profile ORDER BY account_hk,version_id DESC
)
-- Each account dimension follows its fixed Vault owner and product.
INSERT INTO boa_gold.dim_account(source_system,source_account_id,customer_sk,product_sk,opened_date,closed_date,currency_code)
SELECT h.source_system,h.source_account_id,c.customer_sk,p.product_sk,s.opened_date,s.closed_date,s.currency_code
FROM boa_vault.hub_account h JOIN latest s USING(account_hk)
JOIN boa_vault.link_customer_account l USING(account_hk)
JOIN boa_vault.hub_customer ch USING(customer_hk)
JOIN boa_gold.dim_customer c USING(enterprise_customer_id)
JOIN boa_gold.dim_product p USING(product_code)
ON CONFLICT(source_system,source_account_id) DO UPDATE SET
 customer_sk=EXCLUDED.customer_sk,product_sk=EXCLUDED.product_sk,opened_date=EXCLUDED.opened_date,
 closed_date=EXCLUDED.closed_date,currency_code=EXCLUDED.currency_code;
-- statement-break
-- Business dates remain separate from ingestion and publication timestamps.
INSERT INTO boa_gold.dim_date(date_sk,full_date,day_of_month,month_number,month_name,
 quarter_number,year_number,day_of_week,is_weekend)
SELECT extract(year FROM d)::integer*10000+extract(month FROM d)::integer*100+extract(day FROM d)::integer,
 d,extract(day FROM d)::integer,extract(month FROM d)::integer,to_char(d,'FMMonth'),
 extract(quarter FROM d)::integer,extract(year FROM d)::integer,extract(isodow FROM d)::integer,
 extract(isodow FROM d)>=6
FROM unnest(current_setting('boa.dates')::date[]) AS dates(d)
ON CONFLICT(full_date) DO NOTHING;
-- statement-break
WITH latest_balance AS (
 SELECT DISTINCT ON(account_hk,balance_date) * FROM boa_vault.sat_account_daily_balance
 WHERE balance_date=ANY(current_setting('boa.dates')::date[]) ORDER BY account_hk,balance_date,version_id DESC
), latest_profile AS (
 SELECT DISTINCT ON(account_hk) * FROM boa_vault.sat_account_profile ORDER BY account_hk,version_id DESC
)
-- Upsert the account/date grain and refresh every republished fact's run ID.
INSERT INTO boa_gold.fact_account_daily_snapshot(date_sk,customer_sk,account_sk,product_sk,
 account_status,savings_balance,card_outstanding,loan_principal_outstanding,credit_limit_amount,
 vault_balance_version_id,load_run_id)
SELECT d.date_sk,a.customer_sk,a.account_sk,a.product_sk,b.account_status,b.savings_balance,
 b.card_outstanding,b.loan_principal_outstanding,coalesce(s.credit_limit,0),b.version_id,current_setting('boa.run_id')::uuid
FROM latest_balance b JOIN boa_vault.hub_account h USING(account_hk)
JOIN latest_profile s USING(account_hk)
JOIN boa_vault.link_customer_account l USING(account_hk)
JOIN boa_vault.hub_customer c USING(customer_hk)
JOIN boa_gold.dim_customer dc USING(enterprise_customer_id)
JOIN boa_gold.dim_account a ON a.source_system=h.source_system AND a.source_account_id=h.source_account_id
 AND a.customer_sk=dc.customer_sk
JOIN boa_gold.dim_date d ON d.full_date=b.balance_date
ON CONFLICT(account_sk,date_sk) DO UPDATE SET
 customer_sk=EXCLUDED.customer_sk,product_sk=EXCLUDED.product_sk,account_status=EXCLUDED.account_status,
 savings_balance=EXCLUDED.savings_balance,card_outstanding=EXCLUDED.card_outstanding,
 loan_principal_outstanding=EXCLUDED.loan_principal_outstanding,credit_limit_amount=EXCLUDED.credit_limit_amount,
 vault_balance_version_id=EXCLUDED.vault_balance_version_id,load_run_id=EXCLUDED.load_run_id,loaded_at=clock_timestamp();

-- statement-break
-- Gold events come only from Vault hubs, fixed ownership links and accepted event satellites.
INSERT INTO boa_gold.fact_transaction(source_transaction_id,date_sk,customer_sk,account_sk,product_sk,
  transaction_type_sk,signed_amount,counterparty,category_code,vault_transaction_id,load_run_id)
SELECT t.source_transaction_id,d.date_sk,c.customer_sk,a.account_sk,a.product_sk,tt.transaction_type_sk,
  t.signed_amount,t.counterparty,t.category_code,t.transaction_id,current_setting('boa.run_id')::uuid
FROM boa_vault.sat_account_transaction t JOIN boa_vault.hub_account h USING(account_hk)
JOIN boa_vault.link_customer_account l USING(account_hk)
JOIN boa_vault.hub_customer hc USING(customer_hk)
JOIN boa_gold.dim_customer c USING(enterprise_customer_id)
JOIN boa_gold.dim_account a ON a.source_system=h.source_system AND a.source_account_id=h.source_account_id
  AND a.customer_sk=c.customer_sk
JOIN boa_gold.dim_date d ON d.full_date=t.transaction_date
JOIN boa_gold.dim_transaction_type tt ON tt.transaction_type_code=t.transaction_type
WHERE t.transaction_date=ANY(current_setting('boa.dates')::date[])
ON CONFLICT(account_sk,source_transaction_id) DO UPDATE SET
  date_sk=EXCLUDED.date_sk,customer_sk=EXCLUDED.customer_sk,product_sk=EXCLUDED.product_sk,
  transaction_type_sk=EXCLUDED.transaction_type_sk,signed_amount=EXCLUDED.signed_amount,
  counterparty=EXCLUDED.counterparty,category_code=EXCLUDED.category_code,
  vault_transaction_id=EXCLUDED.vault_transaction_id,load_run_id=EXCLUDED.load_run_id,loaded_at=clock_timestamp();
-- statement-break
-- Refresh statistics for the first dashboard query against a newly loaded database.
ANALYZE boa_gold.dim_customer;
ANALYZE boa_gold.dim_account;
ANALYZE boa_gold.dim_product;
ANALYZE boa_gold.dim_date;
ANALYZE boa_gold.fact_account_daily_snapshot;
ANALYZE boa_gold.fact_transaction;
ANALYZE boa_gold.dim_transaction_type;
-- statement-break
-- Missing observations and mixed publication metadata must abort the whole load.
DO $publication_coverage$
DECLARE offending_date date;
BEGIN
 SELECT d.full_date INTO offending_date FROM boa_gold.dim_date d
  LEFT JOIN boa_gold.fact_account_daily_snapshot f USING(date_sk)
  WHERE d.full_date=ANY(current_setting('boa.dates')::date[])
  GROUP BY d.full_date
  HAVING count(f.snapshot_sk)<>(SELECT count(*) FROM boa_gold.dim_account a WHERE a.opened_date<=d.full_date)
    OR count(f.snapshot_sk)<>count(f.snapshot_sk) FILTER(WHERE f.load_run_id=current_setting('boa.run_id')::uuid)
 LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'MISSING_ACCOUNT_DATE: Publication coverage or metadata mismatch [ALL/%]', offending_date; END IF;
END $publication_coverage$;
-- statement-break
-- Event publication covers every accepted Vault event and refreshes unchanged events on republished dates.
DO $transaction_publication$
DECLARE offending text;
BEGIN
  offending := (SELECT h.source_system||'/'||t.source_transaction_id
    FROM boa_vault.sat_account_transaction t JOIN boa_vault.hub_account h USING(account_hk)
    LEFT JOIN boa_gold.fact_transaction f ON f.vault_transaction_id=t.transaction_id
    WHERE t.transaction_date=ANY(current_setting('boa.dates')::date[])
      AND (f.transaction_sk IS NULL OR f.load_run_id<>current_setting('boa.run_id')::uuid)
    ORDER BY t.transaction_id LIMIT 1);
  IF offending IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_TRANSACTION_PUBLICATION: accepted event is absent or has mixed publication metadata [%]',offending;
  END IF;
END $transaction_publication$;
-- statement-break
-- The caller commits these common-date markers together with all accepted layers.
INSERT INTO boa_audit.published_day(business_date,published_run_id,expected_account_count,actual_account_count)
SELECT d.full_date,current_setting('boa.run_id')::uuid,
 (SELECT count(*) FROM boa_gold.dim_account a WHERE a.opened_date<=d.full_date),count(f.snapshot_sk)
FROM boa_gold.dim_date d LEFT JOIN boa_gold.fact_account_daily_snapshot f USING(date_sk)
WHERE d.full_date=ANY(current_setting('boa.dates')::date[])
GROUP BY d.full_date
ON CONFLICT(business_date) DO UPDATE SET published_run_id=EXCLUDED.published_run_id,
 published_at=clock_timestamp(),expected_account_count=EXCLUDED.expected_account_count,
 actual_account_count=EXCLUDED.actual_account_count;
