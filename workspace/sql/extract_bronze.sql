/*
Layer: Source / Bronze / Audit.
Reads: three complete source inventories, declared daily dates and identity registry.
Writes: durable source_file reconciliation, Bronze payloads and current-run membership.
Order: 04_load_bronze.py after source preparation; commit before step 05.
Context: boa.run_id (UUID), boa.dates (PostgreSQL date array).
The Python step restores run context from the audit tables and records failures.
*/
-- Match the Python source extract's UTC representation of typed source values.
SET LOCAL timezone='UTC';
-- One staged row per source-qualified entity business key preserves provenance.
CREATE TEMP TABLE manual_raw_stage ON COMMIT DROP AS
WITH source_rows AS (
 SELECT 'SAVINGS'::text AS source_system,'customers'::text AS entity_name,to_jsonb(t) AS payload FROM boa_src_savings.customers t
 UNION ALL SELECT 'SAVINGS','accounts',to_jsonb(t) FROM boa_src_savings.accounts t
 UNION ALL SELECT 'SAVINGS','daily_balances',to_jsonb(t) FROM boa_src_savings.daily_balances t WHERE balance_date=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'SAVINGS','transactions',to_jsonb(t) FROM boa_src_savings.transactions t WHERE boa_audit.transaction_date('SAVINGS',to_jsonb(t))=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'CARDS','customers',to_jsonb(t) FROM boa_src_cards.customers t
 UNION ALL SELECT 'CARDS','accounts',to_jsonb(t) FROM boa_src_cards.accounts t
 UNION ALL SELECT 'CARDS','daily_balances',to_jsonb(t) FROM boa_src_cards.daily_balances t WHERE balance_date=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'CARDS','transactions',to_jsonb(t) FROM boa_src_cards.transactions t WHERE boa_audit.transaction_date('CARDS',to_jsonb(t))=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'LOANS','customers',to_jsonb(t) FROM boa_src_loans.customers t
 UNION ALL SELECT 'LOANS','accounts',to_jsonb(t) FROM boa_src_loans.accounts t
 UNION ALL SELECT 'LOANS','daily_balances',to_jsonb(t) FROM boa_src_loans.daily_balances t WHERE balance_date=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'LOANS','transactions',to_jsonb(t) FROM boa_src_loans.transactions t WHERE boa_audit.transaction_date('LOANS',to_jsonb(t))=ANY(current_setting('boa.dates')::date[])
 UNION ALL SELECT 'REGISTRY','crosswalk',jsonb_build_object(
   'source_system',source_system,'source_customer_id',source_customer_id,
   'enterprise_customer_id',enterprise_customer_id,'mapping_method',mapping_method,
   'verification_status',verification_status) FROM boa_audit.identity_registry
), normalised AS (
 SELECT s.source_system,s.entity_name,
  (SELECT jsonb_object_agg(k,CASE WHEN k IN ('source_updated_at','txn_timestamp') THEN
    to_char(v::timestamptz,'YYYY-MM-DD HH24:MI:SS') ||
    CASE WHEN extract(microseconds FROM v::timestamptz)::bigint % 1000000<>0
      THEN '.'||to_char(v::timestamptz,'US') ELSE '' END || '+00:00'
    ELSE v END)
   FROM jsonb_each_text(s.payload) attrs(k,v)) AS payload
 FROM source_rows s
), keyed AS (
 SELECT n.*,CASE entity_name WHEN 'customers' THEN payload->>'customer_id'
   WHEN 'accounts' THEN payload->>'account_id'
   WHEN 'transactions' THEN boa_audit.transaction_key(source_system,payload)
   WHEN 'crosswalk' THEN (payload->>'source_system')||'|'||(payload->>'source_customer_id')
   ELSE (payload->>'account_id')||'|'||(payload->>'balance_date') END AS source_record_key,
  CASE WHEN entity_name='daily_balances' THEN (payload->>'balance_date')::date
    WHEN entity_name='transactions' THEN boa_audit.transaction_date(source_system,payload) END AS business_date
 FROM normalised n
)
SELECT k.*,encode(sha256(convert_to(
 (SELECT '{'||string_agg(to_jsonb(key)::text||':'||value::text,',' ORDER BY key COLLATE "C")||'}'
  FROM jsonb_each(k.payload)), 'UTF8')), 'hex') AS payload_hash
FROM keyed k;

-- The generated manifest, including empty source files, defines required coverage.
DO $extract_coverage$
DECLARE m jsonb; offending_key text;
BEGIN
 SELECT b.manifest INTO m FROM boa_audit.pipeline_run r
 JOIN boa_audit.batch_manifest b USING(batch_id)
 WHERE r.run_id=current_setting('boa.run_id')::uuid;
 IF m IS NULL OR (SELECT array_agg(DISTINCT s ORDER BY s) FROM jsonb_array_elements_text(m->'sources') s)
   IS DISTINCT FROM ARRAY['CARDS','LOANS','SAVINGS']::text[]
 THEN
  SELECT s||'/'||current_setting('boa.run_id') INTO offending_key
  FROM unnest(ARRAY['SAVINGS','CARDS','LOANS']) s
  WHERE NOT coalesce(m->'sources','[]'::jsonb) ? s LIMIT 1;
  RAISE EXCEPTION 'MISSING_SOURCE_BATCH: The manual load requires all three source batches [%]',
    coalesce(offending_key,'ALL/'||current_setting('boa.run_id'));
 END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(m->'files'))<>13 OR EXISTS (
  SELECT 1 FROM (VALUES ('SAVINGS','customers'),('SAVINGS','accounts'),('SAVINGS','daily_balances'),('SAVINGS','transactions'),
    ('CARDS','customers'),('CARDS','accounts'),('CARDS','daily_balances'),('CARDS','transactions'),
    ('LOANS','customers'),('LOANS','accounts'),('LOANS','daily_balances'),('LOANS','transactions'),('REGISTRY','crosswalk')) expected(source_system,entity_name)
  WHERE (SELECT count(*) FROM jsonb_array_elements(m->'files') f
    WHERE f->>'source_system'=expected.source_system AND f->>'entity_name'=expected.entity_name)<>1
 ) THEN
  SELECT source_system||'/'||entity_name INTO offending_key
  FROM (VALUES ('SAVINGS','customers'),('SAVINGS','accounts'),('SAVINGS','daily_balances'),('SAVINGS','transactions'),
    ('CARDS','customers'),('CARDS','accounts'),('CARDS','daily_balances'),('CARDS','transactions'),
    ('LOANS','customers'),('LOANS','accounts'),('LOANS','daily_balances'),('LOANS','transactions'),('REGISTRY','crosswalk')) expected(source_system,entity_name)
  WHERE (SELECT count(*) FROM jsonb_array_elements(m->'files') f
    WHERE f->>'source_system'=expected.source_system AND f->>'entity_name'=expected.entity_name)<>1 LIMIT 1;
  RAISE EXCEPTION 'INVALID_MANIFEST: The manual load requires exactly one manifest file per source/entity [%]',
    coalesce(offending_key,'ALL/'||current_setting('boa.run_id'));
 END IF;
 SELECT (f->>'source_system')||'/'||(f->>'path') INTO offending_key
 FROM jsonb_array_elements(m->'files') f
 WHERE (f->>'row_count')::bigint<>(SELECT count(*) FROM manual_raw_stage s
    WHERE s.source_system=f->>'source_system' AND s.entity_name=f->>'entity_name')
 LIMIT 1;
 IF FOUND THEN RAISE EXCEPTION 'ROW_COUNT_MISMATCH: Source extract row counts differ from the generated batch manifest [%]', offending_key; END IF;
END $extract_coverage$;

-- File counts and original JSONL checksums describe the clean generator input.
INSERT INTO boa_audit.source_file(run_id,path,source_system,entity_name,expected_count,
 input_count,accepted_count,deduplicated_count,rejected_count,sha256)
SELECT r.run_id,f->>'path',f->>'source_system',f->>'entity_name',(f->>'row_count')::bigint,
 (f->>'row_count')::bigint,(f->>'row_count')::bigint,0,0,f->>'sha256'
FROM boa_audit.pipeline_run r JOIN boa_audit.batch_manifest b USING(batch_id)
CROSS JOIN LATERAL jsonb_array_elements(b.manifest->'files') f
WHERE r.run_id=current_setting('boa.run_id')::uuid
ON CONFLICT(run_id,path) DO NOTHING;

-- Retrying the same batch/content reuses its raw row and adds only run membership.
INSERT INTO boa_bronze.source_record(run_id,batch_id,source_system,entity_name,
 source_record_key,business_date,payload,payload_hash)
SELECT r.run_id,r.batch_id,s.source_system,s.entity_name,s.source_record_key,
 s.business_date,s.payload,s.payload_hash
FROM manual_raw_stage s CROSS JOIN boa_audit.pipeline_run r
WHERE r.run_id=current_setting('boa.run_id')::uuid
ON CONFLICT(batch_id,source_system,entity_name,source_record_key,payload_hash) DO NOTHING;

-- Membership proves that a reused raw record was actually extracted by this run.
INSERT INTO boa_audit.raw_run_record(run_id,raw_record_id)
SELECT current_setting('boa.run_id')::uuid,b.raw_record_id
FROM manual_raw_stage s JOIN boa_bronze.source_record b
 USING(source_system,entity_name,source_record_key,payload_hash)
JOIN boa_audit.pipeline_run r ON r.batch_id=b.batch_id
WHERE r.run_id=current_setting('boa.run_id')::uuid
ON CONFLICT DO NOTHING;
