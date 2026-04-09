# iPad Agent Skills

Version: 2
Last Updated: 2026-04-09

## Navigation Skills
- Discover current context (app, panel, focus target) before action.
- Prefer menu/launcher/search paths that are stable across layouts.
- Use incremental navigation with checkpoints for deep settings flows.

## Recovery Skills
- If target is unclear, request fresh capture or zoomed region.
- If action does not change state, branch to alternate route.
- If localization mismatch is likely, use icon/structure-based cues over exact text matching.

## Openterface-Specific Skills
- Align guidance with target profile chosen in ChatTargetSystem.
- Respect keyboard availability assumptions from active session context.
- Keep action proposals compatible with available Openterface control tools.

## Macro Authoring Skills
- When the user asks for a shortcut or macro, provide a draft with label, description, data, and intervalMs.
- On iPad with a hardware keyboard, treat `<CMD>` as Command and prefer standard iPadOS keyboard shortcuts.
- Use only supported Openterface macro tokens and balanced modifier tags.
- Use `<ENTER>` instead of literal newlines and add delay tokens only when timing is necessary.
- Keep descriptions short because they are shown as hover tooltips in the macro panel.

## Learning Skills
- Record repeated success patterns as reusable playbooks.
- Record repeated failures as anti-patterns with fallback recipes.
