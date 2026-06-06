# Bug: flat_dict decompression cache key is always empty (key_len=0)

## Problem

The per-segment dictionary cache in the ColumnarScan always returns the
FIRST dictionary inserted, regardless of which segment's batch is being
decompressed. This causes `Assert(idx < ctx->num_values)` failures when
segments have different dictionary cardinalities.

## Root Cause (confirmed with diagnostic logging)

`flat_dict_cache_build_key()` returns `key_len=0` for ALL segments because
`cache->num_segmentby_cols == 0`. The cache thinks there are no segmentby
columns.

The chain:
1. `compressed_batch_ensure_flat_dict_cache()` in `compressed_batch.c:967`
   counts segmentby columns by iterating `dcontext->compressed_chunk_columns`
   up to `dcontext->num_data_columns`.
2. Segmentby columns with `custom_scan_attno == 0` are skipped in `exec.c:262`
   during the counting loop that sets `num_data_columns`.
3. Therefore they never appear in `dcontext->compressed_chunk_columns`.
4. Therefore the cache gets `num_segmentby_cols = 0`.
5. Therefore all keys are empty → first insert wins for all lookups.

## Why segmentby columns have custom_scan_attno == 0

In the planner (`planner.c`), `build_decompression_map()` iterates the
compressed scan targetlist. For each column it looks up
`uncompressed_info->custom_scan_attno` — the position in the ColumnarScan
output slot. Segmentby columns that are NOT referenced by the query (e.g.
`SELECT count(tags) FROM ...`) have `custom_scan_attno = 0`
(`InvalidAttrNumber`) because they were never added to the ColumnarScan
output targetlist.

The code in `columnar_scan.c:1851-1867` (`compressed_rel_setup_reltarget`)
correctly forces segmentby columns into the **compressed** scan output. But
it does NOT add them to the **ColumnarScan** output targetlist (the
`custom_scan_tlist`). So they flow through the compressed scan but are
invisible to the executor's decompression context.

## The Fix

File: `tsl/src/nodes/columnar_scan/planner.c`

In `build_decompression_map()` (around line 470-476), after building the
`custom_scan_tlist` entries for query-referenced columns, add segmentby
columns that are needed for flat_dict but not already in the output:

```c
// After the existing custom_scan_tlist loop (line ~476):
if (has_flat_dict && info->settings->fd.segmentby)
{
    // For each segmentby column in the compressed scan output:
    // If its custom_scan_attno is still InvalidAttrNumber (not in output),
    // add it to custom_scan_tlist with the next available attno.
    // This makes it available in the decompressed output slot (hidden from
    // the projection, but visible to the executor for cache key building).
}
```

The key insight: `custom_scan_tlist` determines what the ColumnarScan node
outputs. Even though the user query doesn't need `host` and `metric` in the
result, the executor needs them in the slot so `slot_getattr` works when
building the cache key.

## Files to Modify

1. **`tsl/src/nodes/columnar_scan/planner.c`** — In the function that builds
   `custom_scan_tlist` and `uncompressed_attno_info`, ensure segmentby columns
   get a valid `custom_scan_attno` when flat_dict is active.

2. **`tsl/src/nodes/columnar_scan/exec.c`** — No changes needed if the
   planner fix is correct (segmentby columns will have valid attno and pass
   the `if (output_attno == 0) continue` check naturally).

## How to Verify

```sql
-- This must NOT crash:
SET max_parallel_workers_per_gather = 0;
SELECT count(tags) FROM server_metrics_v2 WHERE metric = 'disk_read_bytes_total'::metric_name;

-- Full table scan must work:
SELECT count(*), count(tags), max(length(tags)) FROM server_metrics_v2;
```

Check with diagnostic:
```sql
SET client_min_messages = DEBUG2;
-- cache_insert and cache_lookup should show key_len > 0 (not 0)
-- Different segments should have different first_bytes
```

## Key Variables to Trace

| Variable | Where | What it should be |
|----------|-------|-------------------|
| `cache->num_segmentby_cols` | `flat_dict_cache_create` | 2 (host + metric) |
| `key_len` in `cache_lookup` | `flat_dict_cache.c:284` | >0 (e.g. 21 for UUID+enum) |
| `uncompressed_info->custom_scan_attno` | `planner.c:525` | >0 for segmentby cols |
| `dcontext->num_data_columns` | `exec.c:280` | includes segmentby cols |

## Test Data Already Available

On port 5433: `server_metrics_v2` with ~900k rows, compressed with flat_dict.
Multiple hosts × metrics = many segments with different dictionary sizes.
`disk_read_bytes_total` has 2 hosts with 17 and 18 distinct tags respectively
— perfect minimal reproducer for the cross-segment dictionary mismatch.

## Existing Fixes Already Committed

- Compression use-after-free (Pass 2 replay): `56054a49c`
- Null-safe decompress_all + cache sentinel: `aac3571c1`
- Diagnostic instrumentation: `4cf0fb1f2`, `ca346cfbf`

After this fix, remove the diagnostic `elog` calls and update the test
expected output.
