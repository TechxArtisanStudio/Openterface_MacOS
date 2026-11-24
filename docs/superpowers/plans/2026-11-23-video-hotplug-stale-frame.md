# Video hot-plug: stale last frame / black start / no recovery

Date: 2026-11-23
Status: implemented, awaiting hardware verification

## Symptoms (user report)

1. Launch with no KVM device → black screen instead of the placeholder image.
2. Plug device in → video works.
3. Unplug while streaming → the last frame stays frozen forever.
4. Re-plug → still frozen; never recovers.

## Root causes (from app log 2026-11-23 12:09 + code)

- **A. Metal view re-renders cached textures forever.**
  `VideoMetalView.draw()` re-samples `currentYTexture/currentUVTexture` at
  VSync. Nothing clears them when the capture stream dies, so the last frame
  is repainted until the process exits ("Render FPS: 75.0" keeps logging on
  the frozen frame).
- **B. Placeholder image is covered by the opaque MTKView.**
  `PlayerView.setupLayer()` adds `playerBackgroundImage` as a sublayer and
  `VideoMetalView` (opaque, black clear color) as a subview above it. With no
  textures on launch, Metal clears to black and hides the placeholder.
- **C. Zombie session is never stopped, so replug is skipped.**
  On unplug `videoWasDisconnected` only matched via
  `AppStatus.videoChipDevice + matchesLocalID`; in the log that guard failed
  (no "disconnected, stopping session" line), so `captureSession` stayed
  "running" with the dead input. On replug `prepareVideo()` hit
  `Video already running, skipping preparation` and returned.

## Fix design

- `VideoMetalView`
  - Track `lastFrameUpdateTime` / `isShowingLiveFrame` under
    `textureUpdateQueue`; expose `hasLiveFrame`, `secondsSinceLastFrame()`.
  - `clearFrame()` drops cached textures/refs/orphans and posts
    `.videoFrameAvailabilityChanged`.
  - `draw()` drops cached textures once no frame arrived for
    `frameStaleTimeout` (2 s).
  - Post live=true only on false→true transition.
- `PlayerView`
  - Hide the Metal view (show placeholder) until a live frame arrives;
    toggle on `.videoFrameAvailabilityChanged`.
  - `captureSessionDidStopRunning` → `clearFrame()`.
- `VideoManager`
  - `prepareVideo()`: when running, restart if inputs are gone or frames are
    stale (replaces unconditional skip). Predicate:
    `static func sessionNeedsRestart(isRunning:hasInputs:secondsSinceLastFrame:staleTimeout:)`.
  - `videoWasDisconnected`: match the current session input's `uniqueID`
    first, fall back to chip `locationID`; then stop + clear + remove inputs.
  - `stopVideoSession()`: always clears the Metal frame.
  - 2 s watchdog (`DispatchSourceTimer`, main queue): running + stale →
    clear; if a matching device is present restart, otherwise stop the empty
    zombie session. Guarded by start-time cooldown so a 1 s start delay is
    not mistaken for a zombie.

## Verification

- Unit tests (discriminating): `VideoHotplugRecoveryTests` covers both
  predicates (fresh vs stale, no-input zombie, not-running).
- `xcodebuild -scheme openterface build` in this clone.
- Manual: launch w/o device → placeholder; plug → live; unplug → placeholder;
  replug → live again.

### Results (2026-11-23)

- App build: BUILD SUCCEEDED. Test bundle: TEST BUILD SUCCEEDED.
- Hosted XCTest runner hangs before connecting in this environment (same for
  pre-existing `LogTests`), so the predicates were verified by compiling
  `VideoRecoveryPolicy.swift` with a standalone harness: 10/10 assertions
  passed, including the unplug case (running + stale → restart) and the
  just-under/just-over timeout boundary.