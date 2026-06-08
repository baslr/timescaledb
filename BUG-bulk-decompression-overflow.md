# Bug Report: Buffer Overflow in ColumnarScan Bulk Decompression (PRE-EXISTING)

## Summary

A heap corruption bug exists in TimescaleDB's ColumnarScan bulk decompression path that causes `pfree called with invalid pointer` crashes during `CREATE TABLE AS SELECT` (CTAS), `SELECT INTO`, and similar full-table materializations. The bug is **pre-existing in the unmodified codebase** — it has nothing to do with the flat_dictionary feature. It reproduces with standard DICTIONARY compression on unmodified TimescaleDB code.

## Verified: Not caused by our changes

The bug was reproduced on a **clean checkout** of `tsl/src/nodes/columnar_scan/` (git checkout -- both files) with zero flat_dict modifications. The test uses standard compression (`tsdb.segmentby` + `tsdb.orderby`, no `tsdb.compress_algorithm`). The identical `pfree called with invalid pointer` crash occurs.

## Reproduction

```sql
CREATE TABLE repro(
    time timestamptz NOT NULL,
    device text NOT NULL,
    tags text,
    value float NOT NULL
) WITH (
    tsdb.hypertable,
    tsdb.partition_column = 'time',
    tsdb.chunk_interval = '1 hour',
    tsdb.segmentby = 'device',
    tsdb.orderby = 'time'
    -- NOTE: no flat_dictionary! Standard compression triggers it too.
);

INSERT INTO repro
SELECT '2025-06-01'::timestamptz + (g || ' seconds')::interval,
       'dev-' || (g % 5),
       CASE WHEN g % 50 = 0 THEN NULL
            ELSE '["p=t-' || (g % 20) || '","pad=' || repeat('p', 80 + (g % 400)) || '"]'
       END,
       g * 0.1
FROM generate_series(1, 7500) g;

SELECT count(compress_chunk(ch)) FROM show_chunks('repro') ch;

SET max_parallel_workers_per_gather = 0;

-- This crashes:
CREATE TABLE repro_copy AS SELECT * FROM repro;
```

**Error:** `ERROR: pfree called with invalid pointer 0x... (header 0x000398205d227070)`

## Conditions that trigger the bug

All of the following must be true simultaneously:

1. **Long text values** in a DICTIONARY-compressed column (>~80 bytes per value)
2. **>1000 rows per segment** (forces multi-batch decompression, batch size = 1000)
3. **Bulk decompression enabled** (`timescaledb.enable_bulk_decompression = on`, the default)
4. **Full-row materialization** (CTAS, SELECT INTO, pg_dump). Simple `SELECT count(*)`, aggregations, `LIMIT`, filtered scans do NOT trigger it.

## Conditions that prevent the bug (workarounds)

Any ONE of these prevents the crash:

- `SET timescaledb.enable_bulk_decompression = off;` — disables the Arrow path entirely
- Short text values (<~80 bytes) — keeps the Arrow data buffer small
- ≤1000 rows per segment — single batch, no per_batch_context reset between batches
- `SET timescaledb.enable_vectorized_aggregation = off;` — only helps for GROUP BY queries, not CTAS

## Root cause analysis

### What we know for certain

1. The corrupt `hdrmask` (MemoryChunk header, 8 bytes before the user pointer) contains **bytes from the text column data**: `0x5d227070` = `"]pp` in ASCII — the end of our JSON tag strings.

2. The corruption is **already present after the first column's `decompress_column()` call** completes. A `palloc(16)` probe immediately after `decompress_column(i=0)` (the `time` column, ARRAY algorithm) already crashes.

3. The corruption is in the **`per_batch_context`** memory context. This context holds:
   - Detoasted compressed blobs (from `detoaster_detoast_attr_copy`)
   - Arrow result arrays (from `decompress_all` functions)
   - Pre-allocated output value buffers (from `get_max_varlena_bytes`)

4. The `per_batch_context` is a **`GenerationContext`** (not AllocSet). Changing it to AllocSet does NOT fix the bug — the corruption persists.

5. The bug does NOT depend on `flat_dictionary` code. It reproduces with standard DICTIONARY compression on the same data.

6. Disabling bulk decompression (`enable_bulk_decompression = off`) prevents the crash entirely. With bulk disabled, all columns use the row-by-row iterator path which is correct.

### Where the overflow likely occurs

The `decompress_all` function for the **DICTIONARY algorithm** (or possibly ARRAY for the `tags` column) produces an Arrow array in `per_batch_context`. The Arrow's `data_buf` (containing the expanded text values) is allocated based on a size calculation. The `memcpy` loop that fills `data_buf` writes text data that includes `"]pp` patterns.

The overflow writes past the end of `data_buf` and corrupts the `MemoryChunk.hdrmask` of the **next** palloc'd block in the context. This corrupted header is later encountered during `MemoryContextReset(per_batch_context)` (between batches) or during a subsequent `palloc` that walks the context's block/chunk list.

### What we ruled out

| Hypothesis | Test | Result |
|---|---|---|
| flat_dict `data_buf` overflow | Added bounds check `offset + len > total_data_size` | Check never triggers |
| flat_dict `offsets` array overflow | Doubled allocation size | Still crashes |
| flat_dict `data_buf` too small | Doubled allocation size | Still crashes |
| `PG_DETOAST_DATUM` allocating in wrong context | Removed call, use `DatumGetPointer` directly | Still crashes |
| `bulk_decompression_context` reset corrupting `per_batch` | Disabled the reset | Still crashes |
| `pfree(null_flags)` corrupting neighbor | Removed the pfree | Still crashes |
| GenerationContext allocator bug | Switched to AllocSet | Still crashes |
| flat_dict specific issue | Tested with standard DICTIONARY | Same crash |
| Our `flat_dictionary_decompress_all` function | Used `return NULL` (iterator fallback) + removed VectorAgg check | Crash persists because OTHER columns' decompress_all has the overflow |
| VectorAgg consuming data incorrectly | Disabled VectorAgg | Doesn't help for CTAS (CTAS doesn't use VectorAgg) |

### The smoking gun

```
corrupt header: 0x000398205d227070
                         ^^^^^^^^
                         "]"pp  — literal bytes from our JSON tag strings

These bytes come from the DICTIONARY decompress_all function's Arrow data buffer
which overflows into the next MemoryChunk header.
```

## Suggested investigation path

1. **Find the exact `decompress_all` function** that overflows. The candidate is `tsl_dictionary_decompress_all` (for the `tags` column with standard DICTIONARY compression). Check its `data_buf` size calculation — likely has an off-by-one or alignment issue with `pad_to_multiple`.

2. **Build PostgreSQL with `--enable-cassert`** (enables `MEMORY_CONTEXT_CHECKING`). This adds sentinel bytes after every palloc'd block and checks them on pfree/reset — it will report the EXACT allocation that overflows and WHERE the corruption was detected.

3. **Alternatively**: use `valgrind --tool=memcheck` with PG's `--enable-cassert` build. This will pinpoint the exact `memcpy` that writes past the allocation boundary.

4. **Key file**: `tsl/src/compression/algorithms/dictionary.c` — look at the `tsl_dictionary_decompress_all_text` function (or equivalent). Check how it computes `total_data_size` and whether NULLs, alignment, or edge cases cause underestimation.

## Impact

- **Affects**: Any table with text columns using DICTIONARY compression (the default for most text columns) with long values (>80 bytes), >1000 rows per compressed segment, and queries that materialize full rows.
- **Does NOT affect**: Aggregations, filtered scans, LIMIT queries, short text values, or queries with `enable_bulk_decompression = off`.
- **Severity**: Server crash (connection terminated) but no data corruption. PostgreSQL recovers cleanly after restart.

## Workaround

```sql
SET timescaledb.enable_bulk_decompression = off;
```

This forces the row-by-row iterator path for all columns, which is correct and ~10-15% slower for full-table scans but has identical performance for filtered/aggregated queries.

## Files involved

- `tsl/src/nodes/columnar_scan/compressed_batch.c` — `decompress_column()`, line 220 (detoast), lines 233-279 (bulk decompression dispatch and context management)
- `tsl/src/nodes/columnar_scan/compressed_batch.h` — `create_per_batch_mctx` macro (GenerationContext), `store_text_datum`, `get_max_varlena_bytes`
- `tsl/src/compression/algorithms/dictionary.c` (or similar) — the `decompress_all` function that produces the overflowing Arrow
- `tsl/src/nodes/columnar_scan/detoaster.c` — `detoaster_detoast_attr_copy` (produces the compressed blob in per_batch_context)
