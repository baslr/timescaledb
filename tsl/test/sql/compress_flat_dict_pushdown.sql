-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

-- Tests for per-segment flat_dictionary dictionary caching, which lets the
-- planner push ORDER BY down (reverse scan, batch sorted merge, compressed
-- sort) for tables that use the flat_dictionary algorithm. Before the
-- per-segment cache these were disabled by a planner guard and an explicit
-- Sort was added above a forward ColumnarScan.

SET timezone TO 'UTC';

\set PREFIX 'EXPLAIN (buffers off, costs off, timing off, summary off)'

CREATE TABLE fd_metrics(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL,
    value float
) WITH (
    tsdb.hypertable,
    tsdb.orderby='time desc',
    tsdb.segmentby='device',
    tsdb.compress_algorithm='tags flat_dictionary'
);

-- Two segments (device d1, d2). Multiple distinct tag values per segment so the
-- flat_dictionary actually builds a non-trivial dictionary per segment, and the
-- two segments get DIFFERENT dictionaries (d1: a/b/c, d2: x/y/z) to catch any
-- cross-segment dictionary mixup.
INSERT INTO fd_metrics VALUES
('2025-01-01 00:00:00', 'd1', 'tag-a', 10.0),
('2025-01-01 01:00:00', 'd1', 'tag-b', 20.0),
('2025-01-01 02:00:00', 'd1', 'tag-c', 15.0),
('2025-01-01 03:00:00', 'd1', 'tag-a', 11.0),
('2025-01-01 04:00:00', 'd1', 'tag-b', 21.0),
('2025-01-01 05:00:00', 'd1', 'tag-c', 16.0),
('2025-01-01 00:00:00', 'd2', 'tag-x', 30.0),
('2025-01-01 01:00:00', 'd2', 'tag-y', 40.0),
('2025-01-01 02:00:00', 'd2', 'tag-z', 35.0),
('2025-01-01 03:00:00', 'd2', 'tag-x', 31.0),
('2025-01-01 04:00:00', 'd2', 'tag-y', 41.0),
('2025-01-01 05:00:00', 'd2', 'tag-z', 36.0);

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_metrics') ch;

-- Verify flat_dictionary is active in catalog
SELECT relid::regclass, segmentby, orderby, algorithm
FROM _timescaledb_catalog.compression_settings
WHERE relid = 'fd_metrics'::regclass;

SET max_parallel_workers_per_gather = 0;
SET enable_bitmapscan = 0;
SET enable_seqscan = 0;
SET timescaledb.enable_vectorized_aggregation = off;

--------------------------------------------------------------------------------
-- test_flat_dict_order_by_pushdown:
-- ORDER BY time within a segment should be answered by a compressed sort
-- pushdown / batch sorted merge, NOT a separate Sort node above ColumnarScan.
--------------------------------------------------------------------------------
:PREFIX SELECT time, tags FROM fd_metrics WHERE device = 'd1' ORDER BY time;
SELECT time, tags FROM fd_metrics WHERE device = 'd1' ORDER BY time;

--------------------------------------------------------------------------------
-- test_flat_dict_reverse_scan:
-- ORDER BY time DESC matches the orderby, so it can be served by a reverse
-- pushdown. The flat_dictionary values must come out correct in reverse order.
--------------------------------------------------------------------------------
:PREFIX SELECT time, tags FROM fd_metrics WHERE device = 'd1' ORDER BY time DESC;
SELECT time, tags FROM fd_metrics WHERE device = 'd1' ORDER BY time DESC;

--------------------------------------------------------------------------------
-- test_flat_dict_sorted_merge_multi_segment:
-- ORDER BY time across ALL segments interleaves batches from d1 and d2, so the
-- decompressor holds both segments' dictionaries in flight. Each row's tags must
-- resolve against its own segment dictionary (d1 -> tag-a/b/c, d2 -> tag-x/y/z).
--------------------------------------------------------------------------------
SET timescaledb.debug_require_batch_sorted_merge = 'allow';
:PREFIX SELECT time, device, tags FROM fd_metrics ORDER BY time, device;
SELECT time, device, tags FROM fd_metrics ORDER BY time, device;
SELECT time, device, tags FROM fd_metrics ORDER BY time DESC, device;
RESET timescaledb.debug_require_batch_sorted_merge;

--------------------------------------------------------------------------------
-- test_flat_dict_select_only_dict_column:
-- Selecting ONLY the flat_dictionary column with an ORDER BY that triggers a
-- reordered read exercises the segmentby-forced-into-scan path and the
-- prefetch-on-miss: the segmentby column is not referenced by the query but is
-- still needed to key the dictionary cache.
--------------------------------------------------------------------------------
SELECT tags FROM fd_metrics ORDER BY time DESC, device;

-- Correctness cross-check: aggregate that must read every value back.
SELECT device, count(DISTINCT tags) AS n_tags, string_agg(DISTINCT tags, ',' ORDER BY tags) AS tags
FROM fd_metrics GROUP BY device ORDER BY device;

--------------------------------------------------------------------------------
-- Reverse + multi-segment with more than one batch per segment. Lower the batch
-- size so each segment spans several batches, stressing the per-batch dictionary
-- resolution across batch boundaries.
--------------------------------------------------------------------------------
CREATE TABLE fd_many(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.orderby='time',
    tsdb.segmentby='device',
    tsdb.compress_algorithm='tags flat_dictionary'
);

INSERT INTO fd_many
SELECT '2025-01-01'::timestamptz + (g || ' minutes')::interval,
       'dev' || (g % 3),
       'tag-' || (g % 7)
FROM generate_series(0, 999) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_many') ch;

-- Verify flat_dictionary is active in catalog
SELECT relid::regclass, segmentby, orderby, algorithm
FROM _timescaledb_catalog.compression_settings
WHERE relid = 'fd_many'::regclass;

-- Forward and reverse full scans must agree on the multiset of values and be
-- exact reverses of each other on the orderby column.
SELECT device, tags, count(*) FROM fd_many GROUP BY device, tags ORDER BY device, tags;

SELECT count(*) AS total,
       count(DISTINCT tags) AS distinct_tags,
       count(DISTINCT device) AS distinct_devices
FROM fd_many;

-- First and last few rows in each direction (values must be correct, not NULL
-- or cross-segment garbage).
SELECT time, device, tags FROM fd_many ORDER BY time ASC LIMIT 5;
SELECT time, device, tags FROM fd_many ORDER BY time DESC LIMIT 5;

--------------------------------------------------------------------------------
-- Regression test: compression must not crash with > 1000 rows per segment.
-- This triggers a batch flush during Pass 2 replay of the flat_dict two-pass
-- compression. Before the fix, the batch flush would reset per_row_ctx and free
-- the dictionary hash keys, causing a use-after-free crash on the next lookup.
--------------------------------------------------------------------------------
CREATE TABLE fd_large_segment(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- 2000 rows in a single segment (device = 'dev0') — well above batch size (1000)
-- Tags are 100-2100 bytes long (matching real-world data: avg 202, max 2107)
INSERT INTO fd_large_segment
SELECT '2025-01-01'::timestamptz + (g || ' seconds')::interval,
       'dev0',
       CASE WHEN g % 50 = 0 THEN NULL
            ELSE '["' || g % 200 || '","process-name-' || (g % 5) || '","' ||
                 repeat('x', 100 + (g % 2000)) || '"]'
       END
FROM generate_series(1, 2000) g;

-- This must not crash:
SELECT count(compress_chunk(ch)) FROM show_chunks('fd_large_segment') ch;

-- Verify data survives round-trip (read back from compressed)
SELECT count(*) AS total, count(tags) AS non_null, count(DISTINCT tags) AS distinct_tags FROM fd_large_segment;

DROP TABLE fd_large_segment CASCADE;

--------------------------------------------------------------------------------
-- Edge case: NULL values in flat_dictionary column
-- NULLs must be preserved through compression/decompression round-trip.
--------------------------------------------------------------------------------
CREATE TABLE fd_nulls(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

INSERT INTO fd_nulls VALUES
('2025-01-01 00:00', 'dev0', 'tag-a'),
('2025-01-01 01:00', 'dev0', NULL),
('2025-01-01 02:00', 'dev0', 'tag-b'),
('2025-01-01 03:00', 'dev0', NULL),
('2025-01-01 04:00', 'dev0', 'tag-a'),
('2025-01-01 00:00', 'dev1', NULL),
('2025-01-01 01:00', 'dev1', 'tag-x'),
('2025-01-01 02:00', 'dev1', NULL);

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_nulls') ch;

-- NULLs must appear in correct positions
SELECT time, device, tags FROM fd_nulls ORDER BY device, time;

-- Aggregate must count NULLs correctly
SELECT device, count(*) AS total, count(tags) AS non_null, count(*) - count(tags) AS nulls
FROM fd_nulls GROUP BY device ORDER BY device;

DROP TABLE fd_nulls CASCADE;

--------------------------------------------------------------------------------
-- Edge case: single-row segments
-- Each segment has exactly 1 row — tests minimal dictionary (1 entry).
--------------------------------------------------------------------------------
CREATE TABLE fd_single_row(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

INSERT INTO fd_single_row VALUES
('2025-01-01 00:00', 'a', 'only-tag'),
('2025-01-01 00:00', 'b', 'other-tag'),
('2025-01-01 00:00', 'c', 'third-tag');

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_single_row') ch;

SELECT device, tags FROM fd_single_row ORDER BY device;

DROP TABLE fd_single_row CASCADE;

--------------------------------------------------------------------------------
-- Edge case: many distinct values (>255) forces 16-bit index width
-- Verifies the index_width upgrade path in flat_dict_compressor_finish.
--------------------------------------------------------------------------------
CREATE TABLE fd_wide_dict(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- 500 rows with 300 distinct tags in one segment → forces 16-bit index
INSERT INTO fd_wide_dict
SELECT '2025-01-01'::timestamptz + (g || ' seconds')::interval,
       'dev0',
       '["' || (g % 300) || '","' || repeat('y', 100 + (g % 2000)) || '"]'
FROM generate_series(1, 500) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_wide_dict') ch;

-- Verify round-trip: count distinct must match
SELECT count(*) AS total, count(DISTINCT tags) AS distinct_tags FROM fd_wide_dict;

-- Spot check some values
SELECT time, tags FROM fd_wide_dict ORDER BY time LIMIT 3;
SELECT time, tags FROM fd_wide_dict ORDER BY time DESC LIMIT 3;

DROP TABLE fd_wide_dict CASCADE;

--------------------------------------------------------------------------------
-- Edge case: all rows have the same tag value (dictionary cardinality = 1)
-- Tests that a degenerate dictionary (single entry) works correctly.
--------------------------------------------------------------------------------
CREATE TABLE fd_uniform(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

INSERT INTO fd_uniform
SELECT '2025-01-01'::timestamptz + (g || ' seconds')::interval,
       'dev0',
       'always-same'
FROM generate_series(1, 100) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_uniform') ch;

SELECT count(*) AS total, count(DISTINCT tags) AS distinct_tags FROM fd_uniform;

DROP TABLE fd_uniform CASCADE;

--------------------------------------------------------------------------------
-- Edge case: empty segment (device with no rows after filter)
-- Tests that compression handles segments gracefully when no data matches.
--------------------------------------------------------------------------------
CREATE TABLE fd_empty_seg(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- Only one device has data
INSERT INTO fd_empty_seg
SELECT '2025-01-01'::timestamptz + (g || ' minutes')::interval,
       'dev0',
       'tag-' || (g % 3)
FROM generate_series(1, 50) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_empty_seg') ch;

SELECT count(*) AS total FROM fd_empty_seg;

DROP TABLE fd_empty_seg CASCADE;

--------------------------------------------------------------------------------
-- Stress test: many segments with batch flushes in each
-- 5 devices × 1500 rows each = 7500 total, each segment > batch size (1000)
-- Tests the full Pass1→Flush→Pass2→Reset→next-segment cycle multiple times.
--------------------------------------------------------------------------------
CREATE TABLE fd_stress(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

INSERT INTO fd_stress
SELECT '2025-01-01'::timestamptz + (g || ' seconds')::interval,
       'dev' || (g % 5),
       CASE WHEN g % 100 = 0 THEN NULL
            ELSE '["' || (g % 1000) || '","cmd-' || (g % 10) || '","' || repeat(chr(65 + (g % 26)), 80 + (g % 2000)) || '"]'
       END
FROM generate_series(1, 7500) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_stress') ch;

-- Verify all data intact after round-trip (reads from compressed chunks)
SELECT device, count(*) AS rows, count(tags) AS non_null, count(DISTINCT tags) AS distinct_tags
FROM fd_stress GROUP BY device ORDER BY device;

-- Verify ordering preserved
SELECT time, device, left(tags, 30) AS tags_prefix FROM fd_stress ORDER BY time ASC LIMIT 3;
SELECT time, device, left(tags, 30) AS tags_prefix FROM fd_stress ORDER BY time DESC LIMIT 3;

DROP TABLE fd_stress CASCADE;

--------------------------------------------------------------------------------
-- Regression: decompression with many segments (tests per-segment cache lookup)
-- The cache must return the correct dictionary for each (host, metric) segment.
-- With many segments that have DIFFERENT dictionary cardinalities, a cache
-- mismatch would cause idx >= num_values and crash.
--------------------------------------------------------------------------------
CREATE TABLE fd_decompress_many(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'host, metric',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- 20 hosts × 5 metrics = 100 segments. Each segment has different number of
-- distinct tags (3 to 50) with long values (200-2100 bytes). Some NULLs.
INSERT INTO fd_decompress_many
SELECT '2025-01-01'::timestamptz + (g || ' seconds')::interval,
       'host-' || (g % 20),
       'metric-' || (g % 5),
       CASE WHEN g % 80 = 0 THEN NULL
            ELSE '["' || (g % (3 + (g % 20) * 2)) || '","' ||
                 repeat(chr(65 + (g % 26)), 100 + (g % 2000)) || '"]'
       END
FROM generate_series(1, 10000) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('fd_decompress_many') ch;

-- Verify decompression: reading tags back must not crash
SET max_parallel_workers_per_gather = 0;
SELECT host, metric, count(*) AS rows, count(tags) AS non_null
FROM fd_decompress_many
GROUP BY host, metric
ORDER BY host, metric
LIMIT 10;
RESET max_parallel_workers_per_gather;

DROP TABLE fd_decompress_many CASCADE;

DROP TABLE fd_metrics CASCADE;
DROP TABLE fd_many CASCADE;

RESET max_parallel_workers_per_gather;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET timescaledb.enable_vectorized_aggregation;
