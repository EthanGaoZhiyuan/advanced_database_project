SELECT set_config('boa.source_user', session_user, false);
SET boa.source_password = 'student';


-- 新建本次运行编号
SELECT set_config('boa.run_id', gen_random_uuid()::text, false);

-- 从刚导入的批次信息中取得处理日期
SELECT set_config(
    'boa.dates',
    (
        SELECT array_agg(d.value::date ORDER BY d.value::date)::text
        FROM boa_audit.batch_manifest b
        CROSS JOIN LATERAL
            jsonb_array_elements_text(b.manifest->'dates') AS d(value)
        WHERE b.batch_id = current_setting('boa.batch_id')
    ),
    false
);

-- 修正样例文件目录记录
UPDATE boa_audit.batch_manifest
SET input_directory = '/workspace/data'
WHERE batch_id = current_setting('boa.batch_id');

-- 记录本次 ETL 开始
INSERT INTO boa_audit.pipeline_run
    (run_id, batch_id, status, current_stage)
VALUES (
    current_setting('boa.run_id')::uuid,
    current_setting('boa.batch_id'),
    'RUNNING',
    'ingest-bronze'
);






BEGIN;
SELECT pg_advisory_xact_lock(32113001);