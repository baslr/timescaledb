
/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */

/*
 * Flat Dictionary Compression Algorithm
 *
 * A shared-dictionary-per-segment approach with raw fixed-width index arrays
 * per batch. Unlike the standard DICTIONARY algorithm which builds a dictionary
 * per batch (inefficient for high-cardinality columns), this stores ONE dictionary
 * for the entire segment and each batch is just a raw array of indexes into it.
 *
 * Compression ratio example:
 *   3706 unique tags * ~200 bytes avg = 741 KB dictionary (stored once)
 *   4.6M rows * 2 bytes index = 9.2 MB
 *   Total ~10 MB vs 924 MB raw = 92:1 compression
 */
#include <postgres.h>
#include <access/htup_details.h>
#include <catalog/pg_type.h>
#include <lib/stringinfo.h>
#include <utils/builtins.h>
#include <utils/datum.h>
#include <utils/lsyscache.h>
#include <utils/typcache.h>
#include <utils/memutils.h>

#include "compression/compression.h"
#include "compression/arrow_c_data_interface.h"
#include "flat_dictionary.h"
#include "array.h"
#include "guc.h"
#include "simple8b_rle.h"
#include "simple8b_rle_bitmap.h"

/*
 * Flat dictionary decompression takes its segment dictionary as an explicit
 * argument threaded from the decompression session object (RowDecompressor for
 * the bulk path, DecompressContext for the columnar scan). There is no ambient
 * or per-backend context, so concurrent scans — and the dictionary blob's own
 * nested ARRAY decompression — never collide.
 */

/*
 * Build a FlatDictionaryContext from an already-detoasted ArrayCompressed blob.
 *
 * Used by every decompression path (bulk decompress_chunk and the columnar
 * scan) so the Arrow->Datum materialization lives in exactly one place. All
 * allocations land in dest_mctx, which the caller must keep alive for as long
 * as any batch references the dictionary.
 */
FlatDictionaryContext *
flat_dictionary_context_from_array_blob(Datum array_blob, Oid element_type, MemoryContext dest_mctx)
{
	MemoryContext old_ctx = MemoryContextSwitchTo(dest_mctx);

	int16 typlen;
	bool typbyval;
	get_typlenbyval(element_type, &typlen, &typbyval);

	uint32 num_values;
	Datum *values;

	/*
	 * Prefer the bulk decompress_all path (TEXT/BOOL/UUID). It returns an
	 * ArrowArray whose buffers we copy into standalone Datums so they survive
	 * independently of the (possibly short-lived) Arrow allocation.
	 */
	DecompressAllFunction decompress_all_fn =
		tsl_get_decompress_all_function(COMPRESSION_ALGORITHM_ARRAY, element_type);

	if (decompress_all_fn != NULL)
	{
		ArrowArray *dict_arrow = decompress_all_fn(array_blob, element_type, dest_mctx);

		num_values = dict_arrow->length;
		values = palloc(sizeof(Datum) * num_values);

		if (typlen == -1)
		{
			/* Variable-length type (TEXT, BYTEA, ...) */
			const uint32 *offsets = (const uint32 *) dict_arrow->buffers[1];
			const char *data = (const char *) dict_arrow->buffers[2];

			for (uint32 i = 0; i < num_values; i++)
			{
				uint32 start = offsets[i];
				uint32 len = offsets[i + 1] - start;
				text *t = (text *) palloc(VARHDRSZ + len);
				SET_VARSIZE(t, VARHDRSZ + len);
				memcpy(VARDATA(t), data + start, len);
				values[i] = PointerGetDatum(t);
			}
		}
		else
		{
			/* Fixed-length type */
			const char *data = (const char *) dict_arrow->buffers[1];
			for (uint32 i = 0; i < num_values; i++)
			{
				if (typbyval)
					values[i] = fetch_att(data + (i * typlen), typbyval, typlen);
				else
				{
					/* Copy out of the Arrow buffer so it owns its memory. */
					char *copy = palloc(typlen);
					memcpy(copy, data + (i * typlen), typlen);
					values[i] = PointerGetDatum(copy);
				}
			}
		}
	}
	else
	{
		/* Fallback: iterator-based decompression, two passes (count, collect). */
		DecompressionIterator *iter =
			tsl_array_decompression_iterator_from_datum_forward(array_blob, element_type);

		uint32 count = 0;
		DecompressResult res;
		while (true)
		{
			res = iter->try_next(iter);
			if (res.is_done)
				break;
			if (!res.is_null)
				count++;
		}

		values = palloc(sizeof(Datum) * count);
		iter = tsl_array_decompression_iterator_from_datum_forward(array_blob, element_type);
		uint32 idx = 0;
		while (true)
		{
			res = iter->try_next(iter);
			if (res.is_done)
				break;
			if (!res.is_null)
				values[idx++] = datumCopy(res.val, typbyval, typlen);
		}
		num_values = count;
	}

	FlatDictionaryContext *ctx = palloc(sizeof(FlatDictionaryContext));
	ctx->values = values;
	ctx->num_values = num_values;
	ctx->element_type = element_type;
	ctx->typlen = typlen;
	ctx->typbyval = typbyval;

	MemoryContextSwitchTo(old_ctx);
	return ctx;
}

bool
flat_dictionary_compressed_has_nulls(const CompressedDataHeader *header)
{
	const FlatDictionaryCompressed *fc = (const FlatDictionaryCompressed *) header;
	return fc->has_nulls;
}

static void
pg_attribute_unused() flat_dict_assertions(void)
{
	FlatDictionaryCompressed test_val;
	/* Ensure no unexpected padding on disk */
	StaticAssertStmt(sizeof(FlatDictionaryCompressed) ==
						 sizeof(test_val.vl_len_) +
							 sizeof(test_val.compression_algorithm) +
							 sizeof(test_val.has_nulls) +
							 sizeof(test_val.index_width) +
							 sizeof(test_val.padding) +
							 sizeof(test_val.element_type) +
							 sizeof(test_val.num_elements) +
							 sizeof(test_val.trailing_pad),
					 "FlatDictionaryCompressed wrong size");
	StaticAssertStmt(sizeof(FlatDictionaryCompressed) == 16,
					 "FlatDictionaryCompressed wrong size");
}

//////////////////
/// Compressor ///
//////////////////

/*
 * The compressor for flat_dictionary batches. During compression, the
 * segment-level dictionary has already been built (Pass 1). This compressor
 * simply collects indexes and writes them as a raw array.
 *
 * The dictionary builder is linked to the compressor via
 * flat_dictionary_compressor_set_builder() before Pass 2 begins, and the
 * driver resolves each value to its index before calling append.
 */

typedef struct FlatDictionaryBatchCompressor
{
	uint32 *indexes;       /* collected indexes for this batch */
	bool *nulls;           /* null bitmap */
	uint16 num_elements;
	uint16 capacity;
	uint32 num_nulls;
	uint8 index_width;     /* determined from dictionary cardinality */
	Oid element_type;
} FlatDictionaryBatchCompressor;

typedef struct FlatDictExtendedCompressor
{
	Compressor base;
	FlatDictionaryBatchCompressor *internal;
	Oid element_type;
	/* Back-pointer to the builder for this column (set during two-pass).
	 * Used at finish() time to determine optimal index width. */
	FlatDictionaryBuilder *builder;
} FlatDictExtendedCompressor;

static FlatDictionaryBatchCompressor *
flat_dictionary_batch_compressor_alloc(Oid type, uint8 index_width)
{
	FlatDictionaryBatchCompressor *comp = palloc0(sizeof(FlatDictionaryBatchCompressor));
	comp->capacity = 1024;
	comp->indexes = palloc(sizeof(uint32) * comp->capacity);
	comp->nulls = palloc0(sizeof(bool) * comp->capacity);
	comp->num_elements = 0;
	comp->num_nulls = 0;
	comp->index_width = index_width;
	comp->element_type = type;
	return comp;
}

static void
flat_dictionary_batch_compressor_ensure_capacity(FlatDictionaryBatchCompressor *comp)
{
	if (comp->num_elements >= comp->capacity)
	{
		comp->capacity *= 2;
		comp->indexes = repalloc(comp->indexes, sizeof(uint32) * comp->capacity);
		comp->nulls = repalloc(comp->nulls, sizeof(bool) * comp->capacity);
	}
}

/*
 * Append a dictionary index directly (the caller has already resolved
 * the value to its dictionary index during Pass 2).
 */
static void
flat_dictionary_batch_append_index(FlatDictionaryBatchCompressor *comp, uint32 index)
{
	flat_dictionary_batch_compressor_ensure_capacity(comp);
	comp->indexes[comp->num_elements] = index;
	comp->nulls[comp->num_elements] = false;
	comp->num_elements++;
}

static void
flat_dictionary_batch_append_null(FlatDictionaryBatchCompressor *comp)
{
	flat_dictionary_batch_compressor_ensure_capacity(comp);
	comp->indexes[comp->num_elements] = 0;
	comp->nulls[comp->num_elements] = true;
	comp->num_elements++;
	comp->num_nulls++;
}

/*
 * Serialize the batch into a FlatDictionaryCompressed blob.
 * Layout: header (16 bytes) + raw index data + optional nulls bitmap
 */
static void *
flat_dictionary_batch_finish(FlatDictionaryBatchCompressor *comp)
{
	/*
	 * num_elements is stored as a uint16 on disk; the batch must never exceed
	 * the global per-batch row cap. flat_dict_compressor_is_full enforces this
	 * during collection — this is a hard backstop against any path that skips
	 * the fullness check.
	 */
	if (comp->num_elements > GLOBAL_MAX_ROWS_PER_COMPRESSION)
		elog(ERROR,
			 "flat_dictionary: batch of %u rows exceeds the maximum of %d",
			 comp->num_elements,
			 GLOBAL_MAX_ROWS_PER_COMPRESSION);

	bool has_nulls = (comp->num_nulls > 0);
	Size data_size = (Size) comp->num_elements * comp->index_width;
	Simple8bRleSerialized *nulls_serialized = NULL;
	Size nulls_size = 0;

	if (has_nulls)
	{
		Simple8bRleCompressor nulls_comp;
		simple8brle_compressor_init(&nulls_comp);
		for (uint16 i = 0; i < comp->num_elements; i++)
			simple8brle_compressor_append(&nulls_comp, comp->nulls[i] ? 1 : 0);
		nulls_serialized = simple8brle_compressor_finish(&nulls_comp);
		nulls_size = simple8brle_serialized_total_size(nulls_serialized);
	}

	Size total_size = sizeof(FlatDictionaryCompressed) + data_size + nulls_size;
	/* Align to 8 bytes */
	total_size = MAXALIGN(total_size);

	FlatDictionaryCompressed *compressed = palloc0(total_size);
	SET_VARSIZE(compressed, total_size);
	compressed->compression_algorithm = COMPRESSION_ALGORITHM_FLAT_DICTIONARY;
	compressed->has_nulls = has_nulls ? 1 : 0;
	compressed->index_width = comp->index_width;
	compressed->element_type = comp->element_type;
	compressed->num_elements = comp->num_elements;

	/* Write raw index data after header */
	char *dest = (char *) compressed + sizeof(FlatDictionaryCompressed);

	switch (comp->index_width)
	{
		case FLAT_DICT_WIDTH_8:
			for (uint16 i = 0; i < comp->num_elements; i++)
				((uint8 *) dest)[i] = (uint8) comp->indexes[i];
			break;
		case FLAT_DICT_WIDTH_16:
			for (uint16 i = 0; i < comp->num_elements; i++)
				((uint16 *) dest)[i] = (uint16) comp->indexes[i];
			break;
		case FLAT_DICT_WIDTH_32:
			for (uint16 i = 0; i < comp->num_elements; i++)
				((uint32 *) dest)[i] = comp->indexes[i];
			break;
		default:
			elog(ERROR, "flat_dictionary: invalid index_width %d", comp->index_width);
	}

	/* Append nulls bitmap if needed */
	if (has_nulls && nulls_serialized)
	{
		char *nulls_dest = dest + data_size;
		memcpy(nulls_dest, nulls_serialized, nulls_size);
	}

	return compressed;
}

/////////////////////////////
/// Compressor Interface  ///
/////////////////////////////

/*
 * Note: The standard Compressor interface expects append_val(Datum).
 * For flat_dictionary, the caller must have resolved the Datum to a
 * dictionary index BEFORE calling append. We store the index in the
 * Datum (as an integer). This works because during Pass 2, the
 * compression driver looks up the value in the segment dictionary
 * and passes the index as a Datum.
 *
 * Alternative: We could do the lookup here, but that couples the
 * compressor to the dictionary hash. Keeping it outside is cleaner.
 */

static void
flat_dict_compressor_append_val(Compressor *compressor, Datum val)
{
	FlatDictExtendedCompressor *ext = (FlatDictExtendedCompressor *) compressor;
	if (ext->internal == NULL)
	{
		/* Use width_32 as placeholder — actual width determined at finish() time
		 * from the final dictionary cardinality. Indexes are stored as uint32
		 * internally regardless. */
		ext->internal = flat_dictionary_batch_compressor_alloc(ext->element_type, FLAT_DICT_WIDTH_32);
	}
	flat_dictionary_batch_append_index(ext->internal, DatumGetUInt32(val));
}

static void
flat_dict_compressor_append_null(Compressor *compressor)
{
	FlatDictExtendedCompressor *ext = (FlatDictExtendedCompressor *) compressor;
	if (ext->internal == NULL)
	{
		ext->internal = flat_dictionary_batch_compressor_alloc(ext->element_type, FLAT_DICT_WIDTH_32);
	}
	flat_dictionary_batch_append_null(ext->internal);
}

static bool
flat_dict_compressor_is_full(Compressor *compressor, Datum val)
{
	FlatDictExtendedCompressor *ext = (FlatDictExtendedCompressor *) compressor;
	(void) val;
	if (ext->internal == NULL)
		return false;
	/*
	 * num_elements is a uint16 on disk. Force a flush before it can reach the
	 * global per-batch row cap so it can never overflow / silently truncate,
	 * even if the row compressor's own count limit is disabled or raised.
	 */
	return ext->internal->num_elements >= GLOBAL_MAX_ROWS_PER_COMPRESSION;
}

static void *
flat_dict_compressor_finish(Compressor *compressor)
{
	FlatDictExtendedCompressor *ext = (FlatDictExtendedCompressor *) compressor;
	if (ext->internal == NULL)
		return NULL;

	/*
	 * Determine optimal index width from the dictionary cardinality. The
	 * builder is always linked on the real two-pass compression path
	 * (row_compressor_init), so its cardinality is authoritative.
	 */
	uint32 num_values = 0;
	if (ext->builder != NULL)
	{
		num_values = flat_dictionary_builder_num_values(ext->builder);
	}

	if (num_values > 0)
	{
		if (num_values <= 255)
			ext->internal->index_width = FLAT_DICT_WIDTH_8;
		else if (num_values <= 65535)
			ext->internal->index_width = FLAT_DICT_WIDTH_16;
		else
			ext->internal->index_width = FLAT_DICT_WIDTH_32;
	}

	/* Validate: no index should exceed the dictionary cardinality */
	if (num_values > 0)
	{
		for (uint32 i = 0; i < ext->internal->num_elements; i++)
		{
			if (ext->internal->indexes[i] >= num_values)
				elog(ERROR, "flat_dict_compressor_finish: index[%u]=%u >= num_values=%u (total_elements=%u, width=%u)",
					 i, ext->internal->indexes[i], num_values,
					 ext->internal->num_elements, ext->internal->index_width);
		}
	}

	void *result = flat_dictionary_batch_finish(ext->internal);
	pfree(ext->internal->indexes);
	pfree(ext->internal->nulls);
	pfree(ext->internal);
	ext->internal = NULL;
	return result;
}

static const Compressor flat_dictionary_compressor_vtable = {
	.append_val = flat_dict_compressor_append_val,
	.append_null = flat_dict_compressor_append_null,
	.is_full = flat_dict_compressor_is_full,
	.finish = flat_dict_compressor_finish,
};

Compressor *
flat_dictionary_compressor_for_type(Oid element_type)
{
	FlatDictExtendedCompressor *compressor = palloc(sizeof(*compressor));
	*compressor = (FlatDictExtendedCompressor){
		.base = flat_dictionary_compressor_vtable,
		.element_type = element_type,
		.builder = NULL,
	};
	return &compressor->base;
}

/*
 * Set the builder back-pointer on a flat_dictionary compressor.
 * Called during row_compressor_init so that finish() can determine
 * the optimal index width from the builder's cardinality.
 */
void
flat_dictionary_compressor_set_builder(Compressor *compressor, FlatDictionaryBuilder *builder)
{
	FlatDictExtendedCompressor *ext = (FlatDictExtendedCompressor *) compressor;
	ext->builder = builder;
}

//////////////////////
/// Decompression  ///
//////////////////////

typedef struct FlatDictionaryDecompressionIterator
{
	DecompressionIterator base;
	const FlatDictionaryCompressed *compressed;
	FlatDictionaryContext *dict_ctx;
	const char *index_data;
	uint16 current_pos;
	/* nulls */
	bool has_nulls;
	Simple8bRleDecompressionIterator nulls_iter;
} FlatDictionaryDecompressionIterator;

static inline uint32
flat_dict_read_index(const char *data, uint8 width, uint16 pos)
{
	switch (width)
	{
		case FLAT_DICT_WIDTH_8:
			return ((const uint8 *) data)[pos];
		case FLAT_DICT_WIDTH_16:
			return ((const uint16 *) data)[pos];
		case FLAT_DICT_WIDTH_32:
			return ((const uint32 *) data)[pos];
		default:
			elog(ERROR, "flat_dictionary: invalid index_width %d", width);
			return 0; /* unreachable */
	}
}

DecompressionIterator *
tsl_flat_dictionary_decompression_iterator_from_datum_forward(Datum compressed_data,
                                                              Oid element_type,
                                                              FlatDictionaryContext *ctx)
{
	if (ctx == NULL)
		elog(ERROR, "flat_dictionary: no dictionary context provided for decompression");

	const FlatDictionaryCompressed *header =
		(const FlatDictionaryCompressed *) PG_DETOAST_DATUM(compressed_data);

	Assert(header->compression_algorithm == COMPRESSION_ALGORITHM_FLAT_DICTIONARY);

	FlatDictionaryDecompressionIterator *iter = palloc(sizeof(*iter));
	iter->base.compression_algorithm = COMPRESSION_ALGORITHM_FLAT_DICTIONARY;
	iter->base.forward = true;
	iter->base.element_type = element_type;
	iter->base.try_next = flat_dictionary_decompression_iterator_try_next_forward;

	iter->compressed = header;
	iter->dict_ctx = ctx;
	iter->index_data = (const char *) header + sizeof(FlatDictionaryCompressed);
	iter->current_pos = 0;
	iter->has_nulls = header->has_nulls;

	if (iter->has_nulls)
	{
		Size data_size = (Size) header->num_elements * header->index_width;
		const char *nulls_data = iter->index_data + data_size;
		StringInfoData si;
		si.data = (char *) nulls_data;
		si.len = VARSIZE(header) - sizeof(FlatDictionaryCompressed) - data_size;
		si.cursor = 0;
		si.maxlen = si.len;
		Simple8bRleSerialized *nulls_serialized = bytes_deserialize_simple8b_and_advance(&si);
		simple8brle_decompression_iterator_init_forward(&iter->nulls_iter, nulls_serialized);
	}

	return &iter->base;
}

DecompressResult
flat_dictionary_decompression_iterator_try_next_forward(DecompressionIterator *base_iter)
{
	FlatDictionaryDecompressionIterator *iter =
		(FlatDictionaryDecompressionIterator *) base_iter;

	if (iter->current_pos >= iter->compressed->num_elements)
		return (DecompressResult){ .is_done = true };

	if (iter->has_nulls)
	{
		Simple8bRleDecompressResult null_result =
			simple8brle_decompression_iterator_try_next_forward(&iter->nulls_iter);
		if (null_result.val == 1)
		{
			iter->current_pos++;
			return (DecompressResult){ .is_null = true };
		}
	}

	uint32 index = flat_dict_read_index(iter->index_data,
										iter->compressed->index_width,
										iter->current_pos);
	iter->current_pos++;

	Assert(index < iter->dict_ctx->num_values);
	Datum val = iter->dict_ctx->values[index];

	return (DecompressResult){ .val = val };
}

DecompressionIterator *
tsl_flat_dictionary_decompression_iterator_from_datum_reverse(Datum compressed_data,
                                                              Oid element_type,
                                                              FlatDictionaryContext *ctx)
{
	if (ctx == NULL)
		elog(ERROR, "flat_dictionary: no dictionary context provided for decompression");

	const FlatDictionaryCompressed *header =
		(const FlatDictionaryCompressed *) PG_DETOAST_DATUM(compressed_data);

	Assert(header->compression_algorithm == COMPRESSION_ALGORITHM_FLAT_DICTIONARY);

	FlatDictionaryDecompressionIterator *iter = palloc(sizeof(*iter));
	iter->base.compression_algorithm = COMPRESSION_ALGORITHM_FLAT_DICTIONARY;
	iter->base.forward = false;
	iter->base.element_type = element_type;
	iter->base.try_next = flat_dictionary_decompression_iterator_try_next_reverse;

	iter->compressed = header;
	iter->dict_ctx = ctx;
	iter->index_data = (const char *) header + sizeof(FlatDictionaryCompressed);
	iter->current_pos = header->num_elements; /* start past end, decrement */
	iter->has_nulls = header->has_nulls;

	if (iter->has_nulls)
	{
		Size data_size = (Size) header->num_elements * header->index_width;
		const char *nulls_data = iter->index_data + data_size;
		StringInfoData si;
		si.data = (char *) nulls_data;
		si.len = VARSIZE(header) - sizeof(FlatDictionaryCompressed) - data_size;
		si.cursor = 0;
		si.maxlen = si.len;
		Simple8bRleSerialized *nulls_serialized = bytes_deserialize_simple8b_and_advance(&si);
		simple8brle_decompression_iterator_init_reverse(&iter->nulls_iter, nulls_serialized);
	}

	return &iter->base;
}

DecompressResult
flat_dictionary_decompression_iterator_try_next_reverse(DecompressionIterator *base_iter)
{
	FlatDictionaryDecompressionIterator *iter =
		(FlatDictionaryDecompressionIterator *) base_iter;

	if (iter->current_pos == 0)
		return (DecompressResult){ .is_done = true };

	iter->current_pos--;

	if (iter->has_nulls)
	{
		Simple8bRleDecompressResult null_result =
			simple8brle_decompression_iterator_try_next_reverse(&iter->nulls_iter);
		if (null_result.val == 1)
			return (DecompressResult){ .is_null = true };
	}

	uint32 index = flat_dict_read_index(iter->index_data,
										iter->compressed->index_width,
										iter->current_pos);

	Assert(index < iter->dict_ctx->num_values);
	Datum val = iter->dict_ctx->values[index];

	return (DecompressResult){ .val = val };
}

////////////////////////
/// decompress_all   ///
////////////////////////

/*
 * Bulk decompression — returns an ArrowArray with all values resolved
 * from the dictionary. This is the fast path used by vectorized execution.
 */
ArrowArray *
flat_dictionary_decompress_all(Datum compressed_data, Oid element_type,
                               FlatDictionaryContext *ctx, MemoryContext dest_mctx)
{
	const FlatDictionaryCompressed *header =
		(const FlatDictionaryCompressed *) PG_DETOAST_DATUM(compressed_data);

	Assert(header->compression_algorithm == COMPRESSION_ALGORITHM_FLAT_DICTIONARY);

	uint16 n = header->num_elements;
	const char *index_data = (const char *) header + sizeof(FlatDictionaryCompressed);

	MemoryContext old_ctx = MemoryContextSwitchTo(dest_mctx);

	/*
	 * If ctx is NULL, this is an all-NULL segment (no dictionary exists).
	 * Every row in the batch must be NULL. Produce an all-NULL ArrowArray.
	 */
	if (ctx == NULL)
	{
		ArrowArray *result = palloc0(sizeof(ArrowArray));
		result->length = n;
		result->null_count = n;
		result->n_buffers = 3;
		result->buffers = palloc0(sizeof(void *) * 3);
		/* validity bitmap: all zeros = all NULL */
		result->buffers[0] = palloc0(sizeof(uint64) * ((n + 63) / 64));
		/* offsets: all zero (no data) */
		result->buffers[1] = palloc0(pad_to_multiple(64, sizeof(uint32) * (n + 1)));
		/* empty data buffer */
		result->buffers[2] = palloc(64);
		MemoryContextSwitchTo(old_ctx);
		return result;
	}

	/*
	 * For TEXT types, we build an ArrowArray with dictionary encoding:
	 * the dictionary buffer + index array. For now, fall back to the
	 * iterator-based approach by resolving all values.
	 *
	 * TODO: Native Arrow dictionary encoding for zero-copy vectorized scans.
	 * For the initial implementation, we resolve indexes to Datums.
	 */

	/* Allocate Arrow buffers */
	ArrowArray *result = palloc0(sizeof(ArrowArray));
	result->length = n;
	result->null_count = 0;
	result->n_buffers = 2; /* validity + offsets/data */

	/* For TEXT: offsets (int32[n+1]) + data buffer */
	int16 typlen;
	bool typbyval;
	char typalign;
	get_typlenbyvalalign(element_type, &typlen, &typbyval, &typalign);

	if (typlen == -1)
	{
		/* Variable-length type (TEXT, BYTEA, etc.) */

		/* Decode nulls bitmap upfront (needed for both size and data passes) */
		bool has_nulls = header->has_nulls;
		bool *null_flags = NULL;
		if (has_nulls)
		{
			Size idx_data_size = (Size) n * header->index_width;
			const char *nulls_data = index_data + idx_data_size;
			StringInfoData si;
			si.data = (char *) nulls_data;
			si.len = VARSIZE(header) - sizeof(FlatDictionaryCompressed) - idx_data_size;
			si.cursor = 0;
			si.maxlen = si.len;
			Simple8bRleSerialized *ns = bytes_deserialize_simple8b_and_advance(&si);
			Simple8bRleDecompressionIterator nulls_iter;
			simple8brle_decompression_iterator_init_forward(&nulls_iter, ns);
			null_flags = palloc(sizeof(bool) * n);
			for (uint16 i = 0; i < n; i++)
			{
				Simple8bRleDecompressResult nr =
					simple8brle_decompression_iterator_try_next_forward(&nulls_iter);
				null_flags[i] = (nr.val == 1);
			}
		}

		/* Compute total data size (skip NULLs — their index slot is garbage) */
		Size total_data_size = 0;
		for (uint16 i = 0; i < n; i++)
		{
			if (null_flags && null_flags[i])
				continue;
			uint32 idx = flat_dict_read_index(index_data, header->index_width, i);
			Assert(idx < ctx->num_values);
			Datum val = ctx->values[idx];
			total_data_size += VARSIZE_ANY_EXHDR(DatumGetPointer(val));
		}

		/*
		 * Match the Arrow text layout produced by array.c: uint32 offsets (the
		 * contract the consumers read, e.g. get_max_varlena_bytes) and buffers
		 * padded to a 64-byte multiple so vectorized/SIMD consumers can read in
		 * full words without running past the allocation.
		 */
		uint32 *offsets =
			(uint32 *) palloc(pad_to_multiple(64, sizeof(uint32) * (n + 1)));
		char *data_buf = palloc(pad_to_multiple(64, total_data_size + 1));
		uint8 *validity = NULL;

		if (has_nulls)
		{
			validity = palloc0(sizeof(uint64) * ((n + 63) / 64));
		}

		uint32 offset = 0;
		offsets[0] = 0;
		for (uint16 i = 0; i < n; i++)
		{
			bool is_null = (null_flags && null_flags[i]);

			if (is_null)
			{
				offsets[i + 1] = offset;
				result->null_count++;
				/* validity bit stays 0 (null) */
			}
			else
			{
				uint32 idx = flat_dict_read_index(index_data, header->index_width, i);
				Assert(idx < ctx->num_values);
				Datum val = ctx->values[idx];
				Size len = VARSIZE_ANY_EXHDR(DatumGetPointer(val));
				memcpy(data_buf + offset, VARDATA_ANY(DatumGetPointer(val)), len);
				offset += len;
				offsets[i + 1] = offset;
				if (validity)
					validity[i / 8] |= (1 << (i % 8));
			}
		}

		if (null_flags)
			pfree(null_flags);

		result->buffers = palloc(sizeof(void *) * 3);
		result->buffers[0] = validity;
		result->buffers[1] = offsets;
		result->buffers[2] = data_buf;
		result->n_buffers = 3;
	}
	else
	{
		/* Fixed-length type. Pad to a 64-byte multiple for SIMD consumers. */
		char *data_buf = palloc(pad_to_multiple(64, (Size) typlen * n));
		uint8 *validity = NULL;
		bool has_nulls = header->has_nulls;

		Simple8bRleDecompressionIterator nulls_iter;
		if (has_nulls)
		{
			Size idx_data_size = (Size) n * header->index_width;
			const char *nulls_data = index_data + idx_data_size;
			StringInfoData si;
			si.data = (char *) nulls_data;
			si.len = VARSIZE(header) - sizeof(FlatDictionaryCompressed) - idx_data_size;
			si.cursor = 0;
			si.maxlen = si.len;
			Simple8bRleSerialized *ns = bytes_deserialize_simple8b_and_advance(&si);
			simple8brle_decompression_iterator_init_forward(&nulls_iter, ns);
			/*
			 * The validity bitmap is read by consumers a uint64 word at a time
			 * (arrow_row_is_valid / the vectorized qual loop), so it must be
			 * allocated as a whole number of 64-bit words — not (n+7)/8 bytes,
			 * which would let the last word read past the allocation.
			 */
			validity = palloc0(sizeof(uint64) * ((n + 63) / 64));
		}

		for (uint16 i = 0; i < n; i++)
		{
			bool is_null = false;
			if (has_nulls)
			{
				Simple8bRleDecompressResult nr =
					simple8brle_decompression_iterator_try_next_forward(&nulls_iter);
				is_null = (nr.val == 1);
			}

			if (is_null)
			{
				memset(data_buf + (typlen * i), 0, typlen);
				result->null_count++;
			}
			else
			{
				uint32 idx = flat_dict_read_index(index_data, header->index_width, i);
				Assert(idx < ctx->num_values);
				Datum val = ctx->values[idx];
				if (typbyval)
					store_att_byval(data_buf + (typlen * i), val, typlen);
				else
					memcpy(data_buf + (typlen * i), DatumGetPointer(val), typlen);
				if (validity)
					validity[i / 8] |= (1 << (i % 8));
			}
		}

		result->buffers = palloc(sizeof(void *) * 2);
		result->buffers[0] = validity;
		result->buffers[1] = data_buf;
		result->n_buffers = 2;
	}

	MemoryContextSwitchTo(old_ctx);
	return result;
}

/*
 * Generic-vtable stubs. flat_dictionary needs its segment dictionary, which the
 * generic decompression signatures cannot pass, so every real data path
 * special-cases the algorithm and calls the *_ctx-bearing functions above
 * directly. Reaching a stub means a generic path tried to decompress a
 * flat_dictionary datum in isolation (e.g. the SQL debug functions), which is
 * unsupported because the dictionary lives in a separate dictionary row.
 */
DecompressionIterator *
flat_dictionary_iterator_init_forward_stub(Datum compressed, Oid element_type)
{
	elog(ERROR,
		 "flat_dictionary cannot be decompressed without its segment dictionary; "
		 "this code path is not supported");
	pg_unreachable();
}

DecompressionIterator *
flat_dictionary_iterator_init_reverse_stub(Datum compressed, Oid element_type)
{
	elog(ERROR,
		 "flat_dictionary cannot be decompressed without its segment dictionary; "
		 "this code path is not supported");
	pg_unreachable();
}

ArrowArray *
flat_dictionary_decompress_all_stub(Datum compressed, Oid element_type, MemoryContext dest_mctx)
{
	elog(ERROR,
		 "flat_dictionary cannot be decompressed without its segment dictionary; "
		 "this code path is not supported");
	pg_unreachable();
}

/////////////////////
/// Send / Recv   ///
/////////////////////

void
flat_dictionary_compressed_send(CompressedDataHeader *header, StringInfo buffer)
{
	const FlatDictionaryCompressed *fc = (const FlatDictionaryCompressed *) header;
	Size total_size = VARSIZE(fc);
	Size data_size = total_size - sizeof(FlatDictionaryCompressed);

	pq_sendbyte(buffer, fc->has_nulls);
	pq_sendbyte(buffer, fc->index_width);
	pq_sendint32(buffer, fc->element_type);
	pq_sendint16(buffer, fc->num_elements);
	pq_sendbytes(buffer, (const char *) fc + sizeof(FlatDictionaryCompressed), data_size);
}

Datum
flat_dictionary_compressed_recv(StringInfo buf)
{
	uint8 has_nulls = pq_getmsgbyte(buf);
	uint8 index_width = pq_getmsgbyte(buf);
	Oid element_type = pq_getmsgint(buf, 4);
	uint16 num_elements = pq_getmsgint(buf, 2);

	Size data_size = (Size) num_elements * index_width;
	/* If has_nulls, there's additional nulls bitmap data */
	Size remaining = buf->len - buf->cursor;

	Size total_size = sizeof(FlatDictionaryCompressed) + remaining;
	total_size = MAXALIGN(total_size);

	FlatDictionaryCompressed *compressed = palloc0(total_size);
	SET_VARSIZE(compressed, total_size);
	compressed->compression_algorithm = COMPRESSION_ALGORITHM_FLAT_DICTIONARY;
	compressed->has_nulls = has_nulls;
	compressed->index_width = index_width;
	compressed->element_type = element_type;
	compressed->num_elements = num_elements;

	char *dest = (char *) compressed + sizeof(FlatDictionaryCompressed);
	memcpy(dest, pq_getmsgbytes(buf, remaining), remaining);

	(void) data_size; /* used implicitly via remaining */

	return PointerGetDatum(compressed);
}

///////////////////////////////
/// Pass 1: Dictionary Build //
///////////////////////////////

#include "dictionary_hash.h"
#include "datum_serialize.h"

/*
 * FlatDictionaryBuilder: Used during Pass 1 to collect all unique values
 * for a column within a segment and build the shared dictionary.
 */
typedef struct FlatDictionaryBuilder
{
	dictionary_hash *hash;
	uint32 next_index;
	Oid type;
	int16 typlen;
	bool typbyval;
	char typalign;
	DatumSerializer *serializer;
	ArrayCompressor *array_comp; /* for serializing dictionary values */
} FlatDictionaryBuilder;

FlatDictionaryBuilder *
flat_dictionary_builder_alloc(Oid type)
{
	FlatDictionaryBuilder *builder = palloc0(sizeof(FlatDictionaryBuilder));
	TypeCacheEntry *tentry =
		lookup_type_cache(type, TYPECACHE_EQ_OPR_FINFO | TYPECACHE_HASH_PROC_FINFO);

	builder->next_index = 0;
	builder->type = type;
	builder->typlen = tentry->typlen;
	builder->typbyval = tentry->typbyval;
	builder->typalign = tentry->typalign;
	builder->hash = dictionary_hash_alloc(tentry);
	builder->serializer = create_datum_serializer(type);
	builder->array_comp = array_compressor_alloc(type);

	return builder;
}

/*
 * Add a value to the dictionary. Returns the assigned index.
 * If the value already exists, returns the existing index.
 */
uint32
flat_dictionary_builder_add(FlatDictionaryBuilder *builder, Datum val)
{
	bool found;
	DictionaryHashItem *item;

	if (datum_serializer_value_may_be_toasted(builder->serializer))
		val = PointerGetDatum(PG_DETOAST_DATUM_PACKED(val));

	item = dictionary_insert(builder->hash, val, &found);

	if (!found)
	{
		item->index = builder->next_index++;
		item->key = datumCopy(val, builder->typbyval, builder->typlen);
		array_compressor_append(builder->array_comp, val);
	}

	return item->index;
}

uint32
flat_dictionary_builder_num_values(FlatDictionaryBuilder *builder)
{
	return builder->next_index;
}

/*
 * Finish building: serialize dictionary as ArrayCompressed blob.
 * Returns the compressed dictionary data (varlena).
 */
void *
flat_dictionary_builder_finish(FlatDictionaryBuilder *builder)
{
	return array_compressor_finish(builder->array_comp);
}

/*
 * Look up a value in the builder's hash, returning its index.
 * The value MUST already exist (added during Pass 1).
 */
uint32
flat_dictionary_builder_lookup(FlatDictionaryBuilder *builder, Datum val)
{
	bool found;
	DictionaryHashItem *item;

	if (datum_serializer_value_may_be_toasted(builder->serializer))
		val = PointerGetDatum(PG_DETOAST_DATUM_PACKED(val));

	item = dictionary_insert(builder->hash, val, &found);
	Assert(found);
	return item->index;
}
