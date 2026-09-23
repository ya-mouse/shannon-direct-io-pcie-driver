// SPDX-License-Identifier: GPL-2.0
/*
 * tests/gfp-xlate-harness.c -- development-only userspace test for
 * shannon_gfp_xlate() / shannon_slab_flags_xlate() in shannon_gfp_legacy.h.
 *
 * This file is NOT part of the module build (Kbuild compiles only the shannon_*
 * wrapper objects).  Run it through scripts/test-gfp-xlate.sh, which generates
 * the modern GFP_ and SLAB_ macro values from a real kernel git tree and injects
 * them with -include, so the assertions below are checked against the actual
 * encoding of a specific kernel release rather than against remembered values.
 *
 * Why it matters: the flag translation is invisible at runtime.  A wrong
 * mapping does not fail to load or fail to build -- it silently changes
 * allocation behaviour (worst case: turning a GFP into __GFP_NOFAIL).  The only
 * cheap way to keep it honest across kernel versions is to re-run this against
 * every kernel the driver is ported to.
 *
 * Manual use, if you have already written a stub header:
 *   cc -Wall -Wextra -I. -include /tmp/stub-v6.8.h \
 *      tests/gfp-xlate-harness.c -o /tmp/h && /tmp/h
 */
#include <stdio.h>
#include <stdlib.h>

#include "shannon_gfp_legacy.h"

static int checks, failures;

static void expect_eq(const char *what, unsigned long got, unsigned long want)
{
	checks++;
	if (got != want) {
		failures++;
		printf("  FAIL  %-46s got %#lx want %#lx\n", what, got, want);
	} else {
		printf("  ok    %-46s %#lx\n", what, got);
	}
}

static void expect_true(const char *what, int cond)
{
	checks++;
	if (!cond) {
		failures++;
		printf("  FAIL  %s\n", what);
	} else {
		printf("  ok    %s\n", what);
	}
}

#define X(v)	SHANNON_GFP_RAW(shannon_gfp_xlate(v))

int main(void)
{
	unsigned int modern[] = {
		SHANNON_GFP_RAW(GFP_KERNEL), SHANNON_GFP_RAW(GFP_NOIO),
		SHANNON_GFP_RAW(GFP_NOFS), SHANNON_GFP_RAW(GFP_ATOMIC),
		SHANNON_GFP_RAW(GFP_NOWAIT),
	};
	unsigned int i;

	printf("kernel under test: %s encoding (LINUX_VERSION_CODE=%d)\n",
	       SHANNON_GFP_LEGACY_KERNEL ? "LEGACY (<=v4.3)" : "modern (>=v4.4)",
#ifdef LINUX_VERSION_CODE
	       LINUX_VERSION_CODE
#else
	       0
#endif
	);
	printf("  GFP_KERNEL=%#x GFP_NOIO=%#x GFP_ATOMIC=%#x GFP_NOWAIT=%#x __GFP_NOWARN=%#x\n",
	       SHANNON_GFP_RAW(GFP_KERNEL), SHANNON_GFP_RAW(GFP_NOIO),
	       SHANNON_GFP_RAW(GFP_ATOMIC), SHANNON_GFP_RAW(GFP_NOWAIT),
#ifdef __GFP_NOWARN
	       SHANNON_GFP_RAW(__GFP_NOWARN)
#else
	       0
#endif
	);

#if SHANNON_GFP_LEGACY_KERNEL
	/*
	 * On a kernel whose encoding matches the core's, the translation must be
	 * the identity -- touching the values would be the bug.
	 */
	printf("\n[identity on a legacy kernel]\n");
	expect_eq("xlate(0x10) stays 0x10", X(SHANNON_LEGACY_GFP_NOIO), 0x10);
	expect_eq("xlate(0x200) stays 0x200", X(SHANNON_LEGACY_GFP_NOWARN), 0x200);
	expect_eq("xlate(0x220) stays 0x220", X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN), 0x220);
#else
	/*
	 * The three values actually baked into *.o_shipped, mapped onto the
	 * intent they had in the vendor's 2.6.x/3.x gfp.h.
	 */
	printf("\n[legacy values found in *.o_shipped]\n");
	expect_eq("0x10  (GFP_NOIO, 127 sites) -> GFP_NOIO",
		  X(SHANNON_LEGACY_GFP_NOIO), SHANNON_GFP_RAW(GFP_NOIO));
	expect_eq("0x220 (GFP_ATOMIC|NOWARN, 26 sites) -> GFP_ATOMIC|__GFP_NOWARN",
		  X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN),
		  SHANNON_GFP_RAW(GFP_ATOMIC) | SHANNON_GFP_RAW(__GFP_NOWARN));
	/*
	 * Legacy 0x200 is __GFP_NOWARN *alone*: quiet, and with no __GFP_WAIT so
	 * it could not sleep for reclaim either.  The faithful modern spelling is
	 * __GFP_NOWARN plus background (kswapd) reclaim -- which is exactly what
	 * GFP_NOWAIT means since commit 16f5dfbc851b ("gfp: include __GFP_NOWARN
	 * in GFP_NOWAIT", first in v6.8).  Assert the composition rather than
	 * equality with GFP_NOWAIT, because before v6.8 GFP_NOWAIT was only
	 * __GFP_KSWAPD_RECLAIM and the composition is the part we care about.
	 */
	expect_eq("0x200 (__GFP_NOWARN, 4 sites) -> __GFP_NOWARN|__GFP_KSWAPD_RECLAIM",
		  X(SHANNON_LEGACY_GFP_NOWARN),
		  SHANNON_GFP_RAW(__GFP_NOWARN) |
		  SHANNON_GFP_RAW(__GFP_KSWAPD_RECLAIM));

	printf("\n[translated values are usable]\n");
	expect_true("0x10  result can reclaim (direct or kswapd)",
		    X(SHANNON_LEGACY_GFP_NOIO) & SHANNON_GFP_RAW(__GFP_RECLAIM));
	expect_true("0x220 result can reclaim",
		    X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN) & SHANNON_GFP_RAW(__GFP_RECLAIM));
	expect_true("0x200 result can reclaim",
		    X(SHANNON_LEGACY_GFP_NOWARN) & SHANNON_GFP_RAW(__GFP_RECLAIM));
	expect_true("0x200 result does not sleep (no __GFP_DIRECT_RECLAIM)",
		    !(X(SHANNON_LEGACY_GFP_NOWARN) &
		      SHANNON_GFP_RAW(__GFP_DIRECT_RECLAIM)));
	expect_true("0x220 result keeps __GFP_HIGH (emergency pools)",
		    X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN) & SHANNON_GFP_RAW(__GFP_HIGH));
	expect_true("0x220 result keeps __GFP_NOWARN",
		    X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN) & SHANNON_GFP_RAW(__GFP_NOWARN));

	printf("\n[no catastrophic mistranslation]\n");
	expect_true("no translated value ever gains __GFP_NOFAIL",
		    !(X(SHANNON_LEGACY_GFP_NOIO) & SHANNON_GFP_RAW(__GFP_NOFAIL)) &&
		    !(X(SHANNON_LEGACY_GFP_ATOMIC_NOWARN) & SHANNON_GFP_RAW(__GFP_NOFAIL)) &&
		    !(X(SHANNON_LEGACY_GFP_NOWARN) & SHANNON_GFP_RAW(__GFP_NOFAIL)));
	expect_true("translation is idempotent",
		    X(SHANNON_GFP_RAW(shannon_gfp_xlate(SHANNON_LEGACY_GFP_NOIO))) ==
		    X(SHANNON_LEGACY_GFP_NOIO));
#endif	/* SHANNON_GFP_LEGACY_KERNEL */

	/*
	 * The discriminator must never classify a gfp this driver produced itself
	 * as legacy, or GFP_SHANNON would be silently rewritten.  This is the
	 * property shannon_gfp_assert_native() also enforces at build time.
	 */
	printf("\n[native gfp values pass through untouched]\n");
	expect_eq("xlate(0) == 0", X(0), 0);
	for (i = 0; i < sizeof(modern) / sizeof(modern[0]); i++) {
		char what[64];

		snprintf(what, sizeof(what), "xlate(%#x) is identity", modern[i]);
		expect_eq(what, X(modern[i]), modern[i]);
		snprintf(what, sizeof(what), "%#x not classified legacy", modern[i]);
		expect_true(what, shannon_gfp_is_legacy(modern[i]) == 0);
	}

	printf("\n[slab flags]\n");
	expect_eq("0x2000 (SLAB_HWCACHE_ALIGN, 2 sites) -> SLAB_HWCACHE_ALIGN",
		  shannon_slab_flags_xlate(SHANNON_LEGACY_SLAB_HWCACHE_ALIGN),
		  (unsigned long)SLAB_HWCACHE_ALIGN);
	expect_eq("unknown slab bits are reported",
		  shannon_slab_flags_unknown(SHANNON_LEGACY_SLAB_HWCACHE_ALIGN), 0UL);
	/* on a pre-v6.9 kernel the slab flags need no translation, so by design
	 * nothing is ever reported unknown there */
	if (!shannon_slab_flags_native())
		expect_true("a novel slab bit is reported as unknown",
			  shannon_slab_flags_unknown(0x80000000UL) != 0UL);

	printf("\n%d checks, %d failure(s)\n", checks, failures);
	return failures ? 1 : 0;
}
