/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */
#ifndef TIMESCALEDB_DECOMPRESS_CONTEXT_H
#define TIMESCALEDB_DECOMPRESS_CONTEXT_H

#include <postgres.h>
#include <access/attnum.h>
#include <executor/tuptable.h>
#include <nodes/execnodes.h>
#include <nodes/pg_list.h>

#include "batch_array.h"
#include "detoaster.h"

typedef enum CompressionColumnType
{
	SEGMENTBY_COLUMN,
	COMPRESSED_COLUMN,
	COUNT_COLUMN,
	SEQUENCE_NUM_COLUMN,
} CompressionColumnType;

typedef struct CompressionColumnDescription
{
	CompressionColumnType type;
	Oid typid;
	int16 value_bytes;
	bool by_value;

	/*
	 * Attno of the decompressed column in the scan tuple of ColumnarScan node.
	 * Negative values are special columns that do not have a representation in
	 * the decompressed chunk, but are still used for decompression. The `type`
	 * field is set accordingly for these columns.
	 */
	AttrNumber custom_scan_attno;

	/*
	 * Attno of this column in the uncompressed chunks. We use it to fetch the
	 * default value from the uncompressed chunk tuple descriptor.
	 */
	AttrNumber uncompressed_chunk_attno;

	/*
	 * Attno of the compressed column in the input compressed chunk scan.
	 */
	AttrNumber compressed_scan_attno;

	bool bulk_decompression_supported;
} CompressionColumnDescription;

typedef struct DecompressContext
{
	/*
	 * Note that this array contains only those columns that are decompressed
	 * (output_attno != 0), and the order is different from the compressed chunk
	 * tuple order: first go the actual data columns, and after that the metadata
	 * columns.
	 */
	CompressionColumnDescription *compressed_chunk_columns;

	/*
	 * This includes all decompressed columns (output_attno != 0), including the
	 * metadata columns.
	 */
	int num_columns_with_metadata;

	/* This excludes the metadata columns. */
	int num_data_columns;

	List *vectorized_quals_constified;
	bool reverse;
	bool batch_sorted_merge; /* Batch sorted merge optimization enabled. */
	bool enable_bulk_decompression;

	/*
	 * Scratch space for bulk decompression which might need a lot of temporary
	 * data.
	 */
	MemoryContext bulk_decompression_context;

	TupleTableSlot *custom_scan_slot;

	/*
	 * The scan tuple descriptor might be different from the uncompressed chunk
	 * one, and it doesn't have the default column values in that case, so we
	 * have to fetch the default values from the uncompressed chunk tuple
	 * descriptor which we store here.
	 */
	TupleDesc uncompressed_chunk_tdesc;

	PlanState *ps; /* Set for filtering and instrumentation */

	Detoaster detoaster;

	int32 chunk_status;

	/*
	 * Per-segment flat_dictionary cache for this scan. Maps a segment (keyed by
	 * its serialized segmentby values) to its FlatDictionaryContext, so that any
	 * number of segment dictionaries can be active at once. This is what allows
	 * reverse scans, batch sorted merge and compressed sort pushdown for
	 * flat_dictionary tables: those read modes reorder the dictionary rows
	 * relative to their data batches (or interleave batches from several
	 * segments), so a single active dictionary is not enough.
	 *
	 * Forward, non-reordered scans fill the cache on the fly as they encounter
	 * each segment's dictionary row (count == 0). The reordered read modes may
	 * reach a data batch before its dictionary row; the first such miss triggers
	 * a one-shot prefetch (flat_dict_cache_prefetch) that scans the compressed
	 * chunk and loads every dictionary row into the cache, after which all
	 * lookups hit. NULL until the first flat_dictionary column is seen.
	 *
	 * Allocated in a scan-lifetime context so it (and every dictionary in it)
	 * survives the per-batch context resets.
	 */
	struct FlatDictCache *flat_dict_cache;

	/*
	 * Oid of the uncompressed chunk relation for this scan. Used to locate the
	 * compressed chunk for the one-shot dictionary prefetch above. Set at exec
	 * init time. InvalidOid if not applicable.
	 */
	Oid chunk_relid;

	/*
	 * Oid of the compressed chunk relation's table. Stored here so the
	 * flat_dict prefetch can open it directly without catalog lookups that
	 * would require a transaction ID (forbidden in parallel workers).
	 */
	Oid compressed_rel_id;

	/*
	 * True if this scan's table has at least one flat_dictionary column. Set at
	 * exec init from the compression settings. Gates the per-batch dictionary
	 * resolution so non-flat_dictionary scans pay nothing.
	 */
	bool has_flat_dict_columns;

} DecompressContext;

#endif /* TIMESCALEDB_DECOMPRESS_CONTEXT_H */
