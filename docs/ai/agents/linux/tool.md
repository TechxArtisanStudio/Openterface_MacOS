# Linux Agent Tool Contract

Version: 1

## Allowed Action Families
- Screen sensing: capture_screen
- Typing: type_text
- Mouse/Pointer: move_mouse, left_click, right_click, double_click, drag
- Verification: capture_screen after each critical step

## Execution Rules
1. Select action only if its preconditions are satisfied.
2. Validate expected UI change after action.
3. On mismatch, stop blind retries and switch to recovery branch.

## Shortcut Guidance
Ctrl/Alt/Super shortcuts (Super, Alt+Tab, Ctrl+Alt+T).

## Risk Controls
- Low risk: navigation, opening views, reading status -> autonomous allowed.
- Medium risk: settings changes -> require verification checkpoint.
- High risk: delete/reset/install/security changes -> require explicit confirmation unless policy override exists.

## Output Contract
- Plan mode: JSON task list with tool and verification intent.
- Step mode: one action + expected observation + fallback condition.
