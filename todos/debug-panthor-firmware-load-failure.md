# Debug why panthor firmware load still fails

## What's broken

On the 2026-05-03 boot, panthor probe still fails with ENOENT trying to load the Mali CSF firmware:

```
[28.543515] panthor 28000000.gpu: Direct firmware load for arm/mali/arch10.8/mali_csffw.bin failed with error -2
[28.563370] panthor 28000000.gpu: [drm] *ERROR* Failed to load firmware image 'mali_csffw.bin'
[28.580762] panthor 28000000.gpu: probe with driver panthor failed with error -2
```

This is *not* "the firmware is missing from the OTA" — the felix vendor partition ships five versions of the CSF blob:

```
rootfs/vendor-firmware/extracted/firmware/mali_csffw-r52p0.bin
rootfs/vendor-firmware/extracted/firmware/mali_csffw-r53p0.bin
rootfs/vendor-firmware/extracted/firmware/mali_csffw-r54p0.bin
rootfs/vendor-firmware/extracted/firmware/mali_csffw-r54p1.bin
rootfs/vendor-firmware/extracted/firmware/mali_csffw-r54p2.bin
```

And [Makefile:106-118](Makefile#L106-L118) already includes a step that's *meant* to fix this — it rsyncs `extracted/firmware/` into `/vendor/firmware/` on the sysroot, then drops a symlink:

```make
sudo mkdir -p $(SYSROOT_DIR)/vendor/firmware/arm/mali/arch10.8
sudo ln -sf ../../../mali_csffw-r54p2.bin \
    $(SYSROOT_DIR)/vendor/firmware/arm/mali/arch10.8/mali_csffw.bin
```

So at flash time the rootfs *should* have `/vendor/firmware/arm/mali/arch10.8/mali_csffw.bin → ../../../mali_csffw-r54p2.bin`, and `firmware_class.path=/vendor/firmware` (set by `.build_boot` in the kernel cmdline) tells the firmware loader to search there. The fact that probe still fails with `-ENOENT` means one of the following went wrong.

## Hypotheses, ranked by likelihood

**H1: Stale image — current flashed boot doesn't include the symlink commit.**
The symlink step was added in commit `6a34569` (`feat: AOSP UFS vendor-driver graft onto mainline`). Confirm with `git log --oneline 6a34569 -- Makefile` and check `git log --since=<flash-date> -- Makefile`. If the device was flashed before that commit, the running rootfs.img has no symlink and a rebuild + reflash is the entire fix. **Check this first** — it's the cheapest hypothesis to falsify and the most likely.

**H2: r54p2 is not the right firmware release for arch10.8.**
Panthor builds the firmware path from the live GPU id at [kernel/source/drivers/gpu/drm/panthor/panthor_fw.c:794-797](kernel/source/drivers/gpu/drm/panthor/panthor_fw.c#L794-L797):

```c
snprintf(fw_path, sizeof(fw_path), "arm/mali/arch%d.%d/%s",
         (u32)GPU_ARCH_MAJOR(ptdev->gpu_info.gpu_id),
         (u32)GPU_ARCH_MINOR(ptdev->gpu_info.gpu_id),
         CSF_FW_NAME);
```

The boot log line `Mali-G710 id 0xa862 major 0x0 minor 0x0 status 0x4` reports the *product* major/minor (both 0x0), not the *arch* major/minor — those are extracted from `gpu_id` via different macros and aren't logged. The `arm/mali/arch10.8/...` path in the request_firmware error is the one panthor computed, so that part is correct for *this* GPU. The question is whether `mali_csffw-r54p2.bin` is actually the arch10.8 firmware. The `rXXpY` naming is ARM's firmware release version; release-to-arch mapping isn't in the kernel tree. Cross-check by:

- Looking at the original AOSP kernel build artifacts in [kernel/source.aosp-backup/](kernel/source.aosp-backup/) — whichever `mali_csffw-rXXpY.bin` the AOSP driver loaded for this device is the safe choice.
- Looking at the panthor MODULE_FIRMWARE list at [kernel/source/drivers/gpu/drm/panthor/panthor_fw.c:1496-1502](kernel/source/drivers/gpu/drm/panthor/panthor_fw.c#L1496-L1502) — the seven declared paths (arch10.8, 10.10, 10.12, 11.8, 12.8, 13.8, 14.8) tell us *which* archs panthor knows about, not which release version they map to.
- Reading the binary header of each `mali_csffw-rXXpY.bin` (panthor checks `CSF_FW_BINARY_HEADER_MAGIC = 0xc3f13a6e` and `major = 0`); the headers contain version metadata that may identify the arch.

If r54p2 is wrong, try r54p0, r54p1, then walking back through r53p0 / r52p0.

**H3: The symlink is on disk but the firmware loader can't follow it.**
Less likely — kernel `request_firmware` uses `kernel_read_file_from_path`, which does follow symlinks. But worth ruling out by replacing the symlink with a hardlink or an actual copy in the Makefile and reflashing:

```make
sudo cp $(VENDOR_FIRMWARE_STAGE)/firmware/mali_csffw-r54p2.bin \
    $(SYSROOT_DIR)/vendor/firmware/arm/mali/arch10.8/mali_csffw.bin
```

**H4: `firmware_class.path` isn't being honored at all.**
Verify `cat /sys/module/firmware_class/parameters/path` on the running device; should print `/vendor/firmware`. If it's empty, the cmdline arg didn't take effect — check [Makefile:219+ (`.build_boot`)](Makefile#L219) for the cmdline assembly.

## Investigation order

1. **Confirm the running boot includes the symlink commit.** Compare `git log --oneline -1 6a34569 HEAD` against the flashed boot's build timestamp. If older → rebuild + reflash → done.
2. **If still failing post-reflash**: log into the device, `ls -la /vendor/firmware/arm/mali/arch10.8/` to confirm the symlink resolves; `readlink -f` it; `stat` the target. If broken, the Makefile produced the wrong link.
3. **If symlink is fine and target exists**: switch r54p2 → r54p0 in the Makefile, rebuild, reflash, retry. Walk through versions until panthor's header check passes (the failure mode changes from `-ENOENT` to a different error in `panthor_fw_load`'s header parsing if the file is found but rejected).
4. **If all five versions fail header check**: the panthor ABI in this kernel is newer than what the felix OTA ships — would need to source firmware from upstream linux-firmware.git instead of the OTA.

## Verification when fixed

Successful boot should show panthor finishing probe and registering a DRM render node:

- No `Failed to load firmware image` in dmesg
- `ls /dev/dri/` shows `card0` and `renderD128`
- `lsmod | grep panthor` shows the driver loaded with refcount > 0

## Why this matters

No GPU = no `panfrost`/`panthor` accel = software-only rendering for anything that tries to use DRM/KMS. kmscon falls back to dumb-fb so the console works either way, but Wayland compositors and anything that wants GLES/Vulkan will refuse to start until panthor probes cleanly. Lower priority than UART or A/B slot fixes, but a prerequisite for any graphical userspace work down the road.

## Context references

- Boot log evidence: dmesg lines `[28.543515]`, `[28.563370]`, `[28.580762]` from 2026-05-03.
- Existing Makefile symlink step: [Makefile:106-118](Makefile#L106-L118).
- Panthor firmware loader: [kernel/source/drivers/gpu/drm/panthor/panthor_fw.c:786-820](kernel/source/drivers/gpu/drm/panthor/panthor_fw.c#L786-L820).
- AOSP-tree reference for which firmware version was originally used: [kernel/source.aosp-backup/](kernel/source.aosp-backup/).
