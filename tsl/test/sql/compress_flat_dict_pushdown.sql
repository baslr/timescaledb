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
:PREFIX SELECT time, device, tags FROM fd_metrics ORDER BY time;
SELECT time, device, tags FROM fd_metrics ORDER BY time;
SELECT time, device, tags FROM fd_metrics ORDER BY time DESC;
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

DROP TABLE fd_metrics CASCADE;
DROP TABLE fd_many CASCADE;

RESET max_parallel_workers_per_gather;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET timescaledb.enable_vectorized_aggregation;
