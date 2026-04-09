# AI Agent Prompt System

This directory defines OS-specific autonomous agents for Openterface AI navigation.

## Design Goals
- One agent per target OS profile.
- Five-file contract per agent:
  - soul.md: mission and behavioral priorities
  - tool.md: executable tool/action contract
  - skills.md: domain knowledge map for navigation and recovery
  - memory.md: long-term memory policy
  - session.md: short-term run/session policy
- Keep docs as source of truth before runtime loading is enabled.

## Agent Registry
- macOS: docs/ai/agents/macos/
- Windows: docs/ai/agents/windows/
- Linux: docs/ai/agents/linux/
- iPhone: docs/ai/agents/iphone/
- iPad: docs/ai/agents/ipad/
- Android: docs/ai/agents/android/

## Runtime Mapping Rule (planned)
Map ChatTargetSystem to folder name:
- macOS -> macos
- windows -> windows
- linux -> linux
- iPhone -> iphone
- iPad -> ipad
- android -> android

## Versioning
Each file should include a Version and Last Updated section when edited.

## Macro Authoring
- Openterface AI should understand the macro contract in docs/macro-system.md.
- Runtime OS agent files should include macro-generation guidance so the active prompt profile can help users create shortcuts directly.
- Macro assistance should produce label, description, key sequence, target-aware shortcuts, and interval guidance.
