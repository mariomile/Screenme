import AppKit

/// A normal window of another app on screen, as the window server lists it.
struct OnScreenWindow: Equatable {
    var pid: pid_t
    /// The owning app's name as the window server knows it.
    var app: String?
    var title: String?
    /// Global points, top-left origin.
    var bounds: CGRect

    /// The normal windows (layer 0) of other apps on screen, front to back, from one copy of the window server's list.
    static func others() -> [OnScreenWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer] as? Int == 0, let pid = info[kCGWindowOwnerPID] as? pid_t, pid != own,
                  let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return OnScreenWindow(pid: pid, app: info[kCGWindowOwnerName] as? String, title: info[kCGWindowName] as? String, bounds: bounds)
        }
    }
}
