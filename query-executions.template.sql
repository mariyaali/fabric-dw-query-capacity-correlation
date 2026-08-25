WITH qi AS
(
    SELECT
        distributed_statement_id,
        CAST('{{WAREHOUSE_ITEM_ID}}' AS varchar(36)) AS warehouse_item_id,
        CAST('{{WAREHOUSE_NAME}}' AS varchar(128)) AS warehouse_name,
        database_name,
        submit_time,
        start_time,
        end_time,
        statement_type,
        total_elapsed_time_ms,
        allocated_cpu_time_ms,
        login_name,
        row_count,
        status,
        program_name,
        query_hash,
        label,
        result_cache_hit,
        sql_pool_name,
        error_code,
        error_severity,
        error_state,
        data_scanned_remote_storage_mb,
        data_scanned_memory_mb,
        data_scanned_disk_mb,
        command
    FROM queryinsights.exec_requests_history
    WHERE start_time >= DATEADD(day, -30, SYSUTCDATETIME())
),
normalized AS
(
    SELECT
        *,
        CAST(
            UPPER(REPLACE(REPLACE(CONVERT(varchar(36), distributed_statement_id), '{', ''), '}', ''))
            AS varchar(36)
        ) AS normalized_operation_id,
        COALESCE(end_time, SYSUTCDATETIME()) AS effective_end_time
    FROM qi
),
localized AS
(
    SELECT
        n.*,
        DATEADD(
            hour,
            CASE
                WHEN n.start_time >= start_dst.dst_start_utc
                    AND n.start_time < start_dst.dst_end_utc THEN {{DAYLIGHT_UTC_OFFSET}}
                ELSE {{STANDARD_UTC_OFFSET}}
            END,
            n.start_time
        ) AS local_start_time,
        DATEADD(
            hour,
            CASE
                WHEN n.effective_end_time >= end_dst.dst_start_utc
                    AND n.effective_end_time < end_dst.dst_end_utc THEN {{DAYLIGHT_UTC_OFFSET}}
                ELSE {{STANDARD_UTC_OFFSET}}
            END,
            n.effective_end_time
        ) AS local_end_time
    FROM normalized AS n
    CROSS APPLY
    (
        SELECT
            DATEADD(
                hour,
                10,
                CAST(
                    DATEADD(
                        day,
                        (7 - (DATEDIFF(day, '19000107', DATEFROMPARTS(YEAR(n.start_time), 3, 8)) % 7)) % 7,
                        DATEFROMPARTS(YEAR(n.start_time), 3, 8)
                    ) AS datetime2
                )
            ) AS dst_start_utc,
            DATEADD(
                hour,
                9,
                CAST(
                    DATEADD(
                        day,
                        (7 - (DATEDIFF(day, '19000107', DATEFROMPARTS(YEAR(n.start_time), 11, 1)) % 7)) % 7,
                        DATEFROMPARTS(YEAR(n.start_time), 11, 1)
                    ) AS datetime2
                )
            ) AS dst_end_utc
    ) AS start_dst
    CROSS APPLY
    (
        SELECT
            DATEADD(
                hour,
                10,
                CAST(
                    DATEADD(
                        day,
                        (7 - (DATEDIFF(day, '19000107', DATEFROMPARTS(YEAR(n.effective_end_time), 3, 8)) % 7)) % 7,
                        DATEFROMPARTS(YEAR(n.effective_end_time), 3, 8)
                    ) AS datetime2
                )
            ) AS dst_start_utc,
            DATEADD(
                hour,
                9,
                CAST(
                    DATEADD(
                        day,
                        (7 - (DATEDIFF(day, '19000107', DATEFROMPARTS(YEAR(n.effective_end_time), 11, 1)) % 7)) % 7,
                        DATEFROMPARTS(YEAR(n.effective_end_time), 11, 1)
                    ) AS datetime2
                )
            ) AS dst_end_utc
    ) AS end_dst
),
interval_numbers AS
(
    SELECT ones.n + (10 * tens.n) + (100 * hundreds.n) AS hour_number
    FROM
        (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS ones(n)
    CROSS JOIN
        (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS tens(n)
    CROSS JOIN
        (VALUES (0), (1), (2), (3), (4), (5), (6), (7)) AS hundreds(n)
)
SELECT
    CAST(l.warehouse_item_id + ':' + l.normalized_operation_id AS varchar(73)) AS execution_key,
    l.normalized_operation_id,
    l.warehouse_item_id,
    l.warehouse_name,
    CAST(l.database_name AS varchar(128)) AS database_name,
    l.submit_time,
    l.start_time,
    l.end_time,
    CAST(
        DATEADD(
            second,
            (DATEDIFF(second, CONVERT(datetime2, '2000-01-01'), l.local_start_time) / 30) * 30,
            CONVERT(datetime2, '2000-01-01')
        ) AS datetime2(6)
    ) AS query_timepoint,
    DATEADD(hour, i.hour_number, DATEADD(hour, DATEDIFF(hour, 0, l.local_start_time), 0)) AS query_hour,
    CAST(
        DATEADD(hour, i.hour_number, DATEADD(hour, DATEDIFF(hour, 0, l.local_start_time), 0))
        AS date
    ) AS query_date,
    CAST(l.statement_type AS varchar(128)) AS statement_type,
    CAST(l.total_elapsed_time_ms AS bigint) AS total_elapsed_time_ms,
    CAST(l.allocated_cpu_time_ms AS bigint) AS allocated_cpu_time_ms,
    CAST(l.login_name AS varchar(256)) AS login_name,
    CAST(l.row_count AS bigint) AS row_count,
    CAST(l.status AS varchar(128)) AS status,
    CAST(l.program_name AS varchar(256)) AS program_name,
    CONVERT(varchar(128), l.query_hash, 1) AS query_hash,
    CAST(l.label AS varchar(256)) AS label,
    CAST(l.result_cache_hit AS bigint) AS result_cache_hit,
    CAST(l.sql_pool_name AS varchar(128)) AS sql_pool_name,
    CAST(l.error_code AS bigint) AS error_code,
    CAST(l.error_severity AS bigint) AS error_severity,
    CAST(l.error_state AS bigint) AS error_state,
    CAST(l.data_scanned_remote_storage_mb AS decimal(19, 4)) AS data_scanned_remote_storage_mb,
    CAST(l.data_scanned_memory_mb AS decimal(19, 4)) AS data_scanned_memory_mb,
    CAST(l.data_scanned_disk_mb AS decimal(19, 4)) AS data_scanned_disk_mb,
    CAST(LEFT(l.command, 4000) AS varchar(4000)) AS command
FROM localized AS l
CROSS JOIN interval_numbers AS i
WHERE i.hour_number <=
    CASE
        WHEN DATEDIFF(
            hour,
            DATEADD(hour, DATEDIFF(hour, 0, l.local_start_time), 0),
            l.local_end_time
        ) < 0 THEN 0
        ELSE DATEDIFF(
            hour,
            DATEADD(hour, DATEDIFF(hour, 0, l.local_start_time), 0),
            l.local_end_time
        )
    END;
