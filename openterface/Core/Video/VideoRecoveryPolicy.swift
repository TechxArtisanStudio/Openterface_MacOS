import Foundation

/// Pure decision helpers for recovering the video pipeline after hot-plug.
///
/// Kept free of AVFoundation/Metal/AppKit so the rules can be compiled and
/// verified outside the app host (the test runner cannot launch in every
/// environment).
enum VideoRecoveryPolicy {

    /// A cached frame older than this is stale (capture stopped: device
    /// unplugged, session stopped, or source frozen) and must not be
    /// re-rendered. Without it the view repaints the last frame forever.
    static let frameStaleTimeout: TimeInterval = 2.0

    /// Decide whether a cached frame should be dropped.
    /// `lastUpdate` is a monotonic timestamp (CACurrentMediaTime), 0 = none.
    static func isFrameStale(lastUpdate: TimeInterval,
                             now: TimeInterval,
                             isLive: Bool,
                             timeout: TimeInterval = frameStaleTimeout) -> Bool {
        guard isLive else { return false }
        guard lastUpdate > 0 else { return true }
        return now - lastUpdate > timeout
    }

    /// Decides whether a running capture session must be torn down.
    /// A session is healthy only while it has inputs and recent frames.
    static func sessionNeedsRestart(isRunning: Bool,
                                    hasInputs: Bool,
                                    secondsSinceLastFrame: TimeInterval,
                                    staleTimeout: TimeInterval = frameStaleTimeout) -> Bool {
        guard isRunning else { return false }
        if !hasInputs { return true }
        return secondsSinceLastFrame > staleTimeout
    }
}