# lwis

- **AOSP path**: `private/google-modules/lwis/`
- **Mainline counterpart**: **NONE** (Google-internal framework; closest analogue in spirit is V4L2 + media-controller, which has a totally different UABI)
- **Status**: not-ported
- **Boot-relevance score**: 1/10

## What it does

LWIS = "Light Weight Image Sensor". Google's bespoke kernel framework for camera HALs to talk directly to image sensors and surrounding ICs (PMICs, EEPROMs, AF/OIS actuators, flash drivers) over I2C, SPI, IOREG, GPIO, regulators, clocks, pinctrl, and PHY without going through V4L2. Top-level `lwis_device.c` registers a chardev per device-tree node; per-bus device files (`lwis_device_i2c.c`, `lwis_device_spi.c`, `lwis_device_ioreg.c`, `lwis_device_slc.c`, `lwis_device_top.c`, `lwis_device_dpm.c`, `lwis_device_test.c`) plug into a common ioctl/transaction/event/fence layer (`lwis_ioctl.c`, `lwis_transaction.c`, `lwis_event.c`, `lwis_fence.c`, `lwis_periodic_io.c`). The whole thing is a userspace-driven register-poke framework so the camera HAL can sequence sensor programming with deterministic timing and DMA-fence integration. Depends on `VIDEO_GOOGLE`.

## Mainline equivalent

None. Mainline cameras use V4L2 sub-devices + the media controller (`drivers/media/`), which is the opposite philosophy: kernel drives the sensor, userspace negotiates formats. There is no out-of-tree-style register-poke framework upstream and no path to upstream one — it's been tried for similar Qualcomm CAMSS internals and bounced.

## Differences vs AOSP / what's missing

Entire framework is missing. Porting LWIS is not just "add a driver"; it's "add a camera UABI that no other kernel has", and even then you'd need Google's libcamera/camera-HAL userspace to use it. There is no upstream direction for this code.

## Boot-relevance reasoning

Cameras are not on the boot path at all. The framework also doesn't probe in a way that would hold up boot (each LWIS device just exposes a chardev). Score is 1 — completely orthogonal to the UFS blocker and to any console-only boot.
