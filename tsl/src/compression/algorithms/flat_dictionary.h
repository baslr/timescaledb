/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */
#pragma once

/*
 * Flat Dictionary compression: a shared dictionary per segment with raw
 * fixed-width index arrays per batch. Achieves near-theoretical compression
 * ratios for high-cardinality TEXT columns where the per-batch dictionary
 * approach fails.
 *
 * Storage layout:
 *   Row 0 (dictionary row): _ts_meta_count = 0, column = ArrayCompressed blob
 *   Row 1+: column = FlatDictionaryCompressed (raw index array)
 *
 * Index width is adaptive: uint8 (<=255), uint16 (<=65535), int32 (>65535).
 * No Simple8b, no RLE — raw fixed-width array for O(1) access.
 */

#include <postgres.h>
#include <lib/stringinfo.h>
#include <fmgr.h>

#include "compression/compression.h"

/* Index width constants */
#define FLAT_DICT_WIDTH_8  1
#define FLAT_DICT_WIDTH_16 2
#define FLAT_DICT_WIDTH_32 4

typedef struct FlatDictionaryCompressed FlatDictionaryCompressed;
typedef struct FlatDictionaryCompressor FlatDictionaryCompressor;

/*
 * The compressed on-disk format for one batch of index data.
 * Total size: 16 bytes header + num_elements * index_width
 */
typedef struct FlatDictionaryCompressed
{
	CompressedDataHeaderFields;
	uint8 has_nulls;       /* 1 if nulls bitmap follows data */
	uint8 index_width;     /* 1, 2, or 4 bytes per index */
	uint8 padding[1];
	/*
	 * OID of the original column type. Not read on the decode path (the element
	 * type is always supplied by the caller from the column), but retained:
	 * removing it would not shrink the header — the uint64-aligned flexible
	 * array member below pads the struct to 16 bytes either way — and it keeps
	 * the batch self-describing for send/recv and debugging.
	 */
	Oid element_type;
	uint16 num_elements;   /* number of rows in this batch */
	uint8 trailing_pad[2]; /* explicit trailing padding for uint64 alignment */
	/* followed by: index data (num_elements * index_width bytes) */
	/* followed by: nulls bitmap if has_nulls (Simple8bRle) */
	uint64 alignment_sentinel[FLEXIBLE_ARRAY_MEMBER];
} FlatDictionaryCompressed;

/*
 * The compressor state. This only writes index arrays — it requires that
 * the dictionary has already been built during Pass 1 and is available
 * as a lookup hash.
 */

extern bool flat_dictionary_compressed_has_nulls(const CompressedDataHeader *header);

extern Compressor *flat_dictionary_compressor_for_type(Oid element_type);

/*
 * Segment-level dictionary context. The decompression of a flat_dictionary
 * batch resolves its raw indexes against this dictionary. There is NO ambient
 * / per-backend storage for it: it is threaded explicitly from the decompression
 * session object (RowDecompressor for the bulk path, DecompressContext for the
 * columnar scan) into the functions below.
 */
typedef struct FlatDictionaryContext
{
	Datum *values;     /* array of dictionary values (palloc'd) */
	uint32 num_values; /* number of entries in dictionary */
	Oid element_type;
	int16 typlen;
	bool typbyval;
} FlatDictionaryContext;

/*
 * Decompression entry points. Unlike the other algorithms these take the
 * segment dictionary explicitly, so they are NOT wired into the generic
 * CompressionAlgorithmDefinition vtable (whose signature has no slot for it).
 * Callers must special-case COMPRESSION_ALGORITHM_FLAT_DICTIONARY and invoke
 * these directly with the context from their session object.
 */
extern DecompressionIterator *
tsl_flat_dictionary_decompression_iterator_from_datum_forward(Datum compressed, Oid element_type,
                                                              FlatDictionaryContext *ctx);
extern DecompressResult
flat_dictionary_decompression_iterator_try_next_forward(DecompressionIterator *iter);

extern DecompressionIterator *
tsl_flat_dictionary_decompression_iterator_from_datum_reverse(Datum compressed, Oid element_type,
                                                              FlatDictionaryContext *ctx);
extern DecompressResult
flat_dictionary_decompression_iterator_try_next_reverse(DecompressionIterator *iter);

extern ArrowArray *flat_dictionary_decompress_all(Datum compressed, Oid element_type,
                                                   FlatDictionaryContext *ctx,
                                                   MemoryContext dest_mctx);

extern void flat_dictionary_compressed_send(CompressedDataHeader *header, StringInfo buffer);
extern Datum flat_dictionary_compressed_recv(StringInfo buf);

/*
 * Build a FlatDictionaryContext from a dictionary-row blob.
 *
 * `array_blob` must be an ALREADY-DETOASTED ArrayCompressed datum (as produced
 * by flat_dictionary_builder_finish) holding the segment's unique values.
 * Every value is materialized as a Datum in `dest_mctx`, which MUST outlive all
 * batches that reference the dictionary — i.e. a scan- or segment-lifetime
 * context, never a per-batch context that gets reset between batches. The
 * returned context is itself allocated in `dest_mctx`; store it on the
 * decompression session object (RowDecompressor or DecompressContext) and pass
 * it explicitly to the flat_dictionary decompression functions.
 */
extern FlatDictionaryContext *flat_dictionary_context_from_array_blob(Datum array_blob,
                                                                      Oid element_type,
                                                                      MemoryContext dest_mctx);

/*
 * Pass 1 Dictionary Builder API
 */
typedef struct FlatDictionaryBuilder FlatDictionaryBuilder;

extern FlatDictionaryBuilder *flat_dictionary_builder_alloc(Oid type);
extern uint32 flat_dictionary_builder_add(FlatDictionaryBuilder *builder, Datum val);
extern uint32 flat_dictionary_builder_num_values(FlatDictionaryBuilder *builder);
extern void *flat_dictionary_builder_finish(FlatDictionaryBuilder *builder);
extern uint32 flat_dictionary_builder_lookup(FlatDictionaryBuilder *builder, Datum val);
extern void flat_dictionary_compressor_set_builder(Compressor *compressor,
                                                    FlatDictionaryBuilder *builder);

/*
 * Stubs for the generic vtable. flat_dictionary cannot be decompressed through
 * the generic (Datum, Oid[, MemoryContext]) signatures because it needs the
 * segment dictionary, which those signatures cannot carry. Every real data path
 * special-cases COMPRESSION_ALGORITHM_FLAT_DICTIONARY before dispatch; these
 * stubs exist only so the vtable entry is non-NULL and to give a clear error if
 * an unexpected generic path (e.g. the SQL debug functions that decompress a
 * lone datum without its segment) is ever taken.
 */
extern DecompressionIterator *flat_dictionary_iterator_init_forward_stub(Datum compressed,
                                                                         Oid element_type);
extern DecompressionIterator *flat_dictionary_iterator_init_reverse_stub(Datum compressed,
                                                                         Oid element_type);
extern ArrowArray *flat_dictionary_decompress_all_stub(Datum compressed, Oid element_type,
                                                       MemoryContext dest_mctx);

#define FLAT_DICTIONARY_ALGORITHM_DEFINITION                                                        \
	{                                                                                              \
		.iterator_init_forward = flat_dictionary_iterator_init_forward_stub,                        \
		.iterator_init_reverse = flat_dictionary_iterator_init_reverse_stub,                        \
		.compressed_data_send = flat_dictionary_compressed_send,                                    \
		.compressed_data_recv = flat_dictionary_compressed_recv,                                    \
		.compressor_for_type = flat_dictionary_compressor_for_type,                                 \
		.compressed_data_storage = TOAST_STORAGE_EXTENDED,                                          \
		.decompress_all = flat_dictionary_decompress_all_stub,                                      \
	}
