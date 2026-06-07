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

--------------------------------------------------------------------------------
-- Regression: cache key bug + batch sorted merge with NULL-dictionary segments
--
-- This reproduces three bugs fixed together:
-- 1. The flat_dict cache key was always empty (key_len=0) when segmentby columns
--    were not referenced by the query, because the planner did not assign them a
--    custom_scan_attno. All segments shared one dictionary -> wrong results/crash.
-- 2. The prefetch did not insert a cache entry for segments whose flat_dict
--    column is entirely NULL (no dictionary row). Batch sorted merge reads data
--    batches before dictionary rows, triggering the prefetch, which then missed
--    these NULL-dict segments -> "no segment dictionary found" error.
-- 3. Dictionary rows (count==0) pushed into the batch sorted merge heap caused
--    an Assert(total_batch_rows > 0) crash in compressed_batch_save_first_tuple.
--
-- The test uses TWO segmentby columns and multiple segments where SOME have NULL
-- tags (no dictionary) and others have non-trivial dictionaries with different
-- cardinalities. All data is deterministic so every value can be verified on read.
--------------------------------------------------------------------------------
CREATE TABLE fd_cache_key_bug(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    value float NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'host,metric',
    tsdb.orderby = 'time desc',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- Reference table (plain heap) to compare against after decompression.
CREATE TABLE fd_cache_key_expected(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    value float NOT NULL,
    tags text
);

-- Generate deterministic data with:
-- * 3 hosts (alpha, bravo, charlie) -- different segment key
-- * 4 metrics per host, each with DIFFERENT tag patterns and cardinalities:
--   - disk_io: 19 distinct tags (alpha), 13 (bravo), 5 (charlie)
--   - network: 7 distinct tags (alpha), 4 (bravo) -- charlie has no network
--   - process: 23 distinct tags (alpha), 11 (bravo) -- charlie has no process
--   - temperature: NULL tags always (all hosts)
-- * 1000-2300 rows per segment for multi-batch coverage (batch size = 1000)
-- * Tags include varied lengths (50-400 chars) with host-specific content
-- * value encodes position: host_id * 1e6 + metric_id * 1e4 + row_number

-- Host alpha: disk_io (19 tags, 2100 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'alpha', 'disk_io',
       1000000 + 10000 + g,
       '["' || (CASE g % 19
           WHEN 0 THEN 'sda' WHEN 1 THEN 'sdb' WHEN 2 THEN 'nvme0n1'
           WHEN 3 THEN 'nvme0n1p1' WHEN 4 THEN 'nvme0n1p2'
           WHEN 5 THEN 'dm-0' WHEN 6 THEN 'dm-1'
           WHEN 7 THEN 'loop0' WHEN 8 THEN 'loop1' WHEN 9 THEN 'loop2'
           WHEN 10 THEN 'vda' WHEN 11 THEN 'vdb'
           WHEN 12 THEN 'xvda' WHEN 13 THEN 'xvdb'
           WHEN 14 THEN 'md0' WHEN 15 THEN 'md127'
           WHEN 16 THEN 'mmcblk0' WHEN 17 THEN 'mmcblk0p1'
           ELSE 'sr0'
       END) || '","bytes_read","' || repeat('x', 50 + (g % 200)) || '"]'
FROM generate_series(1, 2100) g;

-- Host alpha: network (7 tags, 1500 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'alpha', 'network',
       1000000 + 20000 + g,
       '["' || (CASE g % 7
           WHEN 0 THEN 'eth0' WHEN 1 THEN 'eth1' WHEN 2 THEN 'ens192'
           WHEN 3 THEN 'docker0' WHEN 4 THEN 'br-a1b2c3d4e5f6'
           WHEN 5 THEN 'veth7890abcd' ELSE 'lo'
       END) || '","rx_bytes","' || repeat('n', 80 + (g % 150)) || '"]'
FROM generate_series(1, 1500) g;

-- Host alpha: process (23 tags, 2300 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'alpha', 'process',
       1000000 + 30000 + g,
       '["' || (CASE g % 23
           WHEN 0 THEN 'systemd' WHEN 1 THEN 'sshd' WHEN 2 THEN 'postgres'
           WHEN 3 THEN 'node_exporter' WHEN 4 THEN 'prometheus'
           WHEN 5 THEN 'grafana-server' WHEN 6 THEN 'alertmanager'
           WHEN 7 THEN 'nginx' WHEN 8 THEN 'redis-server' WHEN 9 THEN 'mongod'
           WHEN 10 THEN 'kubelet' WHEN 11 THEN 'containerd' WHEN 12 THEN 'dockerd'
           WHEN 13 THEN 'etcd' WHEN 14 THEN 'coredns'
           WHEN 15 THEN 'kube-apiserver' WHEN 16 THEN 'kube-scheduler'
           WHEN 17 THEN 'kube-proxy' WHEN 18 THEN 'fluentd'
           WHEN 19 THEN 'elasticsearch' WHEN 20 THEN 'kibana'
           WHEN 21 THEN 'logstash' ELSE 'java-app-service-worker'
       END) || '","cpu_seconds","' || repeat('p', 100 + (g % 300)) || '"]'
FROM generate_series(1, 2300) g;

-- Host alpha: temperature (NULL tags, 500 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'alpha', 'temperature', 1000000 + 40000 + g, NULL
FROM generate_series(1, 500) g;

-- Host bravo: disk_io (13 tags -- DIFFERENT cardinality from alpha!, 1800 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'bravo', 'disk_io',
       2000000 + 10000 + g,
       '["' || (CASE g % 13
           WHEN 0 THEN 'sda' WHEN 1 THEN 'sdb' WHEN 2 THEN 'sdc' WHEN 3 THEN 'sdd'
           WHEN 4 THEN 'nvme0n1' WHEN 5 THEN 'nvme1n1' WHEN 6 THEN 'nvme2n1'
           WHEN 7 THEN 'dm-0' WHEN 8 THEN 'dm-1' WHEN 9 THEN 'dm-2'
           WHEN 10 THEN 'dm-3' WHEN 11 THEN 'md0' ELSE 'md1'
       END) || '","iops","' || repeat('b', 60 + (g % 180)) || '"]'
FROM generate_series(1, 1800) g;

-- Host bravo: network (4 tags, 1200 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'bravo', 'network',
       2000000 + 20000 + g,
       '["' || (CASE g % 4
           WHEN 0 THEN 'bond0' WHEN 1 THEN 'bond0.100'
           WHEN 2 THEN 'bond0.200' ELSE 'mgmt0'
       END) || '","tx_packets","' || repeat('v', 70 + (g % 120)) || '"]'
FROM generate_series(1, 1200) g;

-- Host bravo: process (11 tags, 1600 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'bravo', 'process',
       2000000 + 30000 + g,
       '["' || (CASE g % 11
           WHEN 0 THEN 'haproxy' WHEN 1 THEN 'keepalived' WHEN 2 THEN 'bird'
           WHEN 3 THEN 'frr-zebra' WHEN 4 THEN 'frr-bgpd' WHEN 5 THEN 'chrony'
           WHEN 6 THEN 'rsyslog' WHEN 7 THEN 'auditd' WHEN 8 THEN 'sssd'
           WHEN 9 THEN 'tuned' ELSE 'polkitd'
       END) || '","mem_rss","' || repeat('m', 90 + (g % 250)) || '"]'
FROM generate_series(1, 1600) g;

-- Host bravo: temperature (NULL tags, 800 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'bravo', 'temperature', 2000000 + 40000 + g, NULL
FROM generate_series(1, 800) g;

-- Host charlie: disk_io (5 tags only -- small dict, 1000 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'charlie', 'disk_io',
       3000000 + 10000 + g,
       '["' || (CASE g % 5
           WHEN 0 THEN '/dev/vda' WHEN 1 THEN '/dev/vda1' WHEN 2 THEN '/dev/vda2'
           WHEN 3 THEN '/dev/vdb' ELSE '/dev/vdb1'
       END) || '","latency_us","' || repeat('c', 40 + (g % 100)) || '"]'
FROM generate_series(1, 1000) g;

-- Host charlie: temperature (NULL tags, 600 rows)
INSERT INTO fd_cache_key_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'charlie', 'temperature', 3000000 + 40000 + g, NULL
FROM generate_series(1, 600) g;

-- Copy all data into reference table BEFORE compression
INSERT INTO fd_cache_key_expected SELECT * FROM fd_cache_key_bug;

-- Compress
SELECT count(compress_chunk(ch)) FROM show_chunks('fd_cache_key_bug') ch;

SET max_parallel_workers_per_gather = 0;

--------------------------------------------------------------------------------
-- Correctness: full data round-trip comparison.
-- Every single row must match between compressed and reference table.
--------------------------------------------------------------------------------

-- Total row counts must match:
SELECT
    (SELECT count(*) FROM fd_cache_key_bug) AS compressed_count,
    (SELECT count(*) FROM fd_cache_key_expected) AS expected_count;

-- Exact row-by-row comparison: EXCEPT must return 0 rows.
-- This catches ANY difference (wrong tags, wrong value, extra/missing rows):
SELECT count(*) AS mismatched_rows FROM (
    (SELECT time, host, metric, value, tags FROM fd_cache_key_bug
     EXCEPT
     SELECT time, host, metric, value, tags FROM fd_cache_key_expected)
    UNION ALL
    (SELECT time, host, metric, value, tags FROM fd_cache_key_expected
     EXCEPT
     SELECT time, host, metric, value, tags FROM fd_cache_key_bug)
) diff;

-- Per-segment verification: distinct tag count and NULL-tag handling
SELECT e.host, e.metric, e.distinct_tags AS expected, c.distinct_tags AS actual,
       e.distinct_tags = c.distinct_tags AS ok
FROM (SELECT host, metric, count(DISTINCT tags) AS distinct_tags
      FROM fd_cache_key_expected GROUP BY host, metric) e
JOIN (SELECT host, metric, count(DISTINCT tags) AS distinct_tags
      FROM fd_cache_key_bug GROUP BY host, metric) c
  ON e.host = c.host AND e.metric = c.metric
ORDER BY e.host, e.metric;

-- NULL-tags segments must be all NULL, no cross-segment contamination
SELECT host, count(*) AS total, count(tags) AS non_null_tags
FROM fd_cache_key_bug
WHERE metric = 'temperature'
GROUP BY host ORDER BY host;

--------------------------------------------------------------------------------
-- Batch sorted merge: min/max triggers reordered reads that exercise the
-- prefetch and dictionary-row-in-heap handling.
--------------------------------------------------------------------------------
SELECT min(time), max(time) FROM fd_cache_key_bug;

-- Specific rows via ORDER BY (batch sorted merge path):
SELECT time, host, metric, value, tags IS NOT NULL AS has_tags
FROM fd_cache_key_bug ORDER BY time LIMIT 5;

SELECT time, host, metric, value, tags IS NOT NULL AS has_tags
FROM fd_cache_key_bug ORDER BY time DESC LIMIT 5;

--------------------------------------------------------------------------------
-- Queries that do NOT reference segmentby columns in the SELECT/WHERE:
-- This is the core Bug 1 reproducer -- the cache key was empty without segmentby.
--------------------------------------------------------------------------------
SELECT count(tags) AS non_null_count FROM fd_cache_key_bug;
SELECT count(DISTINCT tags) AS total_distinct_tags FROM fd_cache_key_bug;

-- Cross-contamination checks:
-- alpha.disk_io must never contain bravo's unique device names or metric labels
SELECT count(*) AS cross_contamination FROM fd_cache_key_bug
WHERE host = 'alpha' AND metric = 'disk_io'
  AND (tags LIKE '%iops%' OR tags LIKE '%sdc%' OR tags LIKE '%sdd%'
       OR tags LIKE '%nvme1n1%' OR tags LIKE '%nvme2n1%');

-- bravo.network must never contain alpha's interface names
SELECT count(*) AS cross_contamination FROM fd_cache_key_bug
WHERE host = 'bravo' AND metric = 'network'
  AND (tags LIKE '%eth0%' OR tags LIKE '%docker0%' OR tags LIKE '%ens192%');

-- charlie.disk_io must never contain alpha/bravo process or network tags
SELECT count(*) AS cross_contamination FROM fd_cache_key_bug
WHERE host = 'charlie' AND metric = 'disk_io'
  AND (tags LIKE '%systemd%' OR tags LIKE '%haproxy%' OR tags LIKE '%bond0%');

RESET max_parallel_workers_per_gather;

DROP TABLE fd_cache_key_bug CASCADE;
DROP TABLE fd_cache_key_expected;

--------------------------------------------------------------------------------
-- Regression: long tags (up to 2400 bytes) round-trip through flat_dictionary.
--
-- Real-world Prometheus/OTel tag arrays can be 2000+ bytes. This exercises:
-- * TOAST storage of dictionary blobs (many large entries)
-- * Detoasting during cache-key build and dictionary materialization
-- * Batch sorted merge with large, TOAST-ed dictionaries
-- * Varying lengths within the same segment (100-2400 bytes)
--------------------------------------------------------------------------------
CREATE TABLE fd_long_tags(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    value float NOT NULL,
    tags text
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'host,metric',
    tsdb.orderby = 'time desc',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

CREATE TABLE fd_long_tags_expected(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    value float NOT NULL,
    tags text
);

-- Host srv1, metric containers: 30 distinct tags, each 800-2400 bytes.
-- Simulates container metadata with long image names, label sets, env vars.
INSERT INTO fd_long_tags
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'srv1', 'containers',
       g,
       '["container-' || (g % 30) || '",'
       || '"image=registry.internal.corp/team-' || (g % 30) || '/service-'
       || (CASE (g % 30) / 5
           WHEN 0 THEN 'payment-gateway'
           WHEN 1 THEN 'user-authentication'
           WHEN 2 THEN 'order-processing'
           WHEN 3 THEN 'inventory-management'
           WHEN 4 THEN 'notification-service'
           ELSE 'analytics-pipeline'
       END)
       || ':v1.' || (g % 30) || '.0",'
       || '"namespace=production-' || (CASE g % 30
           WHEN 0 THEN 'us-east-1' WHEN 1 THEN 'us-west-2' WHEN 2 THEN 'eu-central-1'
           WHEN 3 THEN 'ap-southeast-1' WHEN 4 THEN 'eu-west-1'
           ELSE 'region-' || (g % 30)
       END) || '",'
       || '"labels=' || repeat('k' || (g % 30)::text || '=v' || (g % 30)::text || ',',
                                20 + (g % 30) * 2) || '",'
       || '"env=' || repeat('ENV_VAR_' || (g % 30)::text || '=value_' || (g % 30)::text || ';',
                            10 + (g % 30)) || '",'
       || '"annotations=' || repeat('a', 200 + (g % 30) * 60) || '"]'
FROM generate_series(1, 2500) g;

-- Host srv1, metric requests: 15 distinct tags, each 400-1200 bytes.
-- Simulates HTTP request paths with query params.
INSERT INTO fd_long_tags
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'srv1', 'requests',
       10000 + g,
       '["endpoint=/api/v2/' || (CASE g % 15
           WHEN 0 THEN 'users/profile/settings'
           WHEN 1 THEN 'orders/checkout/confirm'
           WHEN 2 THEN 'products/search/results'
           WHEN 3 THEN 'inventory/warehouses/stock'
           WHEN 4 THEN 'notifications/push/batch'
           WHEN 5 THEN 'analytics/reports/daily'
           WHEN 6 THEN 'auth/oauth2/token/refresh'
           WHEN 7 THEN 'billing/invoices/generate'
           WHEN 8 THEN 'shipping/tracking/updates'
           WHEN 9 THEN 'support/tickets/create'
           WHEN 10 THEN 'media/uploads/process'
           WHEN 11 THEN 'cache/invalidate/pattern'
           WHEN 12 THEN 'webhooks/delivery/retry'
           WHEN 13 THEN 'config/features/toggle'
           ELSE 'health/deep/dependencies'
       END) || '?session_id=' || repeat('s', 100 + (g % 15) * 50)
       || '&trace_id=' || repeat('t', 80 + (g % 15) * 30) || '"]'
FROM generate_series(1, 1800) g;

-- Host srv2, metric containers: 25 distinct tags, each 1000-2400 bytes.
-- DIFFERENT tag content from srv1 to catch cross-segment contamination.
INSERT INTO fd_long_tags
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'srv2', 'containers',
       20000 + g,
       '["pod-' || (g % 25) || '",'
       || '"image=gcr.io/project-' || (g % 25) || '/microservice-'
       || (CASE (g % 25) / 5
           WHEN 0 THEN 'data-ingestion'
           WHEN 1 THEN 'stream-processor'
           WHEN 2 THEN 'model-serving'
           WHEN 3 THEN 'feature-store'
           ELSE 'batch-scheduler'
       END)
       || ':release-' || (g % 25) || '",'
       || '"cluster=gke-prod-' || (CASE g % 25
           WHEN 0 THEN 'us-central1-a' WHEN 1 THEN 'us-central1-b'
           WHEN 2 THEN 'europe-west4-a' WHEN 3 THEN 'asia-east1-b'
           ELSE 'zone-' || (g % 25)
       END) || '",'
       || '"resources=' || repeat('cpu=' || (g % 25)::text || 'm,mem=' || (g % 25 * 128)::text || 'Mi,',
                                  15 + (g % 25) * 2) || '",'
       || '"tolerations=' || repeat('T', 300 + (g % 25) * 70) || '"]'
FROM generate_series(1, 2200) g;

-- Host srv2, metric sensors: NULL tags (to test NULL-dict + long-tag mix)
INSERT INTO fd_long_tags
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'srv2', 'sensors', 30000 + g, NULL
FROM generate_series(1, 700) g;

-- Copy before compression
INSERT INTO fd_long_tags_expected SELECT * FROM fd_long_tags;

-- Verify we actually have long tags (the point of this test):
SELECT
    min(length(tags)) AS min_len,
    avg(length(tags))::int AS avg_len,
    max(length(tags)) AS max_len,
    count(*) FILTER (WHERE length(tags) > 2000) AS over_2000_bytes
FROM fd_long_tags
WHERE tags IS NOT NULL;

-- Compress
SELECT count(compress_chunk(ch)) FROM show_chunks('fd_long_tags') ch;

SET max_parallel_workers_per_gather = 0;

-- Full round-trip: every row must survive compression unchanged.
SELECT count(*) AS mismatched_rows FROM (
    (SELECT time, host, metric, value, tags FROM fd_long_tags
     EXCEPT
     SELECT time, host, metric, value, tags FROM fd_long_tags_expected)
    UNION ALL
    (SELECT time, host, metric, value, tags FROM fd_long_tags_expected
     EXCEPT
     SELECT time, host, metric, value, tags FROM fd_long_tags)
) diff;

-- Verify tag lengths survived compression (not truncated):
SELECT
    min(length(tags)) AS min_len,
    avg(length(tags))::int AS avg_len,
    max(length(tags)) AS max_len,
    count(*) FILTER (WHERE length(tags) > 2000) AS over_2000_bytes
FROM fd_long_tags
WHERE tags IS NOT NULL;

-- Per-segment distinct counts:
SELECT host, metric, count(DISTINCT tags) AS distinct_tags, count(*) AS rows
FROM fd_long_tags
GROUP BY host, metric
ORDER BY host, metric;

-- Batch sorted merge must work with TOAST-ed long-tag dictionaries:
SELECT min(time), max(time) FROM fd_long_tags;

SELECT time, host, metric, length(tags) AS tag_len
FROM fd_long_tags ORDER BY time LIMIT 3;

SELECT time, host, metric, length(tags) AS tag_len
FROM fd_long_tags ORDER BY time DESC LIMIT 3;

-- Cross-segment contamination: srv1 containers must not have srv2 content
SELECT count(*) AS cross_contamination FROM fd_long_tags
WHERE host = 'srv1' AND metric = 'containers'
  AND (tags LIKE '%gcr.io%' OR tags LIKE '%gke-prod%' OR tags LIKE '%pod-%');

-- srv2 containers must not have srv1 content
SELECT count(*) AS cross_contamination FROM fd_long_tags
WHERE host = 'srv2' AND metric = 'containers'
  AND (tags LIKE '%registry.internal%' OR tags LIKE '%production-%');

-- Spot-check a specific long value survived intact:
SELECT length(tags) AS len, left(tags, 80) AS prefix, right(tags, 40) AS suffix
FROM fd_long_tags
WHERE host = 'srv1' AND metric = 'containers' AND value = 30
LIMIT 1;

-- NULL-dict segment still works:
SELECT count(*) AS total, count(tags) AS non_null
FROM fd_long_tags WHERE metric = 'sensors';

RESET max_parallel_workers_per_gather;

DROP TABLE fd_long_tags CASCADE;
DROP TABLE fd_long_tags_expected;

DROP TABLE fd_metrics CASCADE;
DROP TABLE fd_many CASCADE;

RESET max_parallel_workers_per_gather;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET timescaledb.enable_vectorized_aggregation;
