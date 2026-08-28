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

The *Keyboard & Mouse* tab always renders `WCHFlashSettingsView`. The WCH ISP
flow itself identifies the connected chip on **Connect** via `WCHChipDB`; if the
chip isn't recognized, `WCHFlashing.init` throws `identificationFailed` and the
status view reports the error. The legacy availability check based on
`AppStatus.controlChipsetType` has been removed — users can attempt a scan +
connect regardless of what the app currently thinks the control chip is.

A `wchNotAvailableView` fallback still exists in `FirmwareUpdateView` but is
currently not referenced (commented out).

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

> ⚠️ **IMPORTANT: Entering Bootloader Mode**
>
> Before flashing the WCH chip, you must put it into ISP bootloader mode:
>
> 1. **Disconnect** the Target USB port from your host computer
> 2. **Press and hold** the on-board BOOT button on the Openterface device
> 3. **While holding the BOOT button**, connect the Target USB port to your host computer
> 4. **Release** the BOOT button after the USB connection is established
>
> The Target USB port is the port that normally connects to the computer/server you're
> controlling (not the host computer running this app). The device must be powered through
> this port for the WCH chip to be detected in bootloader mode.
>
> If you don't follow this sequence, the chip will boot normally and cannot be detected
> for flashing.

This tab is driven by `WCHFlashSettingsView` and backed by `WCHISPManager`. It
uses the WCH USB ISP protocol (via `WCHLibusbTransport` + `WCHFlashing`) rather
than the in-band HID protocol used by the video firmware path.

The tab is always rendered — `FirmwareUpdateView.wchFirmwareContent` returns
`WCHFlashSettingsView` unconditionally. Device presence is shown via the
connection status indicator, not by swapping the view.

### Supported File Formats

- **Binary** `.bin` — raw image loaded verbatim
- **Intel HEX** `.hex` — parsed by `WCHHexFileParser`; auto-detected if the
  first byte is `:` or the extension is `.hex`

### Multi-Device Support

`WCHISPManager.scanDevices()` may find more than one WCH ISP device on the bus.
When `scannedDevices.count > 1`, a `Picker` appears in the Device group box so
the user can choose which one to connect to. The picker is disabled while an
operation is in progress or while already connected.

### Workflow

1. **Enter bootloader mode** — See the warning box above. Disconnect the Target
   USB port, hold the BOOT button, reconnect the Target USB port to your host
   computer, then release the BOOT button.
2. **Scan** — `WCHISPManager.scanDevices()` enumerates WCH ISP devices via
   `WCHLibusbTransport.scanDevices()`. The device must be in ISP / bootloader
   mode (see above).
3. **Connect** — `WCHISPManager.connect(deviceIndex:)` identifies the chip
   (CH32F103 / CH32V20x etc. via `WCHChipDB`), reads its UID and bootloader
   version, and reports flash protection status. The chip info string is shown
   below the connection status.
4. **Choose file** — `WCHISPManager.selectFirmwareFile()` opens an NSOpenPanel
   for `.bin` or `.hex` files.
5. **Operate** (pick one):
   - **Flash Firmware** — full flow: unprotects the code flash if needed,
     erases it, writes the new image, **verifies via the device-side `.verify`
     ISP command** (the bootloader compares internally against code flash),
     re-enables flash protection if supported, and resets the device. After
     reset, `flashing` is released and `isConnected` is set to false (the chip
     is now running the new firmware, no longer in bootloader mode).
   - **Verify** — compares the selected file against the live chip contents
     using the device-side `.verify` command. This sends XOR-encrypted chunks
     to the bootloader, which compares them against what's actually in code
     flash and returns OK/fail. This is the *only* way to verify code flash on
     WCH chips — `dataRead` (0xab) targets data flash/EEPROM, a different
     memory region, and there is no `codeRead` command (security feature).
6. Progress is reported through `@Published operationProgress` with a status
   message in the `Status` group.

### Error Copy to Clipboard

When an operation fails (`isError == true`), a `doc.on.doc` icon button appears
next to the status message in the `Status` group. Clicking it copies the full
`statusMessage` (including error details) to the system clipboard via
`NSPasteboard.general`. The status `Text` also has `.textSelection(.enabled)`
so users can manually select and copy if preferred.

### Flash Protection

If the chip reports `supportsCodeFlashProtect` and the protection bit is set,
the flasher calls `f.unprotect(skipReset: true)` before erasing. After the
write + verify, `f.protect()` re-enables protection. Both steps are automatic
and logged in the status view.

### Verification Details

The verify path uses the WCH ISP `.verify` command (0xa6), which works as
follows:

1. ISP key exchange (same as flash) — establishes the XOR key derived from the
   chip UID.
2. Firmware binary is chunked into 56-byte pieces. Each chunk is XOR-encrypted
   with the derived key and sent to the bootloader with the target address.
3. The bootloader decrypts, reads code flash at that address, and compares
   internally. Returns OK or fail.
4. A final empty chunk signals end-of-verify (matches the flash terminator).

If the bootloader reports fail at any chunk, `verifyCode` throws
`WCHFlashingError.verifyFailed`. The status view surfaces this with the
copy-to-clipboard button for easy bug reports.

Note: because verification is device-side, the app cannot report *which* bytes
differ — only that verification failed. For read-back of data flash / EEPROM,
`readEEPROM` uses `.dataRead` (0xab), which *does* return data; code flash
remains unreadable from the host.

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
| WCH ISP backend (high-level)     | `openterface/Managers/WCH/WCHISPManager.swift`      |
| WCH flash / verify logic         | `openterface/Managers/WCH/WCHFlashing.swift`        |
| WCH ISP protocol (commands, responses, constants) | `openterface/Managers/WCH/WCHProtocol.swift` |
| WCH transport protocol           | `openterface/Managers/WCH/WCHTransport.swift`       |
| WCH transport (libusb)           | `openterface/Managers/WCH/WCHLibusbTransport.swift` |
| WCH transport (IOKit)            | `openterface/Managers/WCH/WCHUSBTransport.swift`    |
| WCH chip database                | `openterface/Managers/WCH/WCHChipDB.swift`          |
| WCH Intel HEX parser             | `openterface/Managers/WCH/WCHFlashing.swift` (`WCHHexFileParser`) |
| Chipset / device state           | `openterface/Settings/AppStatus.swift`              |
| Window entry point               | `openterfaceApp.showFirmwareUpdateWindow()`         |
