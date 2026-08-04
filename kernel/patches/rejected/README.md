# Rejected patches

Patches that were built, flashed and **measured not to work**. Kept so nobody
re-derives them.

Nothing here is applied: `.apply_kernel_patches` explicitly prunes this
directory. That prune is load-bearing — the stage derives the target project
from the path under `kernel/patches/`, so without it this directory resolves to
`kernel/source/rejected`, which does not exist, and the build aborts. (It did
exactly that once, which is how the prune came to be written.)

## 0002-gs201-dwc3-cap-at-high-speed.patch — DOES NOT CAP HOST MODE

**Intent:** the traced root event behind the "dongle wedge" is the SuperSpeed
link failing RECOVERY (`Link:Inactive` / `Change: PLC`, 140ms before any xHCI
trouble — see `project_felix_xhci_hc_died_under_load`). If the link never
trains at SuperSpeed, that failure becomes structurally impossible, and 480 Mb/s
is still ~6x what the OTA path needs.

**Why it was rejected — measured on 34291FDHS000WV 2026-08-04:**

Built, flashed to slot A via `pixel-ota update`, booted. The property IS live:

    /sys/firmware/fdt: "high-speed" present
    dtbo.img: high-speed x11, super-speed-plus x0

...and the dongle enumerated at **5000 Mb/s anyway**:

    2-1: 0bda:8153 usbspeed=5000Mb/s
    root hubs: usb1=480 usb2=10000

**Root reason (source):** `maximum-speed` governs the dwc3 **gadget** role.
`aosp/drivers/usb/dwc3/host.c` builds the property list handed to xHCI and it
contains no speed limit at all (only things like `usb2-lpm-disable`), so
host-mode enumeration is unaffected. `dwc->maximum_speed` is otherwise used only
for PHY register setup and gadget paths.

**Worse than inert:** because it *does* bind the gadget role, it silently caps
the CDC-NCM USB gadget at High Speed — a side effect we never wanted.

## Also tried at runtime and rejected: unbind the SS root hub

    echo usb2 > /sys/bus/usb/drivers/usb/unbind      # remove SS root hub
    echo 1 > .../dwc3_exynos_otg_id; echo 0 > ...    # force host re-init

Self-defeating: the host re-init tears down and recreates the xHCI controller,
which **re-registers both root hubs**, undoing the unbind. The dongle came back
at 5000 Mb/s. Unbinding alone (without the re-init) does not work either — the
peripheral has no reason to re-train, so no NIC appears at all and the
self-healing rebind fires.

## What is left, if HS-only is still wanted

* **A USB 2.0-only cable or hub** between phone and dongle. The SS pins are
  simply not wired, so the link cannot train SuperSpeed. Free, reliable, and
  trivially specified for a fleet build-out — but it is a hardware answer, not
  a software one.
* Preventing xHCI from registering the USB3 shared HCD at all (driver change),
  or bringing the SS PHY up disabled. Neither is a DT one-liner.

Long-term the real answer is the **mainline** track, which carries its own gs201
SS PMA tuning; see [[project_gs201_usb_pma_port]].
