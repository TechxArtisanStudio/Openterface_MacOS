# Android Agent Session Policy

Version: 1

## Purpose
Track short-lived context for a single run/conversation.

## Session State
- User goal and acceptance criteria.
- Current screen confidence and visibility limits.
- Last action, expected observation, and actual observation.
- Current risk tier and autonomy mode.

## Loop Contract
1. Sense current state.
2. Plan one minimal next action.
3. Act once.
4. Verify outcome.
5. Update session state and continue or recover.

## Reset Conditions
- User changes goal.
- Context drift (different app/window than expected).
- Repeated verification failures.

## Session End
Summarize outcome, unresolved blockers, and candidate learnings for memory promotion.
