/* SPDX-License-Identifier: GPL-2.0 */
/*
 * shannon_gfp_legacy.h -- translate the allocator/slab flag *encodings* frozen
 * into the precompiled proprietary core (*.o_shipped).
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The core was compiled once, long ago, against the shannon_*() shim.  It never
 * calls the kernel's allocators directly; it passes flag values to wrappers that
 * forward them.  Those values are *numbers* baked into .text at vendor build
 * time, so they carry the flag encoding of the vendor's kernel, not ours.
 *
 * Evidence (reproduce with scripts/probe-shipped-flags.py):
 *
 *   .comment in all nine objects:  GCC: (GNU) 4.1.2 20080704 (Red Hat 4.1.2-54)
 *   baked gfp immediates:          0x10 (127 sites), 0x220 (26), 0x200 (4)
 *   baked slab_flags immediate:    0x2000 (2 sites)
 *
 * Decoded against include/linux/gfp.h of the 2.6.x/3.x era:
 *
 *   __GFP_WAIT   0x10    => GFP_NOIO   == __GFP_WAIT              == 0x10
 *   __GFP_HIGH   0x20    => GFP_ATOMIC == __GFP_HIGH              == 0x20
 *   __GFP_NOWARN 0x200   => 0x220 is GFP_ATOMIC|__GFP_NOWARN
 *   SLAB_HWCACHE_ALIGN   == 0x2000
 *
 * and shannon_kcore.h still spells the driver's house style out as
 * "#define GFP_SHANNON GFP_NOIO", which is exactly the 0x10 the core passes.
 * That encoding is only valid up to v4.3: the __GFP_WAIT -> __GFP_RECLAIM split
 * (v4.4) moved every bit above the zone selector.  On a modern kernel 0x10 is
 * ___GFP_RECLAIMABLE, so the core's GFP_NOIO silently becomes "no reclaim at
 * all", and 0x200 is an unassigned bit (v6.3+ discarded ___GFP_ATOMIC).
 *
 * Consequences observed/verified against the upstream tree:
 *   - gfpflags_allow_blocking() is false, so every core allocation behaves like
 *     GFP_NOWAIT and returns NULL under pressure instead of reclaiming.
 *   - mm/mempool.c gates the wait-for-refill loop on __GFP_DIRECT_RECLAIM, so
 *     alloc_sbio() -> shannon_mempool_alloc() loses the mempool's forward
 *     progress guarantee in the I/O submission path.
 *   - since v6.19 (commit 07003531e03c) __vmalloc validates gfp against
 *     GFP_VMALLOC_SUPPORTED, which excludes ___GFP_RECLAIMABLE:
 *       Unexpected gfp: 0x10 ... Fixing up to gfp: 0x0 ... Fix your code!
 *     and the map-table allocation is then made with gfp 0.
 *   - since v6.9 (commit cc61eb851c9a) SLAB_HWCACHE_ALIGN is BIT(4), so the
 *     core's 0x2000 silently selects a different slab flag (SLAB_NO_MERGE on a
 *     distro config) and the caches lose hardware cacheline alignment.
 *
 * THE DISCRIMINATOR PROBLEM
 * -------------------------
 * These wrappers are called from two populations: the precompiled core (legacy
 * encoding) and the open-source wrappers themselves (this kernel's encoding,
 * e.g. GFP_SHANNON/GFP_ATOMIC/GFP_NOWAIT).  They cannot be told apart by the
 * call site, so shannon_gfp_xlate() classifies the *value*:
 *
 *   - 0 is never translated;
 *   - any bit above 0xffff cannot be legacy (the legacy encoding is 16 bits);
 *   - any value carrying a modern reclaim bit (__GFP_RECLAIM, i.e.
 *     __GFP_DIRECT_RECLAIM or __GFP_KSWAPD_RECLAIM) is already modern.  Every
 *     usable gfp on a modern kernel carries one -- GFP_KERNEL, GFP_NOIO,
 *     GFP_NOFS, GFP_ATOMIC and GFP_NOWAIT all do -- while none of the three
 *     legacy values the core passes does.
 *
 * shannon_gfp_assert_native() turns that assumption into a build failure rather
 * than a silent mistranslation, should a future kernel ever define a reclaim-free
 * GFP_* that this driver uses.
 *
 * This header is deliberately free of kernel-only dependencies so that
 * tests/gfp-xlate-harness.c can compile it in userspace against the *real*
 * gfp values of any kernel tag (see scripts/test-gfp-xlate.sh).
 */
#ifndef __SHANNON_GFP_LEGACY_H
#define __SHANNON_GFP_LEGACY_H

/* ------------------------------------------------------------------ legacy */

/* include/linux/gfp.h as the vendor's kernel had it (2.6.x .. v4.3) */
#define SHANNON_LEGACY___GFP_DMA		0x0001u
#define SHANNON_LEGACY___GFP_HIGHMEM		0x0002u
#define SHANNON_LEGACY___GFP_DMA32		0x0004u
#define SHANNON_LEGACY___GFP_MOVABLE		0x0008u
#define SHANNON_LEGACY___GFP_WAIT		0x0010u
#define SHANNON_LEGACY___GFP_HIGH		0x0020u
#define SHANNON_LEGACY___GFP_IO			0x0040u
#define SHANNON_LEGACY___GFP_FS			0x0080u
#define SHANNON_LEGACY___GFP_COLD		0x0100u
#define SHANNON_LEGACY___GFP_NOWARN		0x0200u
#define SHANNON_LEGACY___GFP_REPEAT		0x0400u
#define SHANNON_LEGACY___GFP_NOFAIL		0x0800u
#define SHANNON_LEGACY___GFP_NORETRY		0x1000u
#define SHANNON_LEGACY___GFP_NO_GROW		0x2000u
#define SHANNON_LEGACY___GFP_COMP		0x4000u
#define SHANNON_LEGACY___GFP_ZERO		0x8000u

#define SHANNON_LEGACY_GFP_ZONE_MASK \
	(SHANNON_LEGACY___GFP_DMA | SHANNON_LEGACY___GFP_HIGHMEM | \
	 SHANNON_LEGACY___GFP_DMA32 | SHANNON_LEGACY___GFP_MOVABLE)

#define SHANNON_LEGACY_GFP_ALL_MASK		0xffffu

/*
 * The three composites actually present in *.o_shipped, named so that call sites
 * and tests read as intent rather than as hex.
 */
#define SHANNON_LEGACY_GFP_NOIO		SHANNON_LEGACY___GFP_WAIT	/* 0x10  */
#define SHANNON_LEGACY_GFP_ATOMIC	SHANNON_LEGACY___GFP_HIGH	/* 0x20  */
#define SHANNON_LEGACY_GFP_NOWARN	SHANNON_LEGACY___GFP_NOWARN	/* 0x200 */
#define SHANNON_LEGACY_GFP_ATOMIC_NOWARN \
	(SHANNON_LEGACY___GFP_HIGH | SHANNON_LEGACY___GFP_NOWARN)	/* 0x220 */

/* include/linux/slab.h as the vendor's kernel had it */
#define SHANNON_LEGACY_SLAB_DEBUG_FREE		0x00000100UL
#define SHANNON_LEGACY_SLAB_DEBUG_INITIAL	0x00000200UL
#define SHANNON_LEGACY_SLAB_RED_ZONE		0x00000400UL
#define SHANNON_LEGACY_SLAB_POISON		0x00000800UL
#define SHANNON_LEGACY_SLAB_HWCACHE_ALIGN	0x00002000UL
#define SHANNON_LEGACY_SLAB_CACHE_DMA		0x00004000UL
#define SHANNON_LEGACY_SLAB_MUST_HWCACHE_ALIGN	0x00008000UL
#define SHANNON_LEGACY_SLAB_STORE_USER		0x00010000UL
#define SHANNON_LEGACY_SLAB_RECLAIM_ACCOUNT	0x00020000UL
#define SHANNON_LEGACY_SLAB_PANIC		0x00040000UL
#define SHANNON_LEGACY_SLAB_DESTROY_BY_RCU	0x00080000UL
#define SHANNON_LEGACY_SLAB_MEM_SPREAD		0x00100000UL

#define SHANNON_LEGACY_SLAB_KNOWN_MASK \
	(SHANNON_LEGACY_SLAB_DEBUG_FREE | SHANNON_LEGACY_SLAB_DEBUG_INITIAL | \
	 SHANNON_LEGACY_SLAB_RED_ZONE | SHANNON_LEGACY_SLAB_POISON | \
	 SHANNON_LEGACY_SLAB_HWCACHE_ALIGN | SHANNON_LEGACY_SLAB_CACHE_DMA | \
	 SHANNON_LEGACY_SLAB_MUST_HWCACHE_ALIGN | \
	 SHANNON_LEGACY_SLAB_STORE_USER | \
	 SHANNON_LEGACY_SLAB_RECLAIM_ACCOUNT | SHANNON_LEGACY_SLAB_PANIC | \
	 SHANNON_LEGACY_SLAB_DESTROY_BY_RCU | SHANNON_LEGACY_SLAB_MEM_SPREAD)

/* ------------------------------------------------- is this kernel legacy? */

/*
 * __GFP_WAIT exists exactly on the kernels whose encoding the core was built
 * against; it was split into __GFP_DIRECT_RECLAIM/__GFP_KSWAPD_RECLAIM in v4.4.
 * Testing for the macro beats hard-coding a version number.
 */
#ifdef __GFP_WAIT
#define SHANNON_GFP_LEGACY_KERNEL	1
#else
#define SHANNON_GFP_LEGACY_KERNEL	0
#endif

/*
 * Cast helper: the shim's shannon_gfp_t and the kernel's gfp_t are both
 * "unsigned __bitwise__".  The translation below is pure integer arithmetic (so
 * that tests/gfp-xlate-harness.c can run it in userspace), so strip __bitwise
 * exactly once, here, rather than sprinkling __force casts over every call site.
 * Passing a gfp_t straight into an "unsigned int" parameter would be a sparse
 * error; SHANNON_GFP_RAW() is how callers hand a gfp to these helpers.
 */
#ifndef __force
#define __force
#endif
#define SHANNON_GFP_RAW(x)	((unsigned int)(__force gfp_t)(x))

/* ------------------------------------------------------------- translation */

/*
 * Decode a legacy (2.6.x/3.x) gfp mask into this kernel's encoding.
 *
 * Two deliberate judgement calls, both documented because they change behaviour
 * rather than merely re-spelling it:
 *
 *  - legacy __GFP_HIGH is mapped to GFP_ATOMIC, not to a bare __GFP_HIGH.  In
 *    the legacy encoding GFP_ATOMIC *was* __GFP_HIGH, and a modern bare
 *    __GFP_HIGH cannot even wake kswapd, which would be far more restrictive
 *    than what the core asked for.
 *  - a mask that ends up with no reclaim bit at all gains
 *    __GFP_KSWAPD_RECLAIM.  The legacy encoding had no separate kswapd bit, so
 *    "no __GFP_WAIT" could not express "background reclaim only"; the closest
 *    non-blocking modern equivalent is GFP_NOWAIT.  This is what turns the
 *    core's 0x200 (__GFP_NOWARN) into GFP_NOWAIT instead of a gfp that can
 *    never succeed under pressure.
 *
 * __GFP_COLD (0x100) and __GFP_NO_GROW (0x2000) have no modern equivalent
 * (dropped in v4.14 and long-gone slab internals respectively) and are dropped.
 */
#if SHANNON_GFP_LEGACY_KERNEL

/*
 * This kernel's encoding IS the one frozen into the core, so every transform
 * here is the identity.  The real decode below must not even be compiled: it
 * names __GFP_RECLAIM / __GFP_KSWAPD_RECLAIM, which do not exist before v4.4.
 */
static inline unsigned int shannon_gfp_decode_legacy(unsigned int legacy)
{
	return legacy;
}

static inline int shannon_gfp_is_legacy(unsigned int v)
{
	(void)v;
	return 0;
}

#else	/* !SHANNON_GFP_LEGACY_KERNEL */

static inline unsigned int shannon_gfp_decode_legacy(unsigned int legacy)
{
	unsigned int g = 0;

	/* Zone selector bits 0..3 have never moved. */
	g |= legacy & SHANNON_LEGACY_GFP_ZONE_MASK;

	if (legacy & SHANNON_LEGACY___GFP_WAIT)
		g |= SHANNON_GFP_RAW(__GFP_RECLAIM);
	if (legacy & SHANNON_LEGACY___GFP_HIGH)
		g |= SHANNON_GFP_RAW(GFP_ATOMIC);
	if (legacy & SHANNON_LEGACY___GFP_IO)
		g |= SHANNON_GFP_RAW(__GFP_IO);
	if (legacy & SHANNON_LEGACY___GFP_FS)
		g |= SHANNON_GFP_RAW(__GFP_FS);
	if (legacy & SHANNON_LEGACY___GFP_NOWARN)
		g |= SHANNON_GFP_RAW(__GFP_NOWARN);
	if (legacy & SHANNON_LEGACY___GFP_REPEAT)
#ifdef __GFP_RETRY_MAYFAIL
		g |= SHANNON_GFP_RAW(__GFP_RETRY_MAYFAIL);	/* renamed v4.13 */
#else
		g |= SHANNON_GFP_RAW(__GFP_REPEAT);
#endif
	if (legacy & SHANNON_LEGACY___GFP_NOFAIL)
		g |= SHANNON_GFP_RAW(__GFP_NOFAIL);
	if (legacy & SHANNON_LEGACY___GFP_NORETRY)
		g |= SHANNON_GFP_RAW(__GFP_NORETRY);
	if (legacy & SHANNON_LEGACY___GFP_COMP)
		g |= SHANNON_GFP_RAW(__GFP_COMP);
	if (legacy & SHANNON_LEGACY___GFP_ZERO)
		g |= SHANNON_GFP_RAW(__GFP_ZERO);

	if (!(g & SHANNON_GFP_RAW(__GFP_RECLAIM)))
		g |= SHANNON_GFP_RAW(__GFP_KSWAPD_RECLAIM);

	return g;
}

/*
 * True if `v` is a legacy-encoded gfp rather than one of this kernel's own.
 * See "THE DISCRIMINATOR PROBLEM" above.
 */
static inline int shannon_gfp_is_legacy(unsigned int v)
{
	if (v == 0)
		return 0;
	if (v & ~SHANNON_LEGACY_GFP_ALL_MASK)
		return 0;		/* bit above 0xffff cannot be legacy */
	if (v & SHANNON_GFP_RAW(__GFP_RECLAIM))
		return 0;		/* already carries a modern reclaim bit */
	return 1;
}

#endif	/* SHANNON_GFP_LEGACY_KERNEL */

/*
 * The entry point every gfp-forwarding wrapper must use.  Identity on kernels
 * whose encoding matches the core's, and for values this kernel produced itself.
 */
static inline gfp_t shannon_gfp_xlate(unsigned int in)
{
	if (!shannon_gfp_is_legacy(in))
		return (gfp_t)(__force gfp_t)in;

	return (gfp_t)(__force gfp_t)shannon_gfp_decode_legacy(in);
}

/* Same idea for slab creation flags.  Only the core calls this wrapper. */
/*
 * True when this kernel still spells SLAB_HWCACHE_ALIGN as 0x2000, i.e. the
 * core's baked value is already correct.  Both operands are compile-time
 * constants, so the compiler folds this away; it is written as a value
 * comparison rather than a LINUX_VERSION_CODE test because it then cannot drift
 * out of step with the headers (and needs no <linux/version.h>).  The slab
 * flags became BIT(_SLAB_*) in v6.9, commit cc61eb851c9a.
 */
#define shannon_slab_flags_native() \
	((unsigned long)SLAB_HWCACHE_ALIGN == SHANNON_LEGACY_SLAB_HWCACHE_ALIGN)

static inline unsigned long shannon_slab_flags_xlate(unsigned long legacy)
{
	unsigned long f = 0;

	if (shannon_slab_flags_native())
		return legacy;		/* 0x2000 already means HWCACHE_ALIGN */

	/*
	 * Every flag below except HWCACHE_ALIGN/CACHE_DMA/PANIC/
	 * TYPESAFE_BY_RCU is only defined under CONFIG_SLUB_DEBUG (and
	 * SLAB_RECLAIM_ACCOUNT only under CONFIG_MEMCG), so each needs its own
	 * #ifdef -- this header must compile on any config.  The core only ever
	 * passes SLAB_HWCACHE_ALIGN (0x2000, two call sites in
	 * shannon_alloc_mempool()); the rest are here so that a future core drop
	 * using another flag is translated rather than silently misread.
	 */
	if (legacy & SHANNON_LEGACY_SLAB_HWCACHE_ALIGN)
		f |= SLAB_HWCACHE_ALIGN;
#ifdef SLAB_CONSISTENCY_CHECKS
	if (legacy & SHANNON_LEGACY_SLAB_DEBUG_FREE)
		f |= SLAB_CONSISTENCY_CHECKS;	/* renamed from DEBUG_FREE */
#endif
#ifdef SLAB_RED_ZONE
	if (legacy & SHANNON_LEGACY_SLAB_RED_ZONE)
		f |= SLAB_RED_ZONE;
#endif
#ifdef SLAB_POISON
	if (legacy & SHANNON_LEGACY_SLAB_POISON)
		f |= SLAB_POISON;
#endif
#ifdef SLAB_CACHE_DMA
	if (legacy & SHANNON_LEGACY_SLAB_CACHE_DMA)
		f |= SLAB_CACHE_DMA;
#endif
#ifdef SLAB_STORE_USER
	if (legacy & SHANNON_LEGACY_SLAB_STORE_USER)
		f |= SLAB_STORE_USER;
#endif
#ifdef SLAB_PANIC
	if (legacy & SHANNON_LEGACY_SLAB_PANIC)
		f |= SLAB_PANIC;
#endif
#ifdef SLAB_TYPESAFE_BY_RCU
	if (legacy & SHANNON_LEGACY_SLAB_DESTROY_BY_RCU)
		f |= SLAB_TYPESAFE_BY_RCU;	/* renamed v4.5 */
#endif
#ifdef SLAB_RECLAIM_ACCOUNT
	if (legacy & SHANNON_LEGACY_SLAB_RECLAIM_ACCOUNT)
		f |= SLAB_RECLAIM_ACCOUNT;
#endif
	/*
	 * Dropped, no modern equivalent: SLAB_DEBUG_INITIAL (0x200),
	 * SLAB_MUST_HWCACHE_ALIGN (0x8000), SLAB_MEM_SPREAD (0x100000).
	 */
	return f;
}

/* Bits of `legacy` this translation does not recognise -- log-worthy. */
static inline unsigned long shannon_slab_flags_unknown(unsigned long legacy)
{
	if (shannon_slab_flags_native())
		return 0;
	return legacy & ~SHANNON_LEGACY_SLAB_KNOWN_MASK;
}

/*
 * Compile-time guard for the discriminator: every gfp this driver passes
 * natively must carry a reclaim bit, or shannon_gfp_is_legacy() could mistake
 * it for a legacy value.  Failing the build beats mistranslating silently.
 */
#if defined(BUILD_BUG_ON) && !SHANNON_GFP_LEGACY_KERNEL
#define shannon_gfp_assert_native()					\
do {									\
	BUILD_BUG_ON(!(SHANNON_GFP_RAW(GFP_KERNEL) &			\
		       SHANNON_GFP_RAW(__GFP_RECLAIM)));		\
	BUILD_BUG_ON(!(SHANNON_GFP_RAW(GFP_ATOMIC) &			\
		       SHANNON_GFP_RAW(__GFP_RECLAIM)));		\
	BUILD_BUG_ON(!(SHANNON_GFP_RAW(GFP_NOWAIT) &			\
		       SHANNON_GFP_RAW(__GFP_RECLAIM)));		\
	BUILD_BUG_ON(!(SHANNON_GFP_RAW(GFP_NOIO) &			\
		       SHANNON_GFP_RAW(__GFP_RECLAIM)));		\
	BUILD_BUG_ON(!(SHANNON_GFP_RAW(GFP_NOFS) &			\
		       SHANNON_GFP_RAW(__GFP_RECLAIM)));		\
} while (0)
#else
#define shannon_gfp_assert_native()	do { } while (0)
#endif

#endif /* __SHANNON_GFP_LEGACY_H */
