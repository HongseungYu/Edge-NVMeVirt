// SPDX-License-Identifier: GPL-2.0-only
//
// hmb_cache.c - 3-tier L2P translation cache simulator
//
// Models the latency of L2P address translation on a DRAM-less SSD:
//   Tier 1 (SRAM)  - small on-device cache, fastest
//   Tier 2 (HMB)   - host memory buffer via PCIe, medium latency
//   Tier 3 (NAND)  - fetch mapping segment from flash, slowest
//
// The maptbl[] array in conv_ftl.c remains the source of truth for actual
// PPA values; this module only models the *latency* added by the 3-tier
// lookup.

#include <linux/vmalloc.h>
#include <linux/log2.h>
#include <linux/random.h>
#include <linux/hash.h>
#include <linux/string.h>

#include "nvmev.h"
#include "hmb_cache.h"

/* ------------------------------------------------------------------ */
/* Internal tier helpers                                               */
/* ------------------------------------------------------------------ */

static int tier_init(struct hmb_cache_tier *tier, uint32_t capacity)
{
	uint32_t i, nbuckets;

	tier->capacity  = capacity;
	tier->count     = 0;
	tier->next_free = 0;
	INIT_LIST_HEAD(&tier->lru_list);

	/* vzalloc gives zero-initialised pages so hlist nodes start "unhashed" */
	tier->pool = vzalloc(sizeof(struct hmb_cache_entry) * capacity);
	if (!tier->pool)
		return -ENOMEM;

	/* Choose bucket count as next power-of-two >= capacity */
	tier->htable_bits = order_base_2(capacity);
	if (tier->htable_bits == 0)
		tier->htable_bits = 1;
	nbuckets = 1u << tier->htable_bits;

	tier->htable = vmalloc(sizeof(struct hlist_head) * nbuckets);
	if (!tier->htable) {
		vfree(tier->pool);
		tier->pool = NULL;
		return -ENOMEM;
	}
	for (i = 0; i < nbuckets; i++)
		INIT_HLIST_HEAD(&tier->htable[i]);

	return 0;
}

static void tier_fini(struct hmb_cache_tier *tier)
{
	if (tier->htable) {
		vfree(tier->htable);
		tier->htable = NULL;
	}
	if (tier->pool) {
		vfree(tier->pool);
		tier->pool = NULL;
	}
	tier->capacity = tier->count = tier->next_free = 0;
}

/* O(1) lookup via hash table. Returns NULL on miss. */
static struct hmb_cache_entry *tier_lookup(struct hmb_cache_tier *tier, uint64_t lpn)
{
	struct hmb_cache_entry *e;
	uint32_t bucket = hash_64(lpn, tier->htable_bits);

	hlist_for_each_entry(e, &tier->htable[bucket], hash_link) {
		if (e->lpn == lpn)
			return e;
	}
	return NULL;
}

/* Move an already-cached entry to the MRU head of the LRU list. */
static inline void tier_promote(struct hmb_cache_tier *tier, struct hmb_cache_entry *e)
{
	list_move(&e->lru_link, &tier->lru_list);
}

/*
 * Insert (lpn, ppa) into the tier, evicting if at capacity.
 * Caller must hold the cache spinlock.
 */
static void tier_insert(struct hmb_cache_tier *tier, uint64_t lpn,
			const struct ppa *ppa, enum hmb_repl_policy policy)
{
	struct hmb_cache_entry *e;
	uint32_t bucket;

	if (tier->count < tier->capacity) {
		/* Warmup: grab the next free pool slot. */
		e = &tier->pool[tier->next_free++];
		tier->count++;
	} else {
		/* Tier full: choose a victim. */
		if (policy == HMB_REPL_RANDOM) {
			/*
			 * When count == capacity every pool slot is live, so a
			 * uniform random index gives a uniform random victim.
			 */
			e = &tier->pool[get_random_u32() % tier->capacity];
		} else {
			/* LRU: evict the tail of the LRU list. */
			e = list_last_entry(&tier->lru_list,
					    struct hmb_cache_entry, lru_link);
		}
		hlist_del_init(&e->hash_link);
		list_del(&e->lru_link);
	}

	/* Populate and link the entry. */
	e->lpn = lpn;
	e->ppa = *ppa;

	bucket = hash_64(lpn, tier->htable_bits);
	hlist_add_head(&e->hash_link, &tier->htable[bucket]);
	list_add(&e->lru_link, &tier->lru_list); /* MRU position */
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

int hmb_cache_init(struct nvmev_hmb_cache *cache, uint32_t sram_entries,
		   uint32_t hmb_entries, uint64_t lat_sram_ns,
		   uint64_t lat_hmb_ns, uint64_t lat_nand_ns,
		   enum hmb_repl_policy policy)
{
	int ret;

	memset(cache, 0, sizeof(*cache));
	spin_lock_init(&cache->lock);
	atomic64_set(&cache->total_l2p_lat_ns, 0);
	atomic64_set(&cache->total_ios, 0);

	cache->lat_sram_ns  = lat_sram_ns;
	cache->lat_hmb_ns   = lat_hmb_ns;
	cache->lat_nand_ns  = lat_nand_ns;
	cache->repl_policy  = policy;

	if (sram_entries > 0) {
		ret = tier_init(&cache->sram, sram_entries);
		if (ret) {
			NVMEV_ERROR("HMB cache: SRAM tier alloc failed (%d)\n", ret);
			return ret;
		}
	}

	if (hmb_entries > 0) {
		ret = tier_init(&cache->hmb, hmb_entries);
		if (ret) {
			NVMEV_ERROR("HMB cache: HMB tier alloc failed (%d)\n", ret);
			tier_fini(&cache->sram);
			return ret;
		}
	}

	NVMEV_INFO("HMB cache init: SRAM %u entries (%llu ns), HMB %u entries (%llu ns), "
		   "NAND miss %llu ns, policy=%s\n",
		   sram_entries, lat_sram_ns,
		   hmb_entries, lat_hmb_ns,
		   lat_nand_ns,
		   policy == HMB_REPL_LRU ? "LRU" : "RANDOM");
	return 0;
}

void hmb_cache_fini(struct nvmev_hmb_cache *cache)
{
	uint64_t ios = (uint64_t)atomic64_read(&cache->total_ios);
	uint64_t avg_lat = ios > 0 ?
		(uint64_t)atomic64_read(&cache->total_l2p_lat_ns) / ios : 0;

	NVMEV_INFO("HMB cache stats: SRAM hits=%llu  HMB hits=%llu  NAND fetches=%llu"
		   "  avg_l2p_lat_ns=%llu\n",
		   cache->sram_hits, cache->hmb_hits, cache->nand_fetches, avg_lat);
	tier_fini(&cache->hmb);
	tier_fini(&cache->sram);
}

void hmb_cache_record_io(struct nvmev_hmb_cache *cache, uint64_t l2p_lat_ns)
{
	atomic64_add(l2p_lat_ns, &cache->total_l2p_lat_ns);
	atomic64_inc(&cache->total_ios);
}

uint64_t hmb_cache_lookup(struct nvmev_hmb_cache *cache, uint64_t lpn,
			  const struct ppa *ppa)
{
	struct hmb_cache_entry *e;
	uint64_t lat;
	unsigned long flags;

	spin_lock_irqsave(&cache->lock, flags);

	/* --- Tier 1: SRAM --- */
	if (cache->sram.capacity > 0) {
		e = tier_lookup(&cache->sram, lpn);
		if (e) {
			tier_promote(&cache->sram, e);
			cache->sram_hits++;
			lat = cache->lat_sram_ns;
			goto out;
		}
	}

	/* --- Tier 2: HMB --- */
	if (cache->hmb.capacity > 0) {
		e = tier_lookup(&cache->hmb, lpn);
		if (e) {
			cache->hmb_hits++;
			lat = cache->lat_hmb_ns;
			/* Promote to SRAM so the next access is faster. */
			if (cache->sram.capacity > 0)
				tier_insert(&cache->sram, lpn, ppa, cache->repl_policy);
			/* Keep HMB entry at MRU to reflect the recent access. */
			tier_promote(&cache->hmb, e);
			goto out;
		}
	}

	/* --- Tier 3: NAND miss --- */
	cache->nand_fetches++;
	lat = cache->lat_nand_ns;
	/* Load into the highest available tier: HMB if present, else SRAM directly. */
	if (cache->hmb.capacity > 0)
		tier_insert(&cache->hmb, lpn, ppa, cache->repl_policy);
	else if (cache->sram.capacity > 0)
		tier_insert(&cache->sram, lpn, ppa, cache->repl_policy);

out:
	spin_unlock_irqrestore(&cache->lock, flags);
	return lat;
}

void hmb_cache_update(struct nvmev_hmb_cache *cache, uint64_t lpn,
		      const struct ppa *ppa)
{
	struct hmb_cache_entry *e;
	unsigned long flags;

	spin_lock_irqsave(&cache->lock, flags);

	/* Update SRAM in-place if present; keep it at MRU. */
	if (cache->sram.capacity > 0) {
		e = tier_lookup(&cache->sram, lpn);
		if (e) {
			e->ppa = *ppa;
			tier_promote(&cache->sram, e);
			/* Also refresh the HMB shadow entry if it still exists. */
			if (cache->hmb.capacity > 0) {
				e = tier_lookup(&cache->hmb, lpn);
				if (e) {
					e->ppa = *ppa;
					tier_promote(&cache->hmb, e);
				}
			}
			goto out;
		}
	}

	/* Update HMB in-place if present; promote to SRAM with new PPA. */
	if (cache->hmb.capacity > 0) {
		e = tier_lookup(&cache->hmb, lpn);
		if (e) {
			e->ppa = *ppa;
			tier_promote(&cache->hmb, e);
			if (cache->sram.capacity > 0)
				tier_insert(&cache->sram, lpn, ppa, cache->repl_policy);
			goto out;
		}
		/* Entry was evicted between the pre-write lookup and here; insert fresh. */
		tier_insert(&cache->hmb, lpn, ppa, cache->repl_policy);
	}

out:
	spin_unlock_irqrestore(&cache->lock, flags);
}
