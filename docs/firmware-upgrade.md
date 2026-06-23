# Firmware Upgrade Guide

This document covers the firmware upgrade workflow in the Openterface MacOS app.
The firmware upgrade tool lives in a standalone window reachable from the Settings
menu. The window uses a segmented picker with two tabs:

1. **Video** — firmware for the video chipset (MS2109 / MS2109S / MS2130S)
2. **Keyboard & Mouse** — firmware for the WCH control chipset (CH32V208)

The window is opened via `openterfaceApp.showFirmwareUpdateWindow()` and uses a
`700 x 720` frame to accommodate both views.

## Supported Hardware

### Video Chipset (Tab 1)

| Chipset  | Upgrade path                              |
|----------|-------------------------------------------|
| MS2109   | EEPROM write over HID (`FirmwareManager`) |
| MS2109S  | EEPROM write over HID (`FirmwareManager`) |
| MS2130S  | External flash via `MS2130SFlashManager`  |

The app auto-detects the connected chipset through `AppStatus.videoChipsetType`
and picks the matching backend.

### Control Chipset (Tab 2)

| Chipset  | Supported | Notes                                        |
|----------|-----------|----------------------------------------------|
| CH32V208 | ✅        | WCH ISP / bootloader mode required           |
| CH9329   | ❌        | No flashable control firmware on this device |
| Unknown  | ❌        | Not detected                                 |

The availability check is performed at render time by reading
`AppStatus.controlChipsetType`. When the connected control chip is **not**
`.ch32v208`, the *Keyboard & Mouse* tab shows an availability notice instead of
the `WCHFlashSettingsView`:

> The connected control chip is not a WCH CH32 device, so upgrading the keyboard
> and mouse firmware is not available in this device.

This check lives in `FirmwareUpdateView.wchFirmwareContent`.

## Video Firmware Tab

### Checking Versions

When the window opens, `FirmwareUpdateView` performs two reads:

- **Current version** — via `FirmwareManager.getCurrentFirmwareVersion()` which
  either reads EEPROM over HID (MS2109/MS2109S) or asks
  `MS2130SFlashManager.shared.getVersion()` for MS2130S.
- **Latest version** — fetched asynchronously from
  `https://assets.openterface.com/openterface/firmware/minikvm_latest_firmware2.txt`
  using `FirmwareManager.fetchLatestFirmwareVersion()`.

The UI compares the two and displays one of three outcomes:

- Versions match → green "firmware is already up to date" banner
- Current is newer → orange "your firmware is newer than the latest available version" banner
- Current is older → blue "Update Now" button is enabled

### OTA Update

1. User clicks **Update Now** → confirmation alert.
2. `performFirmwareUpdate()` runs:
   - `stopAllOperations()` tears down video/audio/HID sessions.
   - `firmwareManager.loadFirmwareToEeprom()` writes the new firmware via HID
     commands in 64-byte chunks starting at address `0x0000`.
3. Progress is streamed through `@Published updateProgress` / `updateStatus`.
4. On completion the app asks the user to unplug and replug all cables and then
   terminates itself via `NSApplication.shared.terminate(nil)`.

### Backup

The small arrow button next to *Current firmware version* saves the current
firmware to disk via `FirmwareManager.backupFirmware(to:)`. Naming convention:

```
Openterface_Firmware_Backup_v<version>_<yyyyMMdd_HHmmss>.bin
```

The save panel defaults to the Desktop.

### Flash Local Firmware

The *Flash Local Firmware* button lets the user pick a `.bin` file from disk.
It goes through `FirmwareUpdateView.performFirmwareFlash(from:)` which:

1. Sets `AppStatus.isFirmwareFlashing = true` to block video/HID startup.
2. Stops all operations.
3. Validates the file size (between 100 B and 10 MB).
4. Dispatches to the correct backend:
   - `firmwareManager.flashExternalFirmware(data)` for MS2130S
   - `firmwareManager.writeFirmwareToEeprom(data)` for MS2109/MS2109S
5. On completion, the same termination flow as OTA update is triggered.

## Keyboard & Mouse (WCH) Firmware Tab

This tab is driven by `WCHFlashSettingsView` and backed by `WCHISPManager`. It
uses the WCH USB ISP protocol (via `WCHLibusbTransport` + `WCHFlashing`) rather
than the in-band HID protocol used by the video firmware path.

### Supported File Formats

- **Binary** `.bin` — raw image loaded verbatim
- **Intel HEX** `.hex` — parsed by `WCHHexFileParser`; auto-detected if the
  first byte is `:` or the extension is `.hex`

### Workflow

1. **Scan** — `WCHISPManager.scanDevices()` enumerates WCH ISP devices. The
   device must already be in ISP / bootloader mode.
2. **Connect** — `WCHISPManager.connect()` identifies the chip (CH32F103 /
   CH32V20x), reads its UID and bootloader version, and reports flash
   protection status.
3. **Choose file** — `WCHISPManager.selectFirmwareFile()` opens an NSOpenPanel.
4. **Operate** (pick one):
   - **Flash Firmware** — unprotects the code flash if needed, erases it, writes
     the new image, verifies it byte-for-byte, and resets the device.
   - **Verify** — compares the selected file against the live chip contents.
   - **Dump** — reads the live flash contents and saves them via NSSavePanel.
5. Progress is reported through `@Published operationProgress` with a status
   message in the `Status` group.

### Flash Protection

If the chip reports `supportsCodeFlashProtect` and the protection bit is set,
the flasher calls `f.unprotect(skipReset: true)` before erasing. This step is
automatic and logged in the status view.

## Pre-Update Checklist

For both tabs, the on-screen instructions recommend:

- Using a good quality USB cable between host and device
- Disconnecting the HDMI cable
- Not interrupting power during the write
- Restarting the application after completion
- For a clean state, unplugging and replugging all cables after the write

## Code Map

| Concern                          | File(s)                                             |
|----------------------------------|-----------------------------------------------------|
| Tab container UI                 | `openterface/Views/FirmwareUpdateView.swift`        |
| Video tab inner UI               | Same file, `videoFirmwareContent`                   |
| WCH tab inner UI                 | `openterface/Views/Settings/WCHFlashSettingsView.swift` |
| Video firmware backend           | `openterface/Managers/FirmwareManager.swift`        |
| MS2130S external flash backend   | `openterface/Managers/MS2130SFlashManager.swift`    |
| WCH ISP backend                  | `openterface/Managers/WCH/WCHISPManager.swift`      |
| WCH low-level protocol           | `openterface/Managers/WCH/WCHFlashing.swift`        |
| WCH transport (libusb)           | `openterface/Managers/WCH/WCHLibusbTransport.swift` |
| Chipset / device state           | `openterface/Settings/AppStatus.swift`              |
| Window entry point               | `openterfaceApp.showFirmwareUpdateWindow()`         |
