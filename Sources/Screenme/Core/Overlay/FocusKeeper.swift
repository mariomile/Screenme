import AppKit

/// Local event monitors run on the main thread but are not declared main-actor; this carries the event across.
struct EventBox: @unchecked Sendable {
    let event: NSEvent
}

/// Activation and pointer helpers for every overlay, alert and save panel.
/// Screenme is an accessory app: to receive keys it has to take focus, and to leave no trace
/// it has to hand focus back to whoever had it.
@MainActor
enum FocusKeeper {
    /// The frontmost app, unless that is Screenme itself.
    static func frontmostExternal() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }

    /// Brings Screenme forward so its panels, alerts and save panels receive keyboard events.
    /// Not the cooperative `activate()`: macOS can decline that when a global hot key woke Screenme.
    static func activateSelf() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Gives focus back to `app` and waits briefly until macOS has switched, so a capture taken
    /// right afterwards shows the window as active.
    static func restore(_ app: NSRunningApplication?) async {
        guard let app, !app.isTerminated else { return }
        func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        if isFront() { return }
        NSApp.yieldActivation(to: app)
        app.activate()
        for _ in 0..<25 {
            if isFront() { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
        // The window server repaints title bars just after the switch.
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Lets this process change the pointer while another app is nominally frontmost.
    /// Without it `NSCursor.hide()` is ignored whenever activation was declined.
    static func allowBackgroundCursor() {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let main = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let set = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(main, to: MainConnection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
