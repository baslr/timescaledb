# RFC: Shared Flat Dictionary Compression Algorithm

## Problem

The current `DICTIONARY` algorithm builds a per-batch dictionary. With the default
batch size of 1000 rows and high-cardinality TEXT columns (~2000-4000 unique values),
the dictionary has as many entries as rows → no compression gain.

The theoretical compression potential for a column with 3706 unique strings across
4.6M rows is 92:1, but the per-batch architecture limits it to ~10:1.

## Proposal

New compression algorithm: `COMPRESSION_ALGORITHM_FLAT_DICTIONARY`

A **shared dictionary per segment** with raw fixed-width index arrays per batch.

### SQL Interface

```sql
ALTER TABLE server_metrics_v2 SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'host',
    timescaledb.compress_orderby = 'timestamp',
    timescaledb.compress_algorithm = 'tags flat_dictionary'
);
```

New option `compress_algorithm` takes `'column_name algorithm_name'` pairs
(space-separated, comma-separated for multiple columns).

### Storage Layout

```
Compressed table for one segment (host='abc'):

Row 0:  _ts_meta_count = 0  (marker: this is a dictionary row)
        tags = [ArrayCompressed blob of all unique values]
        other columns = NULL

Row 1:  _ts_meta_count = 1000
        tags = int32[] raw (1000 dictionary indexes)
        timestamp = DeltaDelta(1000 values)
        ...

Row 2:  _ts_meta_count = 1000
        tags = int32[] raw (1000 dictionary indexes)
        ...
```

The dictionary row is identified by `_ts_meta_count = 0`.

### Index Width

- <= 255 unique values: uint8 (1 byte per row)
- <= 65535 unique values: uint16 (2 bytes per row)  
- <= 2^31 unique values: int32 (4 bytes per row)

Selected once during Pass 1 based on actual cardinality.

### Compression Flow (Two-Pass)

```
Pass 1: Sequential scan of all rows in segment
        → Build hash table: value → index
        → Count unique values → determine index width
        → Serialize dictionary as ArrayCompressed blob
        → Write dictionary row (Row 0)

Pass 2: Same as current compression, but for flat_dictionary columns:
        → Look up value in hash table → get index
        → Append index to raw array (no simple8b, no RLE)
        → Flush batch: write raw index array as bytea
```

### Decompression Flow

```
1. When segment is first accessed, read Row 0 → deserialize dictionary
2. Cache dictionary in memory (per-segment, lifetime of query)
3. For each batch row: read raw index array → O(1) lookup by position
4. Return dictionary[index] for each row
```

### On-Disk Format: Flat Dictionary Batch

```
FlatDictionaryCompressed {
    CompressedDataHeaderFields;     // vl_len + algorithm byte
    uint8   index_width;            // 1, 2, or 4 bytes
    uint8   padding[5];
    uint16  num_elements;           // rows in this batch
    char    data[FLEXIBLE_ARRAY_MEMBER];  // raw indexes
}
```

Total size per batch: header(16) + num_elements * index_width
Example: 1000 rows × 2 bytes = 2016 bytes per batch for tags column.

### On-Disk Format: Dictionary Row

Reuses existing `ArrayCompressed` format for the dictionary values.
Other columns are NULL. `_ts_meta_count = 0` marks it as dictionary row.

### Changes Required

1. **`compression.h`**: Add `COMPRESSION_ALGORITHM_FLAT_DICTIONARY = 8`

2. **`algorithms/flat_dictionary.c`** (new file):
   - `flat_dictionary_compressor_alloc()`
   - `flat_dictionary_compressor_append()`
   - `flat_dictionary_compressor_finish()` → returns raw index array
   - `flat_dictionary_decompress_all()` → needs dictionary reference
   - `flat_dictionary_decompression_iterator_init()`

3. **`compression.c`**:
   - Register in `definitions[]` array
   - `compressor_for_column()` function (checks per-column algorithm override)
   - Modify `row_compressor_init()` to accept algorithm overrides
   - Two-pass mode: if any column uses flat_dictionary, do Pass 1 first

4. **`alter_table_with_clause.h`**: Add `AlterTableFlagAlgorithm`

5. **`alter_table_with_clause.c`**: Parse `compress_algorithm` option

6. **`compression_settings.h/.c`**: Store per-column algorithm in catalog
   - New field in CompressionSettings or new catalog table
   - Maps column_name → algorithm_id

7. **`create.c`**: When creating compressed chunk table, handle flat_dictionary
   columns (dictionary row concept)

8. **Decompression path** (`compression_dml.c`):
   - Detect dictionary row (count=0) when scanning compressed table
   - Cache dictionary per segment
   - Pass dictionary reference to flat_dictionary decompressor

### Advantages

- Shared dictionary across all batches in a segment
- O(1) random access within a batch (no sequential decode)
- Adaptive index width (1/2/4 bytes based on cardinality)
- For the motivating use case: 3706 unique tags × 200 bytes avg = 741 KB dictionary
  + 4.6M × 2 bytes = 9.2 MB indexes = ~10 MB total vs 924 MB raw = **92:1**

### Limitations

- Two-pass compression is slower (reads data twice)
- Dictionary row adds complexity to decompression path
- Not suitable for columns where every value is unique (worse than array)
- Segment must fit in memory during Pass 1 (hash table of unique values)

### Backward Compatibility

- New algorithm ID (8) means old TimescaleDB versions cannot read chunks
  compressed with flat_dictionary
- Existing chunks are unaffected
- Can coexist with other algorithms on different columns of same table
