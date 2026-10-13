/*
Layer: Audit success finalisation for 06_build_gold_etl.py.
Reads: current run, manifest dates, source_file counts and validated publication markers.
Writes: SUCCEEDED pipeline_run metadata inside the caller's downstream transaction.
Order: immediately after build_gold.sql; the Python context manager commits the step.
Context: boa.run_id and boa.dates restored from Audit; step 06's transaction is open.
This file intentionally contains neither COMMIT nor transformation logic.
*/

-- Every requested date must have been published by this same still-running transaction.
DO $finish_guards$
DECLARE missing_date date;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM boa_audit.pipeline_run
      WHERE run_id=current_setting('boa.run_id')::uuid AND status='RUNNING') THEN
    RAISE EXCEPTION 'INVALID_RUN_STATE: success requires the current RUNNING audit row [ALL/%]',current_setting('boa.run_id');
  END IF;
  SELECT requested.business_date INTO missing_date
    FROM unnest(current_setting('boa.dates')::date[]) requested(business_date)
    LEFT JOIN boa_audit.published_day p USING(business_date)
    WHERE p.published_run_id IS DISTINCT FROM current_setting('boa.run_id')::uuid
    ORDER BY requested.business_date LIMIT 1;
  IF cardinality(current_setting('boa.dates')::date[])=0 OR missing_date IS NOT NULL THEN
    RAISE EXCEPTION 'INCOMPLETE_PUBLICATION: execute all shared downstream stages before finishing [ALL/%]',
      coalesce(missing_date::text,current_setting('boa.run_id'));
  END IF;
END $finish_guards$;

-- Count accepted input once after all requested dates have been published.
UPDATE boa_audit.pipeline_run SET status='SUCCEEDED',finished_at=clock_timestamp(),current_stage='build-gold',
  records_read=(SELECT coalesce(sum(input_count),0) FROM boa_audit.source_file
    WHERE run_id=current_setting('boa.run_id')::uuid),
  records_written=boa_audit.count_written(current_setting('boa.run_id')::uuid),
  records_rejected=(SELECT coalesce(sum(rejected_count),0) FROM boa_audit.source_file
    WHERE run_id=current_setting('boa.run_id')::uuid),
  execution_metadata=execution_metadata||jsonb_build_object('elapsed_seconds',extract(epoch FROM clock_timestamp()-started_at))
WHERE run_id=current_setting('boa.run_id')::uuid;
