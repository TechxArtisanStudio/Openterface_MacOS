# Macro System

Last Updated: 2026-04-09

## Overview

Openterface macros are saved keyboard actions that can be triggered from the toolbar macro panel.

Each macro contains:
- `label`: short visible name.
- `description`: tooltip text shown when the pointer hovers over the macro.
- `isVerified`: whether the macro has been manually verified by the user.
- `targetSystem`: the OS the shortcut is intended for.
- `data`: the key sequence string.
- `intervalMs`: delay between tokens.

## Verification Status

Macros can be marked as verified or unverified in the editor.

In the macro list:
- Each macro can show a small verified-status indicator.
- The list header includes a toggle that switches between verified macros and unverified macros.

## AI Tooling

Verified macros are also exposed to the AI agent as a tool path.

AI can use the `run_verified_macro` tool to execute a verified macro directly when that macro can jump the target system to a new state faster than screen-by-screen navigation.

Tool behavior:
- Only verified macros are eligible.
- AI receives the current verified macro inventory with macro ids, labels, targets, and descriptions.
- AI should prefer `macro_id` when invoking a verified macro.
- If no verified macro fits, AI should continue with normal screen-driven actions.

## Key Sequence Format

The `data` field is plain text plus supported tokens.

Supported modifier tags:
- `<CTRL>` and `</CTRL>`
- `<SHIFT>` and `</SHIFT>`
- `<ALT>` and `</ALT>`
- `<CMD>` and `</CMD>`

Supported special keys:
- `<ESC>`
- `<BACK>`
- `<ENTER>`
- `<TAB>`
- `<SPACE>`
- `<LEFT>`
- `<RIGHT>`
- `<UP>`
- `<DOWN>`
- `<HOME>`
- `<END>`
- `<DEL>`
- `<PGUP>`
- `<PGDN>`
- `<F1>` through `<F12>`

Supported delay tokens:
- `<DELAY05s>`
- `<DELAY1S>`
- `<DELAY2S>`
- `<DELAY5S>`
- `<DELAY10S>`

Plain characters are typed as-is.

Examples:
- Wait half a second, then press Enter: `<DELAY05s><ENTER>`
- Copy on macOS: `<CMD>c</CMD>`
- Copy on Windows: `<CTRL>c</CTRL>`
- Open Run dialog on Windows: `<CMD>r</CMD>`
- Open Spotlight on macOS: `<CMD><SPACE></CMD>`
- Wait, then press Enter: `<DELAY2S><ENTER>`

## Target OS Meaning

The `<CMD>` token maps by target OS:
- macOS: Command
- Windows: Windows key
- Linux: Super key
- iPhone and iPad: Command on hardware keyboard
- Android: Meta key

## AI Authoring Contract

When AI helps a user create a macro, it should:
- Ask for the target OS if it is unclear.
- Prefer the shortest stable shortcut that matches the user goal.
- Return a practical `label`, a tooltip-friendly `description`, a valid `data` string, and an `intervalMs` value.
- Use `<ENTER>` instead of literal newlines.
- After a typing step finishes and the macro continues with another action, add a short delay such as `<DELAY05s>` so animations and visual effects can settle.
- Use delay tokens only when timing is genuinely needed.
- Never invent unsupported tokens.
- Avoid macro reference tokens during first-pass generation unless the user explicitly asks to compose existing macros.

## Magic Button

The macro editor includes a `Magic` button.

The Magic workflow is:
- User describes the desired outcome in plain language.
- AI generates the name, description, key sequence, and interval.
- User can review and adjust the generated macro before saving.

Recommended prompt shape for AI:
- State the app or system area involved.
- State the desired result.
- State any timing requirement.
- State whether text should be typed after the shortcut.

Example prompt:
- `On Windows, open Run, type cmd, wait for the window, then press Enter.`