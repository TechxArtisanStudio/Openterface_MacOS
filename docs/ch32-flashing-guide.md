# CH32 Firmware Flashing Guide

This guide walks you through flashing the **WCH CH32 control chip** — the chip
that handles the keyboard / mouse / HID functionality on Openterface devices.

> **Scope:** This document is only for the *control* chipset (CH32V208 /
> CH32F103). The *video* chipset firmware (MS2109 / MS2109S / MS2130S) uses a
> completely different upgrade path — see
> [firmware-upgrade.md](firmware-upgrade.md#video-firmware-tab) for that.

---

## Table of Contents

- [Supported Products](#supported-products)
- [When Do You Need This?](#when-do-you-need-this)
- [Prerequisites](#prerequisites)
- [Hardware Overview](#hardware-overview)
- [Step-by-Step: Enter ISP (Bootloader) Mode](#step-by-step-enter-isp-bootloader-mode)
- [Step-by-Step: Flash the Firmware](#step-by-step-flash-the-firmware)
- [Verifying the Flash](#verifying-the-flash)
- [Dumping the Current Firmware](#dumping-the-current-firmware)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Supported Products

The CH32 flashing procedure in this guide applies to **all three Openterface
product lines** that use a CH32V208 / CH32F103 control chip. The hardware
steps (BOOT-button sequence, ISP mode) are identical; only the **software used
to perform the flash** and the physical location of the BOOT button differ.

| Product | Form Factor | Control Chip | Host software for flashing |
|---------|-------------|--------------|----------------------------|
| **Openterface KeyMod** | Compact wireless USB multi-tool (turns your phone into a keyboard/trackpad) | CH32V208 | **Openterface KeyCmd** (dedicated KeyMod companion app) |
| **Openterface Mini-KVM** | Classic HDMI + USB KVM dongle | CH32V208 *(newer hardware revisions)* | **This app** (Openterface MacOS) |
| **Openterface KVM-GO (USB 2.0)** | Keychain-sized KVM, USB 2.0 hub | CH32V208 | **This app** (Openterface MacOS) |
| **Openterface KVM-GO (USB 3.0)** | Keychain-sized KVM, USB 3.0 hub | CH32V208 | **This app** (Openterface MacOS) |

### Why different software?

Although the CH32 chip and the ISP flashing protocol are the same on every
device, the three products serve different use cases:

- **Mini-KVM / KVM-GO** — traditional KVM switches; managed from this
  Openterface MacOS app (video + keyboard/mouse).
- **KeyMod** — a wireless USB + Bluetooth HID multi-tool designed to pair with
  a phone; managed from the dedicated **Openterface KeyCmd** app.

> ⚠️ **If you own a KeyMod**, the BOOT-button / ISP-mode hardware steps in
> this guide still apply — but to actually flash the firmware, open the
> **Openterface KeyCmd** app rather than this Openterface MacOS app. The rest
> of the steps (scan → connect → flash) are the same.

### Not sure which product you have?

Open the relevant host app and go to its firmware-upgrade / WCH flash screen.
Click **Scan** while the device is in ISP mode — if the software detects a
`CH32V20x` chip, this guide applies to your hardware regardless of the
product name.

- Mini-KVM / KVM-GO users: use this app → **Settings → Firmware Upgrade → Keyboard & Mouse**.
- KeyMod users: use **Openterface KeyCmd**.

---

## When Do You Need This?

You should flash the CH32 chip when:

- The manufacturer releases a **new control firmware** version (keyboard/mouse
  fixes, latency improvements, new features).
- Your device behaves erratically and the support team asks you to re-flash.
- You are developing or testing a custom control firmware build.

You do **NOT** need this guide if you are updating the *video* (MS2109 /
MS2130S) chipset — that is done through the **Video Firmware** tab, which does
not require the BOOT button.

---

## Prerequisites

| Item | Requirement |
|------|-------------|
| Openterface Mini-KVM device | Hardware revision with CH32V208 control chip |
| Host computer | macOS (this app) |
| USB cable | Any data-capable USB-A / USB-C cable |
| Firmware file | `.bin` or `.hex` obtained from the official release or your build |
| Openterface app | Latest version, with **Settings → Firmware Upgrade** available |

> ⚠️ **Important:** Do **not** unplug the device from the target computer's
> HDMI / peripheral ports while flashing the control chip. Only the host-side
> USB connection needs to be re-plugged during the BOOT-button sequence.

---

## Hardware Overview

All three product lines expose a small **BOOT** push button on the PCB, near
the USB connector that plugs into your host computer. The physical layout
varies by product:

**Mini-KVM (classic dongle)**

The BOOT button is on the **circuit board (PCB surface)** — you may need to
peek at the board through the housing opening or remove the shell to press it.

```
          ┌─────────────────────────┐
          │    Openterface Mini-KVM │
          │                         │
          │      [BOOT]             │  ← on the PCB surface
          │                         │
          │      [USB-A / C]        │  ← connector
          └─────────────────────────┘
```

**KVM-GO (keychain form factor)**
```
      ┌──────────────────┐
      │   Openterface    │
      │     KVM-GO       │
      │ [BOOT] [USB-A]   │  ← bottom edge
      └──────────────────┘
```

**KeyMod (compact wireless multi-tool)**
```
      ┌────────────────────────┐
      │   Openterface KeyMod   │
      │                        │
      │  [BOOT]  [USB-C port]  │  ← side / bottom edge
      └────────────────────────┘
```

> 💡 If you cannot locate the BOOT button on your device, refer to the
> unboxing / hardware page for your specific product on
> [openterface.com](https://openterface.com/) or the product docs
> ([KeyMod](https://docs.openterface.com/products/keymod/),
> [KVM-GO](https://docs.openterface.com/products/kvmgo/),
> [Mini-KVM](https://docs.openterface.com/products/minikvm/)).

Pressing and holding BOOT while connecting USB tells the CH32 chip to boot
into its internal **ISP (In-System Programming) bootloader** instead of the
regular HID firmware. Only in ISP mode does the chip enumerate as a WCH ISP
device that the app can talk to.

---

## Step-by-Step: Enter ISP (Bootloader) Mode

The CH32 chip boots into its normal HID (keyboard/mouse) firmware by default.
You must manually put it into ISP mode before the app can scan or flash it.

| Step | Action |
|------|--------|
| **1** | **Unplug** the Openterface device from the host computer's USB port. |
| **2** | Locate the **BOOT** button on the device (next to the USB connector). |
| **3** | Press and **hold down** the BOOT button. |
| **4** | While still holding BOOT, **plug** the USB cable back into the host. |
| **5** | **Release** the BOOT button. |
| **6** | The CH32V208 now enumerates as a **WCH ISP device** (no HID/serial). |

> 💡 **Tip:** You can verify ISP mode in the macOS **System Information → USB**
> tree — the device should appear as a WCH ISP product (VID `1A86`, PID for
> ISP mode), not as a keyboard/mouse composite device.

---

## Step-by-Step: Flash the Firmware

Once the device is in ISP mode:

> **Note for KeyMod users:** The steps below describe the Openterface MacOS
> app. If you have a **KeyMod**, use the **Openterface KeyCmd** app instead —
> the hardware steps (entering ISP mode) are the same, but the flashing
> software UI is different.

| Step | Action |
|------|--------|
| **1** | Open the app: **Settings → Firmware Upgrade** window. |
| **2** | Select the **Keyboard & Mouse** (WCH) tab. |
| **3** | Click **Scan** — the device should appear with its chip type (e.g. `CH32V20x`) and UID. |
| **4** | Click **Connect**. The app reads the chip info: UID, bootloader version, and flash-protection status. |
| **5** | Click **Choose…** and select the firmware file (`.bin` or `.hex`). |
| **6** | Click **Flash Firmware**. The app will: unprotect code flash (if needed), erase, write, and verify byte-for-byte. |
| **7** | Wait for the progress bar to reach 100 %. The device resets automatically and re-enumerates as a HID keyboard/mouse. |
| **8** | The app displays the final status message (e.g. `Flash completed successfully`). |

> ⚠️ **Warning:** Flashing **erases and overwrites** the chip firmware. Do not
> unplug the USB cable during the flash process.

---

## Verifying the Flash

To confirm the firmware on the chip matches your file without writing:

1. Put the device in **ISP mode** (see [Enter ISP Mode](#step-by-step-enter-isp-bootloader-mode)).
2. Click **Scan → Connect**.
3. Pick the same firmware file.
4. Click **Verify**.

The app compares the selected file against the live chip contents and reports
whether they match byte-for-byte.

---

## Dumping the Current Firmware

To back up the firmware currently on the chip:

1. Put the device in **ISP mode**.
2. Click **Scan → Connect**.
3. Click **Dump**.
4. Choose a destination in the save panel. The live flash is written to disk.

---

## Troubleshooting

### "No devices found" when clicking Scan

| Cause | Fix |
|-------|-----|
| Device is not in ISP mode | Repeat the [BOOT-button sequence](#step-by-step-enter-isp-bootloader-mode). A normal plug-in leaves the chip in HID mode, which the ISP backend cannot see. |
| USB cable is charge-only | Use a **data-capable** cable. |
| Another app holds the USB device | Close any other Openterface or WCH-related apps, then scan again. |
| macOS permission prompt denied | Grant USB access in **System Settings → Privacy & Security**. |

### Device disconnects during flash

- **Do not panic.** Unplug, repeat the BOOT-button sequence, reconnect, then
  retry the flash. A partial flash leaves the bootloader intact, so the chip
  can still be recovered via ISP mode.

### "Code flash protected" message

- The app will automatically unprotect before writing. If unprotect fails,
  power-cycle the device, re-enter ISP mode, and try again.

### Chip type shows as `Unknown`

- The device is not a CH32V208 / CH32F103. Your hardware revision may use a
  different control chipset (e.g. CH9329 in older Mini-KVM revisions, which is
  not flashable).

### After flash, the keyboard/mouse does not work

- The device resets automatically at the end of a successful flash. If HID
  does not come back, unplug and re-plug the USB cable (no BOOT button needed
  this time — it should boot into the new firmware normally).

---

## FAQ

**Q: Do I need to hold BOOT every time I use the device?**
A: No. The BOOT button is only needed to enter ISP mode for flashing. After a
successful flash (or a normal power-on), the chip boots into its HID firmware
automatically.

**Q: Is the flashing procedure different for KeyMod vs. Mini-KVM vs. KVM-GO?**
A: No — the steps are **identical** across all three product lines. The CH32
chip, the ISP protocol, and the app interface are the same. The only difference
is where the BOOT button is located on the PCB (see
[Hardware Overview](#hardware-overview)).

**Q: My Mini-KVM is older — does it still have a CH32 chip?**
A: Early Mini-KVM units used the CH9329 control chip, which is **not**
flashable. Newer hardware revisions switched to CH32V208. If you click
**Scan** in the app and the chip type shows `CH32V20x`, this guide applies to
your unit. If it shows `Unknown` or `CH9329`, the CH32 flashing procedure
does not apply to your hardware.

**Q: Where do I get the firmware file?**
A: Firmware releases are published on the official Openterface channels
(GitHub Releases, Discord, Crowd Supply updates). Only use files intended for
your hardware revision.

**Q: Can I brick the device?**
A: The CH32's ISP bootloader lives in a protected region that flashing does
not overwrite. Even a failed flash can be recovered by re-entering ISP mode
with the BOOT button and retrying.

**Q: Does flashing erase my EDID / video settings?**
A: No. EDID and video-chipset settings are stored on the MS2109/MS2130S, not
on the CH32 control chip. Flashing the CH32 only touches the keyboard/mouse
firmware.

**Q: Which file format should I use — `.bin` or `.hex`?**
A: Both are accepted. `.hex` (Intel HEX) is human-readable; `.bin` is the raw
binary image. Use whichever is provided in the release.

---

## Related Documentation

- [Firmware Upgrade Overview](firmware-upgrade.md) — both video and control tabs
- [WCH ISP protocol internals](../openterface/Managers/WCH/) — source code
- [Openterface Quick Start](https://openterface.com/quick-start/)
