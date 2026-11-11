# MCP Server

The Openterface macOS app includes a built-in MCP (Model Context Protocol) server that exposes KVM controls as tools for AI clients like Claude Desktop, Cursor, and other MCP-compatible applications.

## Overview

The MCP server runs inside the Openterface app and provides remote control of a target computer through the KVM hardware. It uses the **Streamable HTTP** transport protocol over TCP.

**Features:**
- Screen capture and OCR
- Mouse control (move, click, drag, scroll)
- Keyboard input (type text, press keys)
- USB switch control
- Device status monitoring
- EDID display name management
- Video firmware upgrade (OTA and local file)

## Configuration

The MCP server is configured in **Settings > MCP Server**:

| Setting | Description | Default |
|---------|-------------|---------|
| Enable MCP Server | Toggle server on/off | Off |
| Port | TCP port for HTTP server | 8767 |
| Bind to localhost only | Accept only local connections | On |
| Authentication Token | Bearer token for API access | Auto-generated UUID |

### Authentication

All requests require a Bearer token in the `Authorization` header. The token is stored securely in the macOS Keychain and can be regenerated from the settings panel.

## Client Configuration

Add the following to your MCP client configuration:

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "openterface": {
      "type": "http",
      "url": "http://localhost:8767/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

### Cursor

Edit `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "openterface": {
      "type": "http",
      "url": "http://localhost:8767/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

Replace `YOUR_TOKEN_HERE` with the token shown in the Openterface MCP settings.

## Protocol

The server implements MCP protocol version `2025-03-26` with JSON-RPC 2.0 messaging.

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/mcp` | Send JSON-RPC requests |
| GET | `/mcp` | Server-Sent Events stream (optional) |
| DELETE | `/mcp` | Terminate session |

### Session Management

1. **Initialize**: Send `initialize` request to create a session. The server returns a `Mcp-Session-Id` header.
2. **Use Session**: Include the session ID in subsequent requests via the `Mcp-Session-Id` header.
3. **Timeout**: Sessions expire after 5 minutes of inactivity.

### Example: Initialize Session

```bash
curl -X POST http://localhost:8767/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": {"name": "my-client", "version": "1.0"}
    },
    "id": 1
  }'
```

Response headers include `Mcp-Session-Id: <session-uuid>`.

## Available Tools

### Screen Tools

#### `capture_screen`

Capture a screenshot of the target computer's display.

**Parameters:** None

**Returns:** Base64-encoded PNG image

**Example:**
```json
{
  "name": "capture_screen",
  "arguments": {}
}
```

#### `ocr_screen`

Capture the screen and extract text using OCR.

**Parameters:** None

**Returns:** Recognized text from the screen

**Example:**
```json
{
  "name": "ocr_screen",
  "arguments": {}
}
```

### Mouse Tools

All coordinates are **normalized 0.0–1.0** with origin at top-left corner.

#### `move_mouse`

Move the mouse cursor to a position.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| x | number | Yes | X coordinate (0.0 = left, 1.0 = right) |
| y | number | Yes | Y coordinate (0.0 = top, 1.0 = bottom) |

**Example:**
```json
{
  "name": "move_mouse",
  "arguments": {"x": 0.5, "y": 0.5}
}
```

#### `left_click`

Left-click at a position. If coordinates omitted, clicks at current position.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| x | number | No | X coordinate |
| y | number | No | Y coordinate |

**Example:**
```json
{
  "name": "left_click",
  "arguments": {"x": 0.5, "y": 0.5}
}
```

#### `right_click`

Right-click at a position.

**Parameters:** Same as `left_click`

#### `double_click`

Double-click at a position.

**Parameters:** Same as `left_click`

#### `drag`

Drag from one position to another (left button held).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| start_x | number | Yes | Start X coordinate |
| start_y | number | Yes | Start Y coordinate |
| end_x | number | Yes | End X coordinate |
| end_y | number | Yes | End Y coordinate |

**Example:**
```json
{
  "name": "drag",
  "arguments": {"start_x": 0.3, "start_y": 0.5, "end_x": 0.7, "end_y": 0.5}
}
```

#### `scroll`

Scroll the mouse wheel.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| amount | integer | Yes | Scroll amount (positive = up, negative = down) |
| x | number | No | X position to scroll at |
| y | number | No | Y position to scroll at |

**Example:**
```json
{
  "name": "scroll",
  "arguments": {"amount": -3}
}
```

### Keyboard Tools

#### `type_text`

Type text as if typed on a physical keyboard. Supports printable ASCII characters.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| text | string | Yes | The text to type |

**Example:**
```json
{
  "name": "type_text",
  "arguments": {"text": "Hello, World!"}
}
```

#### `press_key`

Press a key or key combination.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| keys | string | Yes | Key tokens in angle brackets |

**Key Token Format:**
- Single keys: `<Enter>`, `<Tab>`, `<Escape>`
- Combinations: `<Ctrl+C>`, `<Alt+F4>`, `<Cmd+Space>`
- Multiple modifiers: `<Ctrl+Shift+T>`
- Multiple keys (space-separated): `<Ctrl+A> <Delete>`

**Common Key Names:**
- Letters: `A`–`Z`
- Numbers: `0`–`9`
- Function keys: `F1`–`F12`
- Special: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`, `Delete`
- Arrows: `Up`, `Down`, `Left`, `Right`
- Modifiers: `Ctrl`, `Alt`, `Cmd` (or `Super`), `Shift`

**Example:**
```json
{
  "name": "press_key",
  "arguments": {"keys": "<Ctrl+Alt+Delete>"}
}
```

### Device Tools

#### `get_device_status`

Get the current status of the KVM device.

**Parameters:** None

**Returns:**
```json
{
  "hdmi_connected": true,
  "target_connected": true,
  "keyboard_connected": true,
  "mouse_connected": true,
  "input_resolution": {"width": 1920, "height": 1080},
  "capture_resolution": {"width": 1920, "height": 1080},
  "fps": 60,
  "hdmi_signal": true,
  "firmware_version": "26012113",
  "serial_port_name": "cu.usbmodem211201",
  "serial_port_baudrate": 9600,
  "num_lock": false,
  "caps_lock": false,
  "scroll_lock": false,
  "hardware_switch_on": false,
  "software_switch_on": false,
  "active_protocol": "kvm"
}
```

**Field Descriptions:**
| Field | Description |
|-------|-------------|
| `hdmi_connected` | HDMI cable is connected to the KVM |
| `target_connected` | Target computer is detected and connected |
| `keyboard_connected` | Keyboard HID device is connected to target |
| `mouse_connected` | Mouse HID device is connected to target |
| `input_resolution` | Resolution of the video signal from the target |
| `capture_resolution` | Resolution the KVM is capturing at |
| `fps` | Current frame rate |
| `hdmi_signal` | Valid HDMI signal detected |
| `firmware_version` | Video chip firmware version |
| `serial_port_name` | Serial port device name |
| `serial_port_baudrate` | Serial port baud rate |
| `num_lock` | Num Lock LED state |
| `caps_lock` | Caps Lock LED state |
| `scroll_lock` | Scroll Lock LED state |
| `hardware_switch` | Physical USB switch position |
| `software_switch` | Software USB switch state |
| `active_protocol` | Current connection protocol (kvm/remote) |

#### `switch_usb`

Switch USB peripherals between host (this Mac) and target (remote computer).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| target | string | Yes | `"host"` or `"target"` |

**Example:**
```json
{
  "name": "switch_usb",
  "arguments": {"target": "target"}
}
```

### EDID Tools

#### `edid_info`

Read the EDID display name stored in the video chip EEPROM. This is the monitor name that the target computer sees.

**Parameters:** None

**Returns:**
```json
{
  "chipset": "ms2109s",
  "display_name": "Openterface",
  "manufacturer_id": "AOC",
  "product_code": "0x0A01",
  "serial_number": "0x00000001",
  "serial_string": "",
  "edid_offset": "0x0326",
  "firmware_size": 1453,
  "edid_checksum_valid": true,
  "input_resolution": {"width": 1920, "height": 1080},
  "firmware_version": "26012113"
}
```

**Note:** Not available on MS2130S devices (uses external SPI flash).

#### `edid_set_name`

Set the EDID display name (monitor name) that the target computer sees.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| name | string | Yes | Display name (max 12 ASCII characters) |

**Example:**
```json
{
  "name": "edid_set_name",
  "arguments": {"name": "My Monitor"}
}
```

**Constraints:**
- Maximum 12 characters
- ASCII printable characters only
- Not available on MS2130S devices

### Firmware Tools

#### `firmware_upgrade`

Download and flash the latest video chipset firmware from the Openterface server. The device will be unavailable during the update (typically 10-60 seconds).

**Parameters:** None

**Returns:** Success/failure status with version information

**Example:**
```json
{
  "name": "firmware_upgrade",
  "arguments": {}
}
```

**Response:**
```
Firmware upgrade completed successfully.
Chipset: MS2109S
Previous version: 25022713
New version: 25030610
Please restart the app to reconnect the device.
```

#### `firmware_flash_local`

Flash a local firmware binary file to the video chipset. Use this to install a specific firmware version.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| file_path | string | Yes | Absolute path to the firmware .bin file |

**Example:**
```json
{
  "name": "firmware_flash_local",
  "arguments": {"file_path": "/Users/kevin/Downloads/Openterface_Firmware_250306.bin"}
}
```

**Supported chipsets:** MS2109, MS2109S, MS2130S

#### `firmware_verify`

Verify the integrity of the currently installed video firmware by reading it back from EEPROM and checking the checksums. Use this after a firmware update or if the device is not working correctly.

**Parameters:** None

**Returns:** Verification report with checksum validation results

**Example:**
```json
{
  "name": "firmware_verify",
  "arguments": {}
}
```

**Response:**
```
Firmware Verification Report
============================
Chipset: MS2109S
Firmware version: 25030610
Firmware size: 1453 bytes
Data read: 1453 bytes

Checksum Result:
✅ Firmware checksums are valid
Header: 0x1234 ✓
Code: 0x5678 ✓
```

**Supported chipsets:** MS2109, MS2109S

## Usage Patterns

### Typical AI Workflow

1. **Capture screen** to see what's on the target display
2. **OCR screen** to read text content
3. **Move mouse** to desired position
4. **Click** to interact
5. **Type text** or **press keys** to input data
6. **Capture screen** again to verify result

### Example: Open Application

```
User: Open Calculator on the target computer

AI:
1. capture_screen → See desktop
2. press_key "<Cmd+Space>" → Open Spotlight
3. type_text "Calculator" → Type app name
4. press_key "<Enter>" → Launch app
5. capture_screen → Verify Calculator opened
```

### Example: Read and Copy Text

```
User: Copy the error message on screen

AI:
1. ocr_screen → Extract all visible text
2. Parse response to find error message
3. Return the error text to user
```

## Rate Limiting

The server enforces a rate limit of 10 tool calls per second per client. Exceeding this limit returns an error.

## Troubleshooting

### Connection Refused

- Ensure the MCP server is enabled in Openterface settings
- Check that the port matches (default: 8767)
- If "Bind to localhost only" is disabled, ensure firewall allows connections

### Unauthorized

- Verify the Bearer token matches the one in Openterface settings
- Token is case-sensitive

### Session Expired

- Sessions expire after 5 minutes of inactivity
- Send a new `initialize` request to create a fresh session

### Tool Returns Error

- Check that the KVM device is connected and powered
- Verify HDMI signal is present
- For mouse/keyboard tools, ensure USB is switched to target

## Architecture

```
┌─────────────────┐     HTTP/JSON-RPC     ┌─────────────────┐
│   MCP Client    │ ◄───────────────────► │   MCP Server    │
│ (Claude/Cursor) │                       │  (in Openterface)│
└─────────────────┘                       └────────┬────────┘
                                                   │
                                          ┌────────┴────────┐
                                          │  Tool Registry  │
                                          └────────┬────────┘
                                                   │
                    ┌──────────────────────────────┼──────────────────────────────┐
                    │                              │                              │
              ┌─────┴─────┐                 ┌──────┴──────┐                ┌──────┴──────┐
              │  Screen   │                 │    Input    │                │   Device    │
              │  Capture  │                 │   Router    │                │   Status    │
              │   / OCR   │                 │             │                │             │
              └─────┬─────┘                 └──────┬──────┘                └──────┬──────┘
                    │                              │                              │
              ┌─────┴─────┐                 ┌──────┴──────┐                ┌──────┴──────┐
              │  Camera   │                 │   Serial    │                │     HID     │
              │  Manager  │                 │   Port      │                │   Manager   │
              └───────────┘                 └─────────────┘                └─────────────┘
```

## Security Considerations

- The auth token provides access to control the target computer
- Use "Bind to localhost only" unless remote access is specifically needed
- Regenerate the token if compromised
- The token is stored in macOS Keychain (encrypted at rest)

## Source Files

| File | Description |
|------|-------------|
| `MCP/MCPServer.swift` | Server orchestrator and session management |
| `MCP/MCPHTTPServer.swift` | HTTP transport layer |
| `MCP/MCPHTTPConnection.swift` | Connection handler |
| `MCP/MCPMessage.swift` | JSON-RPC message types |
| `MCP/MCPSession.swift` | Session state management |
| `MCP/MCPToolRegistry.swift` | Tool registration and dispatch |
| `MCP/MCPKeychainStore.swift` | Auth token storage |
| `MCP/Tools/*.swift` | Individual tool implementations |
| `MCP/Views/MCPSettingsView.swift` | Settings UI |
