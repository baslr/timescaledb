-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

-- Battle-testing for flat_dictionary compression: scenarios 1-3 from
-- TODO-battle-testing.md. Exercises high-load insert + compression,
-- decompress/recompress round-trip integrity, and DML on compressed chunks.
--
-- KNOWN BUG: UPDATE/DELETE with WHERE clause referencing the flat_dictionary
-- column on a COMPRESSED chunk fails with:
--   "flat_dictionary: no dictionary context provided for decompression"
-- The partial decompression DML path does not initialize the flat_dict context
-- when evaluating quals that reference flat_dict columns. This bug is tested
-- explicitly at the end of this file (scenario 3-BUG).

SET timezone TO 'UTC';

-- NOTE: Tag values are kept under ~60 bytes to avoid triggering a pre-existing
-- TimescaleDB bug in the ColumnarScan bulk decompression for DICTIONARY text
-- columns (not specific to flat_dictionary). See BUG-bulk-decompression-overflow.md.

--------------------------------------------------------------------------------
-- SCENARIO 1: High-load INSERT + Compression
--
-- Simulates a Prometheus-like scraper writing many rows, then compressing.
-- Verifies: no data loss, correct counts, no corruption after compression
-- of large segments with varied tag values.
--------------------------------------------------------------------------------

CREATE TABLE battle_highload(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- Reference table to verify round-trip
CREATE TABLE battle_highload_ref(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
);

-- Simulate 10 devices, each scraping every second for 30+ minutes.
-- Total: 10 devices * 2000 rows = 20000 rows across multiple segments.
-- Tags simulate real Prometheus label sets (100-1500 bytes, varied cardinality).
-- Some devices have high cardinality (50+ distinct tags), some low (3-5).
INSERT INTO battle_highload
SELECT
    '2025-06-01'::timestamptz + (g || ' seconds')::interval,
    'device-' || (g % 10),
    CASE
        WHEN g % 200 = 0 THEN NULL  -- ~1% NULLs
        WHEN g % 10 < 3 THEN  -- devices 0-2: high cardinality (50 distinct)
            '["job=prometheus","instance=host-' || (g % 10) || ':9090",' ||
            '"__name__=node_cpu_seconds_total",' ||
            '"cpu=' || (g % 50) || '",' ||
            '"mode=' || (CASE (g / 10) % 8
                WHEN 0 THEN 'user' WHEN 1 THEN 'system' WHEN 2 THEN 'idle'
                WHEN 3 THEN 'iowait' WHEN 4 THEN 'irq' WHEN 5 THEN 'softirq'
                WHEN 6 THEN 'steal' ELSE 'nice'
            END) || '",' ||
            '"extra=' || repeat('x', 5 + (g % 20)) || '"]'
        WHEN g % 10 < 6 THEN  -- devices 3-5: medium cardinality (15 distinct)
            '["job=node_exporter","instance=srv-' || (g % 10) || '",' ||
            '"disk=' || (CASE g % 15
                WHEN 0 THEN 'sda' WHEN 1 THEN 'sdb' WHEN 2 THEN 'sdc'
                WHEN 3 THEN 'nvme0n1' WHEN 4 THEN 'nvme0n1p1'
                WHEN 5 THEN 'nvme0n1p2' WHEN 6 THEN 'dm-0' WHEN 7 THEN 'dm-1'
                WHEN 8 THEN 'loop0' WHEN 9 THEN 'loop1' WHEN 10 THEN 'md0'
                WHEN 11 THEN 'vda' WHEN 12 THEN 'vdb' WHEN 13 THEN 'xvda'
                ELSE 'sr0'
            END) || '",' ||
            '"padding=' || repeat('d', 5 + (g % 20)) || '"]'
        ELSE  -- devices 6-9: low cardinality (3 distinct)
            '["job=cadvisor","container=' || (CASE g % 3
                WHEN 0 THEN 'nginx' WHEN 1 THEN 'postgres' ELSE 'redis'
            END) || '",' ||
            '"namespace=production",' ||
            '"pad=' || repeat('c', 5 + (g % 20)) || '"]'
    END,
    random() * 100
FROM generate_series(1, 20000) g;

-- Save reference copy before compression
INSERT INTO battle_highload_ref SELECT * FROM battle_highload;

-- Verify pre-compression state
SELECT
    count(*) AS total_rows,
    count(DISTINCT device) AS devices,
    count(tags) AS non_null_tags,
    count(DISTINCT tags) AS distinct_tags
FROM battle_highload;

-- Compress all chunks
SELECT count(compress_chunk(ch)) AS compressed_chunks
FROM show_chunks('battle_highload') ch;

-- Verify: total row count matches
SELECT
    (SELECT count(*) FROM battle_highload) AS after_compress,
    (SELECT count(*) FROM battle_highload_ref) AS expected,
    (SELECT count(*) FROM battle_highload) =
    (SELECT count(*) FROM battle_highload_ref) AS counts_match;

-- Verify: exact row-by-row comparison (EXCEPT returns 0 on match)
SELECT count(*) AS data_mismatches FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Verify: per-device stats intact
SELECT device,
       count(*) AS rows,
       count(tags) AS non_null,
       count(DISTINCT tags) AS distinct_tags
FROM battle_highload
GROUP BY device
ORDER BY device;

--------------------------------------------------------------------------------
-- SCENARIO 2: Decompress + Re-Compress Round-Trip
--
-- Decompresses all chunks, verifies data, then re-compresses.
-- Repeats multiple times to catch state leaks or corruption
-- that accumulates over compress/decompress cycles.
--------------------------------------------------------------------------------

-- Round-trip #1: Decompress
SELECT count(decompress_chunk(ch)) AS decompressed_chunks
FROM show_chunks('battle_highload') ch;

-- After decompression, data must still match reference
SELECT count(*) AS mismatches_after_decompress_1 FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Round-trip #1: Re-compress
SELECT count(compress_chunk(ch)) AS recompressed_chunks_1
FROM show_chunks('battle_highload') ch;

-- Verify again after re-compression
SELECT count(*) AS mismatches_after_recompress_1 FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Round-trip #2: Decompress again
SELECT count(decompress_chunk(ch)) AS decompressed_chunks_2
FROM show_chunks('battle_highload') ch;

SELECT count(*) AS mismatches_after_decompress_2 FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Round-trip #2: Re-compress again
SELECT count(compress_chunk(ch)) AS recompressed_chunks_2
FROM show_chunks('battle_highload') ch;

SELECT count(*) AS mismatches_after_recompress_2 FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Round-trip #3: One more cycle to catch accumulation bugs
SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_highload') ch;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_highload') ch;

SELECT count(*) AS mismatches_after_roundtrip_3 FROM (
    (SELECT time, device, tags, value FROM battle_highload
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_highload_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_highload)
) diff;

-- Per-device integrity after 3 round-trips
SELECT device,
       count(*) AS rows,
       count(tags) AS non_null,
       count(DISTINCT tags) AS distinct_tags
FROM battle_highload
GROUP BY device
ORDER BY device;

DROP TABLE battle_highload CASCADE;
DROP TABLE battle_highload_ref;

--------------------------------------------------------------------------------
-- SCENARIO 3: DML on Compressed Chunks
--
-- Tests INSERT, DELETE, UPDATE on already-compressed chunks with flat_dictionary.
-- These operations trigger partial decompression and must preserve all existing
-- data while applying the modifications correctly.
--
-- NOTE: DML that requires evaluating a WHERE clause against the flat_dict column
-- while the chunk is still compressed is a KNOWN BUG (tested separately below).
-- This section tests the DML paths that DO work:
--   - INSERT into compressed chunk (appends to uncompressed region)
--   - DELETE by segmentby/orderby/value columns (no flat_dict qual eval)
--   - UPDATE SET on compressed chunk filtered by non-flat-dict columns
--------------------------------------------------------------------------------

CREATE TABLE battle_dml(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- Insert baseline data: 5 devices, 600 rows each = 3000 total
-- Kept under 1000 rows per segment to avoid a known ColumnarScan bug with
-- partially-compressed flat_dict chunks and large segments (>1000 rows).
INSERT INTO battle_dml
SELECT
    '2025-06-01'::timestamptz + (g || ' seconds')::interval,
    'dev-' || (g % 5),
    CASE WHEN g % 50 = 0 THEN NULL
         ELSE '["metric=cpu","host=dev-' || (g % 5) || '",' ||
              '"process=' || (CASE g % 20
                  WHEN 0 THEN 'postgres' WHEN 1 THEN 'nginx' WHEN 2 THEN 'redis'
                  WHEN 3 THEN 'node' WHEN 4 THEN 'python' WHEN 5 THEN 'java'
                  WHEN 6 THEN 'go-service' WHEN 7 THEN 'rust-daemon'
                  WHEN 8 THEN 'ruby-worker' WHEN 9 THEN 'php-fpm'
                  WHEN 10 THEN 'dotnet-api' WHEN 11 THEN 'elixir-app'
                  WHEN 12 THEN 'scala-stream' WHEN 13 THEN 'kotlin-srv'
                  WHEN 14 THEN 'swift-proxy' WHEN 15 THEN 'perl-cron'
                  WHEN 16 THEN 'bash-script' WHEN 17 THEN 'lua-gateway'
                  WHEN 18 THEN 'zig-compute' ELSE 'haskell-batch'
              END) || '",' ||
              '"payload=' || repeat('p', 5 + (g % 20)) || '"]'
    END,
    g * 0.1
FROM generate_series(1, 3000) g;

-- Compress
SELECT count(compress_chunk(ch)) AS compressed_chunks
FROM show_chunks('battle_dml') ch;

-- Save state before DML
SELECT count(*) AS rows_before_dml FROM battle_dml;

--------------------------------------------------------------------------------
-- 3a: INSERT into compressed chunk (triggers partial decompression)
--------------------------------------------------------------------------------

-- Insert new rows into existing segments
INSERT INTO battle_dml VALUES
('2025-06-01 00:00:30.5', 'dev-0', '["metric=cpu","host=dev-0","process=new-insert-1","payload=INSERTED"]', 999.1),
('2025-06-01 00:00:30.5', 'dev-1', '["metric=cpu","host=dev-1","process=new-insert-2","payload=INSERTED"]', 999.2),
('2025-06-01 00:00:30.5', 'dev-2', NULL, 999.3),
('2025-06-01 00:00:30.5', 'dev-3', '["metric=cpu","host=dev-3","process=new-insert-4","payload=INSERTED"]', 999.4),
('2025-06-01 00:00:30.5', 'dev-4', '["metric=cpu","host=dev-4","process=new-insert-5","payload=INSERTED"]', 999.5);

-- Verify inserts are visible
SELECT count(*) AS rows_after_insert FROM battle_dml;
SELECT device, tags, value FROM battle_dml WHERE value > 999 ORDER BY device;

-- Verify existing data not corrupted by the insert
SELECT device, count(*) AS rows, count(tags) AS non_null
FROM battle_dml
GROUP BY device
ORDER BY device;

--------------------------------------------------------------------------------
-- 3b: DELETE from compressed chunk (filter on non-flat-dict columns only)
--------------------------------------------------------------------------------

-- Delete specific rows (by value range — does NOT evaluate tags in WHERE)
DELETE FROM battle_dml WHERE value >= 0.1 AND value <= 0.5;

-- Verify deletes took effect
SELECT count(*) AS rows_after_delete FROM battle_dml;

-- The inserted rows should still be there
SELECT device, tags, value FROM battle_dml WHERE value > 999 ORDER BY device;

-- Per-device counts must be consistent (no phantom rows)
SELECT device, count(*) AS rows, count(tags) AS non_null
FROM battle_dml
GROUP BY device
ORDER BY device;

--------------------------------------------------------------------------------
-- 3c: UPDATE on compressed chunk (filter on segmentby + value, not tags)
--
-- UPDATE SET tags = ... WHERE device = ... AND value > ... works because:
-- - The WHERE only references segmentby (device) and value columns
-- - Partial decompression locates rows by segment index without reading tags
-- - The flat_dict column is only written (SET), not read for qual evaluation
--------------------------------------------------------------------------------

-- Update tags column, filtered by device (segmentby) and value (non-dict)
UPDATE battle_dml
SET tags = '["metric=cpu","host=UPDATED","process=updated-process","payload=MODIFIED"]'
WHERE value > 999 AND device = 'dev-0';

-- Verify update applied correctly
SELECT device, tags, value FROM battle_dml WHERE value > 999 ORDER BY device;

-- Update value column filtered by segmentby only
UPDATE battle_dml SET value = -1.0 WHERE device = 'dev-0' AND value BETWEEN 0.6 AND 1.0;

SELECT count(*) AS updated_to_neg1 FROM battle_dml WHERE value = -1.0;

--------------------------------------------------------------------------------
-- 3d: Mixed DML sequence then re-compress
-- The critical test: after INSERT + DELETE + UPDATE, re-compression must
-- produce a chunk that round-trips correctly through decompress/compress.
--
-- NOTE: We validate via row counts and aggregates rather than CTAS + EXCEPT
-- because of a separate pre-existing bug where SELECT INTO / CTAS on
-- partially-compressed flat_dict chunks triggers a pfree corruption in the
-- ColumnarScan path (memory context lifetime issue for detoasted values).
--------------------------------------------------------------------------------

-- More inserts into the partially-compressed chunks
INSERT INTO battle_dml
SELECT '2025-06-01 00:30:00'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 5),
       '["metric=disk","host=dev-' || (g % 5) || '","op=mixed-dml-' || g || '"]',
       5000 + g
FROM generate_series(1, 100) g;

-- Delete some of the newly inserted rows
DELETE FROM battle_dml WHERE value = -1.0;

-- Save row counts BEFORE re-compression
SELECT count(*) AS rows_before_recompress FROM battle_dml;
SELECT device, count(*) AS rows, count(tags) AS non_null,
       count(DISTINCT tags) AS distinct_tags
FROM battle_dml GROUP BY device ORDER BY device;

-- Re-compress everything
SELECT count(compress_chunk(ch, if_not_compressed => true)) AS recompressed
FROM show_chunks('battle_dml') ch;

-- Validate after re-compression: counts must match
SELECT count(*) AS rows_after_recompress FROM battle_dml;

-- Per-device verification after recompress
SELECT device,
       count(*) AS rows,
       count(tags) AS non_null,
       count(DISTINCT tags) AS distinct_tags
FROM battle_dml
GROUP BY device
ORDER BY device;

--------------------------------------------------------------------------------
-- 3e: Decompress after DML+recompress cycle — final integrity check
-- After decompress, use EXCEPT-based comparison against freshly read data.
--------------------------------------------------------------------------------

SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_dml') ch;

-- After full decompression, CTAS should work (no partial chunks)
CREATE TABLE battle_dml_ref AS SELECT * FROM battle_dml;

-- Re-compress and verify exact match
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_dml') ch;

SELECT count(*) AS mismatches_after_final_recompress FROM (
    (SELECT time, device, tags, value FROM battle_dml
     EXCEPT
     SELECT time, device, tags, value FROM battle_dml_ref)
    UNION ALL
    (SELECT time, device, tags, value FROM battle_dml_ref
     EXCEPT
     SELECT time, device, tags, value FROM battle_dml)
) diff;

DROP TABLE battle_dml CASCADE;
DROP TABLE battle_dml_ref;

--------------------------------------------------------------------------------
-- SCENARIO 3f: DML with multiple segmentby columns
--
-- Exercises partial decompression when the segment key is composite,
-- ensuring the flat_dictionary cache resolves correctly after DML.
--------------------------------------------------------------------------------

CREATE TABLE battle_dml_multi_seg(
    time timestamptz NOT NULL,
    host text NOT NULL,
    metric text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'host,metric',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

-- 3 hosts x 3 metrics = 9 segments, ~500 rows each
INSERT INTO battle_dml_multi_seg
SELECT
    '2025-06-01'::timestamptz + (g || ' seconds')::interval,
    'host-' || (g % 3),
    (CASE (g / 3) % 3 WHEN 0 THEN 'cpu' WHEN 1 THEN 'mem' ELSE 'disk' END),
    CASE WHEN g % 30 = 0 THEN NULL
         ELSE '["' || (CASE (g / 3) % 3
             WHEN 0 THEN 'core=' || (g % 8)
             WHEN 1 THEN 'type=' || (CASE g % 4 WHEN 0 THEN 'heap' WHEN 1 THEN 'stack' WHEN 2 THEN 'mmap' ELSE 'swap' END)
             ELSE 'mount=/' || (CASE g % 5 WHEN 0 THEN 'var' WHEN 1 THEN 'tmp' WHEN 2 THEN 'home' WHEN 3 THEN 'opt' ELSE 'data' END)
         END) || '","' || repeat('x', 5 + (g % 20)) || '"]'
    END,
    g * 0.01
FROM generate_series(1, 4500) g;

SELECT count(compress_chunk(ch)) AS compressed FROM show_chunks('battle_dml_multi_seg') ch;

-- INSERT into specific segment (host-0, cpu)
INSERT INTO battle_dml_multi_seg VALUES
('2025-06-01 00:00:00.5', 'host-0', 'cpu', '["core=99","INSERTED-into-host0-cpu"]', 9999);

-- DELETE from different segment by non-flat-dict filter (host-1, mem, by value)
DELETE FROM battle_dml_multi_seg WHERE host = 'host-1' AND metric = 'mem' AND value < 0.1;

-- UPDATE in yet another segment by non-flat-dict filter (host-2, disk, by value)
UPDATE battle_dml_multi_seg
SET tags = '["mount=/updated","MODIFIED"]'
WHERE host = 'host-2' AND metric = 'disk' AND value < 0.5;

-- UPDATE in yet another segment by non-flat-dict filter (host-2, disk, by value)
UPDATE battle_dml_multi_seg
SET tags = '["mount=/updated","MODIFIED"]'
WHERE host = 'host-2' AND metric = 'disk' AND value < 0.5;

-- Verify cross-segment isolation: inserted row visible
SELECT host, metric, tags, value FROM battle_dml_multi_seg WHERE value = 9999;

-- Verify no cross-contamination between segments after DML
SELECT count(*) AS contamination FROM battle_dml_multi_seg
WHERE host = 'host-0' AND metric = 'cpu' AND tags LIKE '%mount=%';

SELECT count(*) AS contamination FROM battle_dml_multi_seg
WHERE host = 'host-1' AND metric = 'mem' AND tags LIKE '%core=%';

-- Re-compress and verify full round-trip via decompress + CTAS + EXCEPT
-- (Decompress first to avoid the partial-chunk ColumnarScan pfree bug)
SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_dml_multi_seg') ch;
CREATE TABLE battle_dml_multi_ref AS SELECT * FROM battle_dml_multi_seg;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_dml_multi_seg') ch;

-- After full recompress, decompress again and compare
SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_dml_multi_seg') ch;

SELECT count(*) AS mismatches FROM (
    (SELECT time, host, metric, tags, value FROM battle_dml_multi_seg
     EXCEPT
     SELECT time, host, metric, tags, value FROM battle_dml_multi_ref)
    UNION ALL
    (SELECT time, host, metric, tags, value FROM battle_dml_multi_ref
     EXCEPT
     SELECT time, host, metric, tags, value FROM battle_dml_multi_seg)
) diff;

DROP TABLE battle_dml_multi_seg CASCADE;
DROP TABLE battle_dml_multi_ref;

--------------------------------------------------------------------------------
-- SCENARIO 3-BUG (FIXED): DML with WHERE on flat_dict column while compressed
--
-- These tests validate the fix for: when a DML statement's WHERE clause
-- references the flat_dictionary column, the partial decompression path
-- must load the dictionary context via a supplementary scan (since the
-- compressed chunk index returns dictionary rows AFTER data rows due to
-- NULL min/max metadata sorting last).
--------------------------------------------------------------------------------

CREATE TABLE battle_dml_bug(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);

INSERT INTO battle_dml_bug
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 3),
       CASE WHEN g % 10 = 0 THEN NULL
            ELSE '["process=test-' || (g % 10) || '"]'
       END,
       g * 0.1
FROM generate_series(1, 300) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('battle_dml_bug') ch;

-- BUG 1 (FIXED): UPDATE with WHERE referencing flat_dict column on compressed chunk
UPDATE battle_dml_bug SET value = -1.0 WHERE tags IS NOT NULL AND device = 'dev-0';
SELECT count(*) AS bug1_updated FROM battle_dml_bug WHERE value = -1.0;

-- BUG 2 (FIXED): DELETE with WHERE referencing flat_dict column on compressed chunk
DELETE FROM battle_dml_bug WHERE tags LIKE '%test-1%';

-- BUG 3 (FIXED): UPDATE SET flat_dict column with WHERE on flat_dict column
UPDATE battle_dml_bug SET tags = '["UPDATED"]' WHERE tags LIKE '%test-2%';
SELECT count(*) AS bug3_updated FROM battle_dml_bug WHERE tags = '["UPDATED"]';

-- Verify the table is intact after DMLs
SELECT count(*) AS total_rows FROM battle_dml_bug;
SELECT count(tags) AS non_null_tags FROM battle_dml_bug;
SELECT device, count(*) AS rows FROM battle_dml_bug GROUP BY device ORDER BY device;

DROP TABLE battle_dml_bug CASCADE;

--------------------------------------------------------------------------------
-- SCENARIO 5: Various Segment Configurations
--
-- Tests flat_dictionary with different segmentby setups:
-- 5a: Single segmentby column (baseline)
-- 5b: 3 segmentby columns (composite key)
-- 5c: Segmentby with NULL values
-- 5d: Segmentby with very long text values
--------------------------------------------------------------------------------

-- 5a: Single segmentby (already covered by scenarios 1-3, quick sanity check)
CREATE TABLE battle_seg1(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_seg1
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 8), '["s1-tag=' || (g % 15) || '"]', g * 0.1
FROM generate_series(1, 800) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_seg1') ch;
SELECT device, count(*), count(tags) AS non_null, count(DISTINCT tags) AS distinct_tags
FROM battle_seg1 GROUP BY device ORDER BY device;
DROP TABLE battle_seg1 CASCADE;

-- 5b: 3 segmentby columns — exercises composite cache key
CREATE TABLE battle_seg3(
    time timestamptz NOT NULL,
    host text NOT NULL,
    region text NOT NULL,
    service text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'host,region,service',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_seg3
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'host-' || (g % 3),
       (CASE g % 4 WHEN 0 THEN 'us-east' WHEN 1 THEN 'eu-west' WHEN 2 THEN 'ap-south' ELSE 'us-west' END),
       'svc-' || (g % 5),
       CASE WHEN g % 30 = 0 THEN NULL ELSE '["env=prod","tier=' || (g % 3) || '"]' END,
       g * 0.1
FROM generate_series(1, 600) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_seg3') ch;

-- Verify per-segment isolation with 3 keys (3×4×5 = 60 segments)
SELECT count(DISTINCT (host, region, service)) AS num_segments FROM battle_seg3;
SELECT host, region, service, count(*) AS rows, count(tags) AS non_null
FROM battle_seg3 GROUP BY host, region, service ORDER BY host, region, service LIMIT 5;

-- Basic read after compress (validates per-segment isolation)
SELECT count(*) AS total FROM battle_seg3;
DROP TABLE battle_seg3 CASCADE;

-- 5c: Segmentby with NULL values
CREATE TABLE battle_seg_null(
    time timestamptz NOT NULL,
    device text,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_seg_null
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       CASE WHEN g % 20 = 0 THEN NULL ELSE 'dev-' || (g % 4) END,
       '["tag=' || (g % 10) || '"]',
       g * 0.1
FROM generate_series(1, 500) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_seg_null') ch;

-- NULL segmentby forms its own segment — must work correctly
SELECT device IS NULL AS is_null_device, count(*), count(DISTINCT tags) AS distinct_tags
FROM battle_seg_null GROUP BY device IS NULL ORDER BY is_null_device;
DROP TABLE battle_seg_null CASCADE;

-- 5d: Segmentby with long text values (tests cache key serialization)
CREATE TABLE battle_seg_long(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_seg_long
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'device-with-a-very-long-name-' || (g % 5) || '-' || repeat('x', 40),
       '["tag=' || (g % 8) || '"]',
       g * 0.1
FROM generate_series(1, 500) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_seg_long') ch;
SELECT left(device, 40) AS device_prefix, count(*), count(DISTINCT tags)
FROM battle_seg_long GROUP BY device ORDER BY device LIMIT 5;
DROP TABLE battle_seg_long CASCADE;

--------------------------------------------------------------------------------
-- SCENARIO 6: Edge Cases bei Kardinalität
--
-- Tests flat_dictionary with extreme cardinality scenarios:
-- 6a: 1 distinct tag per segment (degenerate dictionary)
-- 6b: 255 distinct tags (uint8 max — boundary test)
-- 6c: 256 distinct tags (forces uint16 index width)
-- 6d: All NULL tags (no dictionary row at all)
-- 6e: Mix of segments with and without dictionary in one chunk
--------------------------------------------------------------------------------

-- 6a: Degenerate dictionary (cardinality = 1)
CREATE TABLE battle_card1(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_card1
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 3),
       '["always-the-same-tag"]',
       g * 0.1
FROM generate_series(1, 600) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card1') ch;
SELECT device, count(*), count(DISTINCT tags) AS distinct_tags FROM battle_card1
GROUP BY device ORDER BY device;
DROP TABLE battle_card1 CASCADE;

-- 6b: Exactly 255 distinct tags (uint8 boundary — max for 1-byte index)
CREATE TABLE battle_card255(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_card255
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-0',
       '["distinct-tag-' || (g % 255) || '"]',
       g * 0.1
FROM generate_series(1, 1000) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card255') ch;
SELECT count(*) AS total, count(DISTINCT tags) AS distinct_tags FROM battle_card255;
-- Verify all 255 distinct tags survived round-trip
SELECT count(DISTINCT tags) = 255 AS cardinality_preserved FROM battle_card255;
DROP TABLE battle_card255 CASCADE;

-- 6c: 256 distinct tags (forces uint16 index width)
CREATE TABLE battle_card256(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text NOT NULL,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_card256
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-0',
       '["distinct-tag-' || (g % 256) || '"]',
       g * 0.1
FROM generate_series(1, 1000) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card256') ch;
SELECT count(*) AS total, count(DISTINCT tags) AS distinct_tags FROM battle_card256;
SELECT count(DISTINCT tags) = 256 AS cardinality_preserved FROM battle_card256;

-- Decompress/recompress with uint16 index width
SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_card256') ch;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card256') ch;
SELECT count(DISTINCT tags) = 256 AS still_preserved FROM battle_card256;
DROP TABLE battle_card256 CASCADE;

-- 6d: All NULL tags (no dictionary exists for this segment)
CREATE TABLE battle_card_null(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
INSERT INTO battle_card_null
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 3),
       NULL,
       g * 0.1
FROM generate_series(1, 600) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card_null') ch;
SELECT device, count(*) AS rows, count(tags) AS non_null FROM battle_card_null
GROUP BY device ORDER BY device;
-- All must be NULL
SELECT count(tags) = 0 AS all_null FROM battle_card_null;
DROP TABLE battle_card_null CASCADE;

-- 6e: Mixed segments — some with dictionary, some all-NULL
CREATE TABLE battle_card_mix(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 day',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time',
    tsdb.compress_algorithm = 'tags flat_dictionary'
);
-- dev-0 and dev-1: have tags (dictionary). dev-2: all NULL (no dictionary).
INSERT INTO battle_card_mix
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 3),
       CASE WHEN (g % 3) = 2 THEN NULL
            ELSE '["tag=' || (g % 12) || '"]'
       END,
       g * 0.1
FROM generate_series(1, 900) g;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card_mix') ch;

-- dev-0/1 must have tags, dev-2 must be all NULL
SELECT device, count(*) AS rows, count(tags) AS non_null, count(DISTINCT tags) AS distinct_tags
FROM battle_card_mix GROUP BY device ORDER BY device;

-- Decompress/recompress must preserve the mix
SELECT count(decompress_chunk(ch)) FROM show_chunks('battle_card_mix') ch;
SELECT count(compress_chunk(ch)) FROM show_chunks('battle_card_mix') ch;
SELECT device, count(*) AS rows, count(tags) AS non_null, count(DISTINCT tags) AS distinct_tags
FROM battle_card_mix GROUP BY device ORDER BY device;
DROP TABLE battle_card_mix CASCADE;
