/* Definitions for Shannon hardware/software interface.
 * Copyright (c) 2017, Shannon technology
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef __SHANNON_MEMBLOCK_H
#define __SHANNON_MEMBLOCK_H

#include <linux/types.h>

//#define get_slot_from_lpmt(sdisk, lba)		(((((lba) / ((sdisk)->strip_size * (sdisk)->sdev_count)) * (sdisk)->strip_size)) + (lba) % (sdisk)->strip_size)
#define get_slot_from_lpmt(sdisk, lba)	({	\
	u64 __slot;		\
	u32 _strip_size = (sdisk)->strip_size * (sdisk)->sdev_count;	\
	if ((sdisk)->sdev_count == 1)	\
		__slot = (lba);	\
	else if ((_strip_size & (_strip_size - 1)) == 0)	/* order of 2 */\
		__slot = (((lba) >> find_first_bit((void *)&_strip_size, sizeof(u32) * 8u)) << (sdisk)->strip_size_shift) + ((lba) & ((sdisk)->strip_size - 1));	\
	else	\
		__slot = (((((lba) / ((sdisk)->strip_size * (sdisk)->sdev_count)) << (sdisk)->strip_size_shift)) + ((lba) & ((sdisk)->strip_size - 1)));	\
			\
	__slot;	\
})
#define get_memblock_index_from_slot(sdisk, slot)	((slot) >> (sdisk)->lpmt_array[0].map_table.entries_per_memblock_shift)
#define get_memblock_index_from_lba(sdisk, lba) (get_memblock_index_from_slot((sdisk), get_slot_from_lpmt((sdisk), (lba))))
#define get_memblock_index_first_lba(sdisk, index)	((index) * (sdisk)->lpmt_array[0].map_table.entries_per_memblock * (sdisk)->sdev_count)
#define get_memblock_index_last_lba(sdisk, index)	((((index) + 1) * (sdisk)->lpmt_array[0].map_table.entries_per_memblock * (sdisk)->sdev_count) - 1)
#define get_sdev_id_from_lba(sdisk, lba) ((lba) / (sdisk)->strip_size % (sdisk)->sdev_count)
#define get_lba_from_lpmt_slot(sdev, sdisk, slot)	(((slot) >> (sdisk)->strip_size_shift) * ((sdisk)->strip_size * (sdisk)->sdev_count) + \
		((slot) & ((sdisk)->strip_size - 1)) + (sdev)->sdev_id * (sdisk)->strip_size)

#define increase_memblock_user_count(lpmt, list_index)	(shannon_atomic_inc_return(&(lpmt)->map_table.user_count[(list_index)]))
#define decrease_memblock_user_count(lpmt, list_index)	(shannon_atomic_dec_return(&(lpmt)->map_table.user_count[(list_index)]))
#define get_memblock_user_count(lpmt, list_index)	(shannon_atomic_read(&(lpmt)->map_table.user_count[(list_index)]))
#define smb_lock(lpmt, list_index)	(shannon_atomic_inc_return(&(lpmt)->map_table.memblock_lock[(list_index)]))
#define smb_unlock(lpmt, list_index)	(shannon_atomic_dec_return(&(lpmt)->map_table.memblock_lock[(list_index)]))
#define smb_lock_by_cnt(lpmt, list_index, cnt)	(shannon_atomic_add_return((cnt), &(lpmt)->map_table.memblock_lock[(list_index)]))
#define smb_unlock_by_cnt(lpmt, list_index, cnt)	(shannon_atomic_sub_return((cnt), &(lpmt)->map_table.memblock_lock[(list_index)]))
#define smb_simultaneously_lock(lpmt, list_index)	({	\
	if (smb_lock((lpmt), (list_index)) < 0)	\
		while(shannon_atomic_read(&(lpmt)->map_table.memblock_lock[(list_index)]) < 0)	\
			;	\
})
#define smb_simultaneously_lock_retry(lpmt, list_index, retry)	({	\
	int __retry_cnt = (retry);	\
	if (__retry_cnt < 0)	\
		__retry_cnt = 0;	\
	smb_lock((lpmt), (list_index));	\
	while (__retry_cnt > 0 &&	\
			shannon_atomic_read(&(lpmt)->map_table.memblock_lock[(list_index)]) < 0)	\
		__retry_cnt--;	\
	if (__retry_cnt == 0)	\
		smb_unlock((lpmt), (list_index));	\
	__retry_cnt;	\
})
#define smb_simultaneously_unlock(lpmt, list_index)	(smb_unlock((lpmt), (list_index)))
// Before invoking this, must "simultaneously" lock the smb first.
#define smb_exclusively_trylock(lpmt, list_index)	({		\
	u32 __ret;	\
	if ((smb_unlock_by_cnt((lpmt), (list_index), 0xffff)) == (0 - 0xffff + 1))	\
		__ret = 1;	\
	else {\
		__ret = 0;	\
		smb_lock_by_cnt((lpmt), (list_index), 0xffff);	\
	}	\
	__ret;		\
})
#define smb_exclusively_unlock(lpmt, list_index)	(smb_lock_by_cnt((lpmt), (list_index), 0xffff))

/*
 * Must ensure that MAPTABLE_MEMBLOCK_SIZE >= logicb_size, and
 * TEMPTABLE_MEMBLOCK_SIZE <= logicb_size.
 * Otherwise fastboot won't be enabled.
 */
typedef u32 lpmt_maptable_t;
typedef u8 lpmt_temptable_t;
#define LOGICB_SIZE_SHIFT			(12)
#define MAPTABLE_TYPE_SIZE_SHIFT	(2)
#define TEMPTABLE_TYPE_SIZE_SHIFT	(0)
#define ENTRIES_PER_MEMBLOCK_SHIFT	(20)
#define ENTRIES_PER_MEMBLOCK		(1 << ENTRIES_PER_MEMBLOCK_SHIFT)
#define MAP_TABLE_ENTRY_SIZE		(sizeof(lpmt_maptable_t) + sizeof(lpmt_temptable_t))
#define MAPTABLE_MEMBLOCK_SIZE_SHIFT	(MAPTABLE_TYPE_SIZE_SHIFT + ENTRIES_PER_MEMBLOCK_SHIFT)
#define TEMPTABLE_MEMBLOCK_SIZE_SHIFT	(TEMPTABLE_TYPE_SIZE_SHIFT + ENTRIES_PER_MEMBLOCK_SHIFT)
#define MAPTABLE_MEMBLOCK_SIZE		(1 << MAPTABLE_MEMBLOCK_SIZE_SHIFT)
#define TEMPTABLE_MEMBLOCK_SIZE		(1 << TEMPTABLE_MEMBLOCK_SIZE_SHIFT)
#define LOGICBS_PER_MAPTABLE_SHIFT	(MAPTABLE_MEMBLOCK_SIZE_SHIFT - LOGICB_SIZE_SHIFT)
#define LOGICBS_PER_TEMPTABLE_SHIFT	(TEMPTABLE_MEMBLOCK_SIZE_SHIFT - LOGICB_SIZE_SHIFT)
#define MAPTABLE_TYPE			(0)
#define TEMPTABLE_TYPE			(1)

struct maptable_memblock {
	lpmt_maptable_t maptable_slot[ENTRIES_PER_MEMBLOCK];
	lpmt_temptable_t temptable_slot[ENTRIES_PER_MEMBLOCK];
};

#define LPMT_INVALID	(~0x0u)

struct scatter_memblock {
	u64 total_size;
	shannon_atomic64_t valid_count;
	u32 memblock_count;
	u64 memblock_size;
	u32 entry_size;
	u32 entries_per_memblock;
	u32 entries_per_memblock_shift;
#define MEMBLOCK_LOCK_CNT	(16)		// it must be order of 2
	shannon_mutex_t memblock_alloc_lock[MEMBLOCK_LOCK_CNT];

	shannon_atomic_t *memblock_lock;
	shannon_atomic_t *user_count;
	struct maptable_memblock **memblock_list;
};

extern int check_and_alloc_memblock(struct scatter_memblock *smb, logicb64_t offset);

#endif /* __SHANNON_MEMBLOCK_H */
