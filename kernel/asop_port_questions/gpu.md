# gpu

- **AOSP path**: `private/google-modules/gpu/`
- **Mainline counterpart**: `drivers/gpu/drm/panthor/` (Mali-G710 CSF — gs201's GPU)
- **Status**: not-ported (mainline panthor exists and supports the GPU model, but there is no gs201 platform glue / DT binding wired up for it)
- **Boot-relevance score**: 2/10

## What it does

ARM's `mali_kbase` driver (Bifrost/Valhall family) re-vendored by Google with Pixel-specific extensions in `mali_pixel/`: a memory-group-manager hook that routes GPU allocations through Pixel's allocator, a protected-memory allocator for content protection, a priority control manager for GPU job scheduling, an SLC (system-level-cache) partition manager, and stats glue. `borr_mali_kbase/` is a forked snapshot for a specific generation; `mali_kbase/` is the main tree. The kbase driver is a job-manager / CSF-style userspace-submission GPU driver with its own out-of-tree UABI consumed by the closed-source Mali userspace blob.

## Mainline equivalent

`drivers/gpu/drm/panthor/` is the upstream Mesa-friendly CSF driver and explicitly recognises Mali-G710 (`panthor_hw.c` returns `"Mali-G710"`), which is the GPU IP in gs201/Tensor G2. `drivers/gpu/drm/panfrost/` is the older job-manager driver for pre-CSF Mali parts. Both are real DRM drivers using the upstream UABI; they pair with Mesa's panfrost/panthor Gallium drivers, not the ARM blob.

## Differences vs AOSP / what's missing

The two trees are not comparable line-by-line — `mali_kbase` is a fundamentally different driver from panthor with a different UABI. What's missing for our SoC isn't the core driver (panthor handles G710) but the gs201 platform integration: clocks/regulators/power-domain wiring, the DT binding for the gs201 GPU node, and (for anything more than basic rendering) the Pixel SLC partition glue. Google's mali_pixel SLC/MGM/PMA hooks have no upstream analogue and would need to be redesigned around upstream APIs if they're needed at all.

## Boot-relevance reasoning

The GPU is not on the boot path — Linux boots, mounts root, and runs userspace with the GPU completely powered off. Even if we wanted on-device graphics, kmscon on the serial console works fine without a GPU. Score is 2: legitimately post-boot peripheral, and the existing mainline panthor driver is a much better starting point than porting Google's kbase fork, so this AOSP tree specifically is low-value to port.
