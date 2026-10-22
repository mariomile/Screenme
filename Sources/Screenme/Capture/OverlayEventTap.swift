import AppKit

/// The event plumbing every full-screen overlay (the picker, the ruler) needs, started together and stopped together:
/// the app's own events, the pointer moves other apps get, and display changes.
@MainActor
final class OverlayEventTap {
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    /// - `handle` gets the app's own events of `events` and returns true when it consumed one.
    /// - `pointerMoved` runs for the moves other apps get: mouse-moved events are not delivered reliably to the
    ///   panels of an inactive app.
    /// - `screensChanged` runs when the displays change.
    init(_ events: NSEvent.EventTypeMask, handle: @escaping @MainActor (NSEvent) -> Bool,
         pointerMoved: @escaping @MainActor () -> Void, screensChanged: @escaping @MainActor () -> Void) {
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated { handle(box.event) }
            return consumed ? nil : event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { pointerMoved() }
        }
        monitors = [local, global].compactMap { $0 }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { screensChanged() }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}
