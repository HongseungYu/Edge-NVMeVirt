// SPDX-License-Identifier: GPL-2.0-only

#ifndef _NVMEVIRT_HMB_CACHE_H
#define _NVMEVIRT_HMB_CACHE_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/spinlock.h>
#include <linux/atomic.h>
#include "ssd.h"

enum hmb_repl_policy {
	HMB_REPL_LRU    = 0,
	HMB_REPL_RANDOM = 1,
	HMB_REPL_MRU    = 2,  /* evict most-recently-used; useful for sequential scans */
	HMB_REPL_FIFO   = 3,  /* evict oldest-inserted; no reorder on hit */
};

/*
 * One cached L2P mapping entry.  Stored in a flat pool array; linked into
 * both an LRU list and a hash-chain for O(1) lookup.
 */
struct hmb_cache_entry {
	uint64_t lpn;
	struct ppa ppa;
	struct list_head lru_link;   /* MRU at head, oldest at tail; for FIFO = insertion order */
	struct hlist_node hash_link;
};

/*
 * One tier (SRAM or HMB).  Entries are pre-allocated in pool[]; new entries
 * consume pool[next_free++] until the tier is full, after which eviction
 * recycles an existing slot.
 */
struct hmb_cache_tier {
	uint32_t capacity;   /* max entries */
	uint32_t count;      /* live entries */
	uint32_t next_free;  /* next unused pool index (valid while count < capacity) */
	struct list_head lru_list;
	struct hmb_cache_entry *pool;   /* vmalloc'd flat array */
	struct hlist_head *htable;      /* vmalloc'd bucket array */
	uint32_t htable_bits;           /* 2^htable_bits buckets */
};

struct nvmev_hmb_cache {
	struct hmb_cache_tier sram;
	struct hmb_cache_tier hmb;

	uint64_t lat_sram_ns;
	uint64_t lat_hmb_ns;
	uint64_t lat_nand_ns;

	enum hmb_repl_policy repl_policy;
	spinlock_t lock;

	/* hit/miss counters (updated under lock) */
	uint64_t sram_hits;
	uint64_t hmb_hits;
	uint64_t nand_fetches;

	/* per-IO L2P latency accumulator (updated with atomics, no lock needed) */
	atomic64_t total_l2p_lat_ns;
	atomic64_t total_ios;
};

/*
 * Allocate and initialise the 3-tier cache.
 *
 * @sram_entries: capacity of the SRAM tier (number of L2P entries)
 * @hmb_entries:  capacity of the HMB tier
 * Latency values are in nanoseconds.
 */
int hmb_cache_init(struct nvmev_hmb_cache *cache, uint32_t sram_entries,
		   uint32_t hmb_entries, uint64_t lat_sram_ns,
		   uint64_t lat_hmb_ns, uint64_t lat_nand_ns,
		   enum hmb_repl_policy policy);

void hmb_cache_fini(struct nvmev_hmb_cache *cache);

/*
 * Simulate an L2P lookup for @lpn through the 3-tier cache.
 *
 * Updates internal LRU ordering, performs promotion on HMB hit, and inserts
 * into HMB on a miss.  @ppa is the ground-truth PPA (from maptbl[]) used to
 * populate cache entries on miss/promotion.
 *
 * Returns the modelled lookup latency in nanoseconds.
 */
uint64_t hmb_cache_lookup(struct nvmev_hmb_cache *cache, uint64_t lpn,
			  const struct ppa *ppa);

/*
 * Update the cached PPA for @lpn after a write has landed.
 *
 * If the entry already exists in SRAM or HMB its PPA field is updated in-place
 * (avoiding the duplicate-entry hazard of a blind tier_insert).  If the entry
 * has been evicted a fresh HMB entry is inserted.  No latency is charged; this
 * models the controller updating its own mapping table as part of the write.
 */
void hmb_cache_update(struct nvmev_hmb_cache *cache, uint64_t lpn,
		      const struct ppa *ppa);

/*
 * Record the total L2P lookup latency accumulated for one host I/O.
 * Call once per conv_read / conv_write with the final l2p_lat value.
 */
void hmb_cache_record_io(struct nvmev_hmb_cache *cache, uint64_t l2p_lat_ns);

#endif /* _NVMEVIRT_HMB_CACHE_H */
