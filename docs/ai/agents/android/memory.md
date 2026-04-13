# Android Agent Memory Policy

Version: 1

## Purpose
Store durable knowledge that improves future task success on Android.

## Store
- Stable shortcut patterns and app-entry paths.
- Verified UI flow heuristics that work across sessions.
- Known failure signatures and proven recoveries.

## Do Not Store
- Secrets, credentials, tokens, or sensitive personal content.
- Volatile one-off observations that do not generalize.

## Promotion Rule
Promote a pattern to durable memory only after repeated successful outcomes.

## Expiration Rule
Retire or downgrade memory entries when they fail repeatedly after OS/app updates.
