# About Openterface Serial driver on MacOS

## Background

Openterface MiniKVM uses CH340B and CH9329 chips to simulate keyboard and mouse control through serial communication. On the host side (macOS), the system comes with a built-in CDC (Communications Device Class) serial driver since macOS 10.9, which normally allows seamless connection to these chips. However, in some cases, installing other software or drivers may disable or interfere with the CDC driver. When this happens, OpenterfaceMacOS may fail to connect to the serial device, resulting in the inability to control the keyboard and mouse through the MiniKVM.

## Driver Issue Behavior

For the USB serial function of the CH340 chip to work correctly, either the built-in CDC driver or a third-party WCH driver must be installed and enabled. If at least one of these drivers is working properly, the Openterface MiniKVM should be able to communicate with the host and control the keyboard and mouse.  
If neither driver is installed or functioning, the serial connection will fail, and the keyboard and mouse control through MiniKVM will not work.

## Identify the issue

If you experience issues with the serial connection, please follow these steps:

1. **Check System Information**: 
   - Go to `Apple Menu` > `About This Mac` > `System Report`.
   - Under `Hardware`, select `USB` and check if the Openterface device appears in the list.
   The USB tree usually looks like this:
   USB 3.1 Bus
     - USB3 Gen2 Hub
        - USB2 Hub
            - USB2.0 HUB
                - USB Serial    <---- this indicated USB serial driver works as expected
                - Openterface

2. **Verify CDC Driver Installation**:  
- Open the Terminal and run:
  ```
  kextstat | grep com.apple.driver.usb.cdc
  ```
- If you see output similar to `com.apple.driver.usb.cdc`, it means the CDC driver is installed and loaded. If there is no output, the driver may be missing or disabled.

3. **Verify WCH Driver Installation**:  
- Open the Terminal and run:
```
systemextensionsctl list
```
- You should see a list of system extensions. For example:
```
  % systemextensionsctl list
...
  --- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' to modify these system extension(s))
enabled	active	teamID	bundleID (version)	name	[state]
  *	*	5JZGQTGU4W	cn.wch.CH34xVCPDriver (1.0/1)	cn.wch.CH34xVCPDriver	[activated enabled]
```
- If you have installed a WCH driver, it should appear under the `com.apple.system_extension.driver_extension` section.

## Troubleshooting the driver issue

If the Openterface MiniKVM is not working as expected, follow these troubleshooting steps:

### 1. Check the CDC Driver

- Ensure the built-in CDC driver is loaded:
  - Open Terminal and run:
    ```
    kextstat | grep com.apple.driver.usb.cdc
    ```
  - If you see output containing `com.apple.driver.usb.cdc`, the CDC driver is active.
  - If there is no output, the CDC driver may be missing or disabled. Try restarting your Mac, or check if any third-party drivers are conflicting or have disabled the CDC driver.

### 2. Install the WCH CH34x Driver

- If the CDC driver is not available or not working, you can install the official WCH CH34x driver:
  1. Visit the [WCH CH34xDriver GitHub Releases page](https://github.com/WCHSoftGroup/ch34xser_macos).
  2. Download the latest release for macOS.
  3. Follow the installation instructions provided in their repository or the included README.
  4. **Important:** After installing the WCH driver, you must enable the driver extension in **System Settings > General > Login Items & Extensions > Driver Extensions**. Make sure the CH34x driver is enabled here, otherwise the serial device will not function.
  5. After installation, reboot your Mac if required.
  6. Verify the driver is loaded by running:
     ```
     systemextensionsctl list
     ```
     and check for an entry like `cn.wch.CH34xVCPDriver` under the driver extensions section.

If neither driver is working after these steps, try disconnecting and reconnecting the device, using a different USB port, or uninstalling any conflicting serial drivers. For persistent issues, consult the Openterface or WCH support resources.


