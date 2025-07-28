# Settings Export Format

Openterface macOS app settings are exported in JSON format with the following structure:

## Example Export File

```json
{
  "version": "1.0",
  "exportDate": "2024-07-29T10:30:00Z",
  "appVersion": "Openterface v1.15 (57)",
  "settings": {
    "mouseControl": 1,
    "isAudioEnabled": false,
    "pasteBehavior": "askEveryTime",
    "useCustomAspectRatio": false,
    "customAspectRatio": "16:9",
    "isAbsoluteModeMouseHide": false,
    "doNotShowHidResolutionAlert": false,
    "edgeThreshold": 5,
    "isSerialOutput": false,
    "mainWindowName": "main_openterface",
    "viewWidth": 0,
    "viewHeight": 0,
    "isFullScreen": false
  }
}
```

## Field Descriptions

### Metadata
- `version`: Format version (always "1.0" for current format)
- `exportDate`: ISO8601 timestamp when settings were exported
- `appVersion`: Version of the app that exported the settings

### Settings
- `mouseControl`: 0 = relative mode, 1 = absolute mode
- `isAudioEnabled`: Boolean for audio streaming
- `pasteBehavior`: "askEveryTime", "alwaysPasteToTarget", or "alwaysPassToTarget"
- `useCustomAspectRatio`: Whether custom aspect ratio is enabled
- `customAspectRatio`: One of: "4:3", "16:9", "16:10", "5:3", "5:4", "21:9", "9:16", "9:19.5", "9:20", "9:21", "9:5"
- `isAbsoluteModeMouseHide`: Auto-hide cursor in absolute mode
- `doNotShowHidResolutionAlert`: Suppress HID resolution change alerts
- `edgeThreshold`: Edge detection threshold (CGFloat)
- `isSerialOutput`: Enable serial output logging
- `mainWindowName`: Main window identifier
- `viewWidth`/`viewHeight`: View dimensions (Float)
- `isFullScreen`: Full screen mode state

## Usage

1. **Export**: Use "Export Settings" button in Advanced & Debug settings
2. **Import**: Use "Import Settings" button to restore from a JSON file
3. **File naming**: Exports are automatically named with timestamp: `Openterface_Settings_YYYY-MM-DD_HH-MM-SS.json`

## Notes

- Import will validate the format version before applying settings
- Invalid or incompatible files will show an error message
- Import overwrites all current settings with values from the file
- Use "Reset All Settings" to restore defaults if needed
