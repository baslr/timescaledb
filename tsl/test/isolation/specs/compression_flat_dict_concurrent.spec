# This file and its contents are licensed under the Timescale License.
# Please see the included NOTICE for copyright information and
# LICENSE-TIMESCALE for a copy of the license.

###
# Battle-test scenario 4: Concurrent reads during compression/decompression
# of flat_dictionary chunks.
#
# Verifies:
# - No deadlock between compress and SELECT
# - No crash when reading flat_dict data mid-compression
# - Correct results from concurrent readers
# - Recompression + SELECT concurrency
###

setup {
    CREATE TABLE fd_concurrent(
        time timestamptz NOT NULL,
        device text NOT NULL,
        tags text,
        value float NOT NULL
    );

    SELECT create_hypertable('fd_concurrent', 'time',
        chunk_time_interval => INTERVAL '1 hour');

    ALTER TABLE fd_concurrent SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'device',
        timescaledb.compress_orderby = 'time',
        timescaledb.compress_algorithm = 'tags flat_dictionary'
    );

    -- Insert 5 devices x 1500 rows = 7500 rows (> batch size per segment)
    -- Varied tag cardinality per device to stress dictionary handling
    INSERT INTO fd_concurrent
    SELECT
        '2025-06-01'::timestamptz + (g || ' seconds')::interval,
        'dev-' || (g % 5),
        CASE WHEN g % 100 = 0 THEN NULL
             ELSE '["job=test","device=dev-' || (g % 5) || '",' ||
                  '"process=' || (CASE g % 12
                      WHEN 0 THEN 'nginx' WHEN 1 THEN 'postgres' WHEN 2 THEN 'redis'
                      WHEN 3 THEN 'node' WHEN 4 THEN 'python' WHEN 5 THEN 'java'
                      WHEN 6 THEN 'go-svc' WHEN 7 THEN 'rust-d' WHEN 8 THEN 'ruby-w'
                      WHEN 9 THEN 'php-fpm' WHEN 10 THEN 'dotnet' ELSE 'elixir'
                  END) || '",' ||
                  '"pad=' || repeat('x', 80 + (g % 300)) || '"]'
        END,
        g * 0.01
    FROM generate_series(1, 7500) g;
}

teardown {
    DROP TABLE fd_concurrent CASCADE;
}

# Session for compression operations
session "compressor"
step "compress_all" {
    SELECT count(compress_chunk(ch)) AS compressed
    FROM show_chunks('fd_concurrent') ch;
}
step "decompress_all" {
    SELECT count(decompress_chunk(ch)) AS decompressed
    FROM show_chunks('fd_concurrent') ch;
}
step "recompress_all" {
    SELECT count(compress_chunk(ch, if_not_compressed => true)) AS recompressed
    FROM show_chunks('fd_concurrent') ch;
}
step "compress_begin" { BEGIN; }
step "compress_do" {
    SELECT count(compress_chunk(ch)) AS compressed
    FROM show_chunks('fd_concurrent') ch;
}
step "compress_commit" { COMMIT; }
step "compress_rollback" { ROLLBACK; }

# Session for read operations (must see consistent data, never crash)
session "reader"
step "read_count" {
    SELECT count(*) AS total FROM fd_concurrent;
}
step "read_count_tags" {
    SELECT count(tags) AS non_null_tags FROM fd_concurrent;
}
step "read_distinct_tags" {
    SELECT count(DISTINCT tags) AS distinct_tags FROM fd_concurrent;
}
step "read_per_device" {
    SELECT device, count(*) AS rows, count(tags) AS non_null
    FROM fd_concurrent GROUP BY device ORDER BY device;
}
step "read_ordered" {
    SELECT count(*) AS ordered_count
    FROM (SELECT time, device, tags FROM fd_concurrent ORDER BY time LIMIT 100) sub;
}
step "read_agg" {
    SELECT device, min(value), max(value), avg(value)::numeric(10,2)
    FROM fd_concurrent GROUP BY device ORDER BY device;
}

# Session for DML that creates partially compressed chunks
session "writer"
step "insert_new" {
    INSERT INTO fd_concurrent
    SELECT '2025-06-01 00:30:00'::timestamptz + (g || ' seconds')::interval,
           'dev-' || (g % 5),
           '["job=concurrent-insert","seq=' || g || '"]',
           10000 + g
    FROM generate_series(1, 50) g;
}
step "delete_some" {
    DELETE FROM fd_concurrent WHERE value < 0.05;
}
step "update_some" {
    UPDATE fd_concurrent SET tags = '["UPDATED"]' WHERE value > 74.0 AND value < 75.0;
}

###############################################################################
# Test permutations
###############################################################################

# Basic: compress while reading - reader must get consistent results (no crash)
permutation "compress_all" "read_count" "read_count_tags" "read_distinct_tags"
permutation "read_count" "compress_all" "read_count"
permutation "compress_begin" "compress_do" "read_count" "compress_commit" "read_count"

# Decompress while reading
permutation "compress_all" "read_count" "decompress_all" "read_count"
permutation "compress_all" "decompress_all" "read_count_tags" "read_per_device"

# Read ordered data (triggers batch sorted merge) concurrent with compression
permutation "compress_all" "read_ordered" "decompress_all" "read_ordered"
permutation "read_ordered" "compress_all" "read_ordered"

# Aggregation during compression
permutation "read_agg" "compress_all" "read_agg"
permutation "compress_all" "read_agg" "decompress_all" "read_agg"

# DML creates partial chunks, then recompress while reading
permutation "compress_all" "insert_new" "read_count" "recompress_all" "read_count"
permutation "compress_all" "insert_new" "read_count_tags" "recompress_all" "read_count_tags"
permutation "compress_all" "delete_some" "read_count" "recompress_all" "read_count"
permutation "compress_all" "update_some" "read_count_tags" "recompress_all" "read_count_tags"

# Compression rollback - data must remain uncompressed and fully readable
permutation "compress_begin" "compress_do" "compress_rollback" "read_count" "read_per_device"

# Full cycle: compress → DML → read → recompress → read
permutation "compress_all" "insert_new" "delete_some" "update_some" "read_per_device" "recompress_all" "read_per_device"
