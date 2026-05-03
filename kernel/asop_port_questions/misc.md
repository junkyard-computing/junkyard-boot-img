# misc

- **AOSP path**: `private/google-modules/misc/` (subdirs: `sscoredump/`, `build/`)
- **Mainline counterpart**: NONE for `sscoredump`; closest analogs in spirit are `drivers/remoteproc/remoteproc_coredump.c` and `kernel/panic.c`'s pstore/devcoredump paths
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

Two things, both small:

- `sscoredump/sscoredump_test.c` and `sscoredump_sample_test.c` — a *test* module for the
  "subsystem coredump" facility. Note the actual `sscoredump` driver isn't here — it lives
  under `private/google-modules/soc/gs/` (the BSP); this module just exercises it from
  userspace by registering a test platform device, kicking off N concurrent fake-crash
  threads, and verifying that the ssc framework collects the right segments. Bound by
  `CONFIG_SUBSYSTEM_COREDUMP_TEST` and depends on `CONFIG_SUBSYSTEM_COREDUMP`.
- `build/version.build` — a single text file with build-version metadata. Not a driver.

The real subsystem-coredump driver (registered via `<linux/platform_data/sscoredump.h>`)
is what the AOC, GPU (mali), modem, and other coprocessor drivers call when they detect
a firmware crash, dumping their state out a `/dev/sscd_*` chardev for userspace
crash-reporters to pick up.

## Mainline equivalent

No upstream `sscoredump`. Mainline coprocessor drivers use `dev_coredumpv()` /
`dev_coredumpsg()` from `drivers/base/devcoredump.c`, which exposes the dump via sysfs
under `/sys/class/devcoredump/`. Same intent, different chardev/sysfs shape, no
multi-segment metadata, no priority queueing.

## Differences vs AOSP / what's missing

If we ever want the Pixel AOC/GPU/modem firmware crash dumps to surface to userspace in
the AOSP-compatible way, we'd need to port the actual `sscoredump` driver (which lives in
`soc/gs/drivers/misc/`, not here) — but anything in mainline that wants to dump coredumps
just calls `dev_coredumpv()` instead. The test module here is uninteresting in
isolation.

## Boot-relevance reasoning

A coredump-collection facility doesn't influence whether the kernel boots; it influences
what happens *after* something has already crashed. Score 2 — not boot-relevant, but a
real future utility if we want to debug AOC / mali firmware faults without parsing
dmesg by hand.
