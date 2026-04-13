# Agent Registry

Version: 1

## Canonical Contract
Each OS agent must provide the following files:
- soul.md
- tool.md
- skills.md
- memory.md
- session.md

## Registered Agents
- id: macos
  label: macOS
  folder: docs/ai/agents/macos
- id: windows
  label: Windows
  folder: docs/ai/agents/windows
- id: linux
  label: Linux
  folder: docs/ai/agents/linux
- id: iphone
  label: iPhone
  folder: docs/ai/agents/iphone
- id: ipad
  label: iPad
  folder: docs/ai/agents/ipad
- id: android
  label: Android
  folder: docs/ai/agents/android

## Safety Baseline
All agents must:
- Avoid inventing unseen UI state.
- Prefer reversible, non-destructive actions first.
- Confirm before destructive operations unless policy explicitly allows autonomous execution.
- Report uncertainty and request re-sense when visibility is insufficient.
