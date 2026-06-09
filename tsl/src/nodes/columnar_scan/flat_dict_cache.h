/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */
#pragma once

#include <postgres.h>
#include <executor/tuptable.h>
#include <utils/palloc.h>

#include "compression/algorithms/flat_dictionary.h"

/*
 * Per-segment flat_dictionary cache.
 *
 * Maps a segment, identified by the serialized bytes of its segmentby column
 * values, to the FlatDictionaryContext built from that segment's dictionary
 * row. Both the dictionary row and every data batch of a segment store the
 * exact same segmentby Datums (the compressor writes them from one shared
 * SegmentInfo), so the serialized segmentby bytes are a correct, unique key
 * from a data batch back to its dictionary.
 *
 * The cache holds many dictionaries at once, which is what lets reverse scans,
 * batch sorted merge and compressed sort pushdown work: those reorder the
 * dictionary rows relative to their data batches, or interleave batches from
 * several segments, so a single active dictionary is not enough.
 *
 * All entries (and the dictionaries they point to) are allocated in the
 * memory context passed to flat_dict_cache_create, which must outlive every
 * batch that references a dictionary (a scan-lifetime context).
 */

typedef struct FlatDictCache FlatDictCache;

/*
 * Description of one segmentby column for keying, in the canonical
 * fd.segmentby order. compressed_scan_attno is the attribute number of this
 * column in the compressed *scan output* slot (the slot the executor feeds to
 * lookup/insert). column_name + typid let the prefetch, which scans the
 * compressed heap relation physically, resolve the (possibly different)
 * physical attribute number of the same column by name. Keying both paths off
 * the same column set, in the same order, with the same serializer, makes the
 * serialized bytes identical regardless of which physical/scan attno each path
 * uses.
 */
typedef struct FlatDictSegmentbyColumn
{
	AttrNumber compressed_scan_attno;
	Oid typid;
	const char *column_name;
} FlatDictSegmentbyColumn;

/*
 * Create an empty cache. num_segmentby_cols may be 0 (no segmentby columns at
 * all): then every segment hashes to the same empty key, which is correct
 * because a chunk without segmentby columns has exactly one segment and one
 * dictionary. The segmentby_columns array is copied into mctx.
 */
extern FlatDictCache *flat_dict_cache_create(
	MemoryContext mctx, int num_segmentby_cols,
	const FlatDictSegmentbyColumn *segmentby_columns);

/*
 * Look up the dictionary for the segment that owns the given compressed tuple
 * (a data batch or a dictionary row). The segmentby values are read from
 * compressed_slot using the columns supplied at create time. Returns NULL if
 * no dictionary for that segment is cached yet.
 */
extern FlatDictionaryContext *flat_dict_cache_lookup(FlatDictCache *cache,
													 TupleTableSlot *compressed_slot);

/*
 * Sentinel value returned by flat_dict_cache_lookup when the segment's
 * dictionary column was NULL (the entire segment is all-NULL for that column).
 * Callers must check for this before using the context for decompression.
 */
#define FLAT_DICT_CTX_ALL_NULL ((FlatDictionaryContext *) (uintptr_t) 1)

/*
 * Insert (or replace) the dictionary for the segment identified by the given
 * compressed tuple's segmentby values. The key is serialized into the cache's
 * own memory context; ctx is stored as-is (it must already live in a
 * scan-lifetime context).
 */
extern void flat_dict_cache_insert(FlatDictCache *cache,
								   TupleTableSlot *compressed_slot,
								   FlatDictionaryContext *ctx);

/*
 * One-shot prefetch: scan the compressed chunk and load every flat_dictionary
 * dictionary row (_ts_meta_count == 0) into the cache, keyed by its segmentby
 * values. Used by the reordered read modes (reverse / batch sorted merge /
 * compressed sort) and parallel scans where a data batch can be reached before
 * its dictionary row.
 *
 * compressed_rel_id is the OID of the compressed chunk's table (resolved at
 * exec init time, avoiding catalog lookups that require a transaction ID and
 * are forbidden in parallel workers). chunk_relid is the uncompressed chunk
 * (needed for its tuple descriptor). dict_mctx is where the dictionaries are
 * materialized (a scan-lifetime context).
 */
extern void flat_dict_cache_prefetch(FlatDictCache *cache,
									 Oid compressed_rel_id,
									 Oid chunk_relid,
									 MemoryContext dict_mctx);
