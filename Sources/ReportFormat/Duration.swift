import Foundation

extension Duration {
    /// "0:12", "1:05", "1:02:03". With `tenths`, to the nearest tenth: "0:12.4", "1:02:03.5".
    static func format(_ seconds: TimeInterval, tenths: Bool = false) -> String {
        let value = max(seconds, 0)
        let units = tenths ? Int((value * 10).rounded()) : Int(value.rounded()) * 10
        let total = units / 10, hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        let clock = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
        return tenths ? clock + ".\(units % 10)" : clock
    }
}
