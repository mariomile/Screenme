import Foundation

extension Duration {
    /// "0:12", "1:05", "1:02:03". With `tenths`, "0:12.4" under an hour (seconds are cut, not rounded).
    static func format(_ seconds: TimeInterval, tenths: Bool = false) -> String {
        let value = max(seconds, 0)
        let total = tenths ? Int(value) : Int(value.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        guard tenths else { return String(format: "%d:%02d", minutes, secs) }
        return String(format: "%d:%02d.%d", minutes, secs, Int((value - Double(total)) * 10))
    }
}
