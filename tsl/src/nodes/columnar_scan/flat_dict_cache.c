/*
 * This file and its contents are licensed under the Timescale License.
 * Please see the included NOTICE for copyright information and
 * LICENSE-TIMESCALE for a copy of the license.
 */
#include <postgres.h>
#include <access/detoast.h>
#include <access/htup_details.h>
#include <access/table.h>
#include <access/tableam.h>
#include <catalog/pg_attribute.h>
#include <common/hashfn.h>
#include <executor/tuptable.h>
#include <lib/stringinfo.h>
#include <utils/builtins.h>
#include <utils/memutils.h>
#include <utils/rel.h>
#include <utils/snapmgr.h>

#include "compression/algorithms/datum_serialize.h"
#include "compression/algorithms/flat_dictionary.h"
#include "compression/compression.h"
#include "nodes/columnar_scan/flat_dict_cache.h"

#include "chunk.h"

/*
 * One cache entry: the serialized segmentby key bytes (owned by the cache's
 * memory context) and the dictionary built for that segment.
 */
typedef struct FlatDictCacheItem
{
	/* Key: the serialized segmentby bytes. NULL key (len 0) is valid and used
	 * for the single-segment / no-segmentby case. */
	const char *key;
	uint32 key_len;
	/* simplehash bookkeeping */
	uint32 hash;
	uint16 status;
	/* Payload */
	FlatDictionaryContext *ctx;
} FlatDictCacheItem;

/*
 * Threaded through the simplehash table's private_data so the hash/eq callbacks
 * can reach the length of the key currently being probed. Keys are raw
 * serialized bytes (not NUL-terminated), so the length cannot be derived from
 * the bare key pointer. Every key in a given scan has the same length (fixed
 * number and types of segmentby columns), and simplehash calls the callbacks
 * synchronously from insert/lookup, so a single shared length is correct.
 */
typedef struct FlatDictHtPrivate
{
	uint32 probe_key_len;
} FlatDictHtPrivate;

#define SH_PREFIX flat_dict_ht
#define SH_ELEMENT_TYPE FlatDictCacheItem
#define SH_KEY_TYPE const char *
#define SH_KEY key
#define SH_HASH_KEY(tb, key) flat_dict_ht_hash_key(tb, key)
#define SH_EQUAL(tb, a, b) flat_dict_ht_equal_key(tb, a, b)
#define SH_STORE_HASH
#define SH_GET_HASH(tb, entry) entry->hash
#define SH_SCOPE static inline
#define SH_DEFINE
#define SH_DECLARE
/*
 * Forward-declare the hash/eq callbacks so the simplehash template can
 * reference them. They need the key length, which is not derivable from the
 * bare key pointer (keys are raw serialized bytes, not NUL-terminated), so it
 * is threaded through the table's private_data. simplehash invokes these
 * callbacks synchronously from within insert/lookup, so reading the length
 * that was set just before the call is safe (single-threaded, no reentrancy).
 */
struct flat_dict_ht_hash;
static inline uint32 flat_dict_ht_hash_key(struct flat_dict_ht_hash *tb, const char *key);
static inline bool flat_dict_ht_equal_key(struct flat_dict_ht_hash *tb, const char *a,
										  const char *b);
#include "lib/simplehash.h"

static inline uint32
flat_dict_ht_hash_key(struct flat_dict_ht_hash *tb, const char *key)
{
	FlatDictHtPrivate *priv = (FlatDictHtPrivate *) tb->private_data;
	return hash_bytes((const unsigned char *) key, priv->probe_key_len);
}

static inline bool
flat_dict_ht_equal_key(struct flat_dict_ht_hash *tb, const char *a, const char *b)
{
	FlatDictHtPrivate *priv = (FlatDictHtPrivate *) tb->private_data;
	/*
	 * Both keys in the table were inserted with the same probe_key_len that is
	 * currently set (the number of segmentby columns and their types are fixed
	 * for a scan, so every key has the same length). Compare those bytes.
	 */
	return memcmp(a, b, priv->probe_key_len) == 0;
}

struct FlatDictCache
{
	MemoryContext mctx; /* where keys, dictionaries and the table live */
	struct flat_dict_ht_hash *ht;
	FlatDictHtPrivate priv;

	int num_segmentby_cols;
	FlatDictSegmentbyColumn *segmentby_columns;
	/* One serializer per segmentby column, built once. */
	DatumSerializer **serializers;
	/*
	 * Cached attno arrays in canonical fd.segmentby order. scan_attnos indexes
	 * the compressed scan-output slot (executor lookup/insert). The prefetch
	 * builds its own physical-heap attno array locally.
	 */
	AttrNumber *scan_attnos;

	/* Scratch buffer reused for building keys; grows as needed. */
	char *keybuf;
	Size keybuf_size;
};

FlatDictCache *
flat_dict_cache_create(MemoryContext mctx, int num_segmentby_cols,
					   const FlatDictSegmentbyColumn *segmentby_columns)
{
	MemoryContext old = MemoryContextSwitchTo(mctx);

	FlatDictCache *cache = palloc0(sizeof(FlatDictCache));
	cache->mctx = mctx;
	cache->num_segmentby_cols = num_segmentby_cols;
	cache->priv.probe_key_len = 0;

	if (num_segmentby_cols > 0)
	{
		cache->segmentby_columns =
			palloc(sizeof(FlatDictSegmentbyColumn) * num_segmentby_cols);
		memcpy(cache->segmentby_columns,
			   segmentby_columns,
			   sizeof(FlatDictSegmentbyColumn) * num_segmentby_cols);

		cache->serializers = palloc(sizeof(DatumSerializer *) * num_segmentby_cols);
		cache->scan_attnos = palloc(sizeof(AttrNumber) * num_segmentby_cols);
		for (int i = 0; i < num_segmentby_cols; i++)
		{
			/* Own the column name string. */
			cache->segmentby_columns[i].column_name =
				pstrdup(segmentby_columns[i].column_name);
			cache->serializers[i] = create_datum_serializer(segmentby_columns[i].typid);
			cache->scan_attnos[i] = segmentby_columns[i].compressed_scan_attno;
		}
	}

	cache->keybuf_size = 128;
	cache->keybuf = palloc(cache->keybuf_size);

	cache->ht = flat_dict_ht_create(mctx, 16, &cache->priv);

	MemoryContextSwitchTo(old);
	return cache;
}

/*
 * Serialize the segmentby values read from `slot` at the given attribute
 * numbers into the cache scratch buffer and return the byte length. The attnos
 * are supplied by the caller so the same routine serves both the executor path
 * (compressed scan-output attnos) and the prefetch path (physical heap attnos);
 * in both cases the columns are visited in the canonical fd.segmentby order
 * with the same per-column serializer, so a data batch and its dictionary row
 * produce identical bytes -> a correct key.
 *
 * A NULL segmentby value is encoded as a single 0xFF marker byte; a non-NULL
 * value is encoded as a 0x00 marker byte followed by its serialized bytes. The
 * marker disambiguates NULL from any real value and keeps every column
 * self-delimiting.
 */
static uint32
flat_dict_cache_build_key(FlatDictCache *cache, TupleTableSlot *slot, const AttrNumber *attnos)
{
	if (cache->num_segmentby_cols == 0)
	{
		/* Single-segment case: constant empty key. */
		return 0;
	}

	Size used = 0;
	for (int i = 0; i < cache->num_segmentby_cols; i++)
	{
		bool isnull;
		Datum value = slot_getattr(slot, attnos[i], &isnull);

		/* Ensure room for the 1-byte marker. */
		if (used + 1 > cache->keybuf_size)
		{
			cache->keybuf_size *= 2;
			cache->keybuf =
				repalloc(cache->keybuf, cache->keybuf_size);
		}

		if (isnull)
		{
			cache->keybuf[used++] = (char) 0xFF;
			continue;
		}

		cache->keybuf[used++] = 0x00;

		/*
		 * Detoast the value if needed: the serializer requires a non-external
		 * datum, and segmentby values can in principle be toasted. We detoast
		 * into the current (per-call) context; the result is only needed until
		 * the bytes are copied into the buffer below.
		 */
		Datum detoasted = value;
		if (datum_serializer_value_may_be_toasted(cache->serializers[i]))
		{
			detoasted = PointerGetDatum(PG_DETOAST_DATUM(value));
		}

		Size needed = datum_get_bytes_size(cache->serializers[i], used, detoasted);
		if (needed > cache->keybuf_size)
		{
			while (needed > cache->keybuf_size)
				cache->keybuf_size *= 2;
			cache->keybuf = repalloc(cache->keybuf, cache->keybuf_size);
		}

		Size max_size = cache->keybuf_size - used;
		char *end =
			datum_to_bytes_and_advance(cache->serializers[i], cache->keybuf + used, &max_size,
									   detoasted);
		used = end - cache->keybuf;

		if (DatumGetPointer(detoasted) != DatumGetPointer(value))
			pfree(DatumGetPointer(detoasted));
	}

	Assert(used <= PG_UINT32_MAX);
	return (uint32) used;
}

/*
 * Insert ctx under the key built from `slot` at the given attnos. Shared by the
 * public executor insert (scan attnos) and the prefetch (physical attnos).
 */
static void
flat_dict_cache_insert_at(FlatDictCache *cache, TupleTableSlot *slot, const AttrNumber *attnos,
						  FlatDictionaryContext *ctx)
{
	uint32 key_len = flat_dict_cache_build_key(cache, slot, attnos);
	cache->priv.probe_key_len = key_len;

	/*
	 * Copy the key bytes into the cache's own context: keybuf is scratch and
	 * gets overwritten by the next build. Insert with the persistent copy as
	 * the key so future probes (which compare bytes, not pointers) match.
	 */
	MemoryContext old = MemoryContextSwitchTo(cache->mctx);
	char *key_copy = key_len > 0 ? palloc(key_len) : palloc(1);
	if (key_len > 0)
		memcpy(key_copy, cache->keybuf, key_len);
	MemoryContextSwitchTo(old);

	bool found;
	FlatDictCacheItem *item = flat_dict_ht_insert(cache->ht, key_copy, &found);
	if (found)
	{
		/*
		 * Same segment dictionary loaded twice (e.g. fill-on-encounter then a
		 * later prefetch). Keep the existing one and drop the duplicate key
		 * copy; the dictionaries are equivalent.
		 */
		pfree(key_copy);
		return;
	}
	item->key = key_copy;
	item->key_len = key_len;
	item->ctx = ctx;
}

FlatDictionaryContext *
flat_dict_cache_lookup(FlatDictCache *cache, TupleTableSlot *compressed_slot)
{
	uint32 key_len = flat_dict_cache_build_key(cache, compressed_slot, cache->scan_attnos);
	cache->priv.probe_key_len = key_len;

	FlatDictCacheItem *item = flat_dict_ht_lookup(cache->ht, cache->keybuf);
	if (item == NULL)
		return NULL;
	return item->ctx;
}

void
flat_dict_cache_insert(FlatDictCache *cache, TupleTableSlot *compressed_slot,
					   FlatDictionaryContext *ctx)
{
	flat_dict_cache_insert_at(cache, compressed_slot, cache->scan_attnos, ctx);
}

void
flat_dict_cache_prefetch(FlatDictCache *cache, Oid chunk_relid, MemoryContext dict_mctx)
{
	Chunk *chunk = ts_chunk_get_by_relid(chunk_relid, /* fail_if_not_found = */ false);
	if (chunk == NULL || chunk->fd.compressed_chunk_id == INVALID_CHUNK_ID)
	{
		/* Not a compressed chunk (should not happen on this path) — nothing to do. */
		return;
	}

	Chunk *compressed_chunk =
		ts_chunk_get_by_id(chunk->fd.compressed_chunk_id, /* fail_if_not_found = */ false);
	if (compressed_chunk == NULL)
		return;

	Relation comp_rel = table_open(compressed_chunk->table_id, AccessShareLock);

	/*
	 * Resolve the physical attribute numbers of the segmentby columns in this
	 * compressed heap relation, by name, in the canonical fd.segmentby order.
	 * These can differ from the executor's compressed scan-output attnos, so we
	 * must use them when reading values from the raw table scan slot below.
	 * Keying off the same column set + serializer in the same order guarantees
	 * the prefetch's keys match the executor's lookup keys.
	 */
	AttrNumber *physical_attnos = NULL;
	if (cache->num_segmentby_cols > 0)
	{
		TupleDesc comp_desc = RelationGetDescr(comp_rel);
		physical_attnos = palloc(sizeof(AttrNumber) * cache->num_segmentby_cols);
		for (int i = 0; i < cache->num_segmentby_cols; i++)
		{
			AttrNumber attno = InvalidAttrNumber;
			for (int a = 0; a < comp_desc->natts; a++)
			{
				Form_pg_attribute att = TupleDescAttr(comp_desc, a);
				if (!att->attisdropped &&
					namestrcmp(&att->attname, cache->segmentby_columns[i].column_name) == 0)
				{
					attno = att->attnum;
					break;
				}
			}
			if (attno == InvalidAttrNumber)
				elog(ERROR,
					 "flat_dictionary prefetch: segmentby column \"%s\" not found in compressed "
					 "chunk",
					 cache->segmentby_columns[i].column_name);
			physical_attnos[i] = attno;
		}
	}

	/*
	 * Build a decompressor over (compressed desc -> uncompressed desc). We reuse
	 * the existing, tested dictionary-row loader; it materializes each segment
	 * dictionary into CurrentMemoryContext, so switch to the scan-lifetime
	 * dict_mctx for the duration.
	 */
	Relation uncompressed_rel = table_open(chunk_relid, AccessShareLock);
	MemoryContext old = MemoryContextSwitchTo(dict_mctx);
	RowDecompressor decompressor =
		build_decompressor(RelationGetDescr(comp_rel), RelationGetDescr(uncompressed_rel));

	TupleTableSlot *slot = table_slot_create(comp_rel, NULL);
	TableScanDesc scan = table_beginscan(comp_rel, GetActiveSnapshot(), 0, (ScanKey) NULL);

	while (table_scan_getnextslot(scan, ForwardScanDirection, slot))
	{
		bool should_free;
		HeapTuple tuple = ExecFetchSlotHeapTuple(slot, false, &should_free);

		heap_deform_tuple(tuple,
						  decompressor.in_desc,
						  decompressor.compressed_datums,
						  decompressor.compressed_is_nulls);

		int32 meta_count =
			DatumGetInt32(decompressor.compressed_datums[decompressor.count_compressed_attindex]);

		if (meta_count == 0)
		{
			/*
			 * Dictionary row. Load it into decompressor->flat_dict_ctx, then
			 * move that dictionary into the cache keyed by this row's segmentby
			 * values (read from the same physical slot). Reset the decompressor
			 * slot so the next dictionary row builds a fresh context.
			 */
			decompressor.flat_dict_ctx = NULL;
			flat_dict_decompress_load_dictionary(&decompressor);

			if (decompressor.flat_dict_ctx != NULL)
			{
				flat_dict_cache_insert_at(cache, slot, physical_attnos, decompressor.flat_dict_ctx);
				decompressor.flat_dict_ctx = NULL;
			}
		}

		if (should_free)
			heap_freetuple(tuple);
	}

	table_endscan(scan);
	ExecDropSingleTupleTableSlot(slot);
	row_decompressor_close(&decompressor);
	MemoryContextSwitchTo(old);

	table_close(uncompressed_rel, AccessShareLock);
	table_close(comp_rel, AccessShareLock);
}
