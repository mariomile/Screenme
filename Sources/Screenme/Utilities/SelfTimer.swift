import CoreGraphics

/// Countdown shown over the area before a timed capture. Returns false when cancelled. Stub.
@MainActor
enum SelfTimer {
    static func countdown(seconds: Int, around frame: CGRect) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return true
    }
}
