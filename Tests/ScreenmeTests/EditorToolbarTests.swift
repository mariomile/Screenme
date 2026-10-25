import AppKit
import SwiftUI
import XCTest
@testable import Screenme

/// The editor window is never so narrow that AppKit hides the right end of the toolbar, where Copy and Done are.
final class EditorToolbarTests: PrefsSandboxTestCase, NSToolbarDelegate {
    private var items: [NSToolbarItem] = []

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [items[0].itemIdentifier, .flexibleSpace, items[1].itemIdentifier, .flexibleSpace, items[2].itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        items.map(\.itemIdentifier) + [.flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items.first { $0.itemIdentifier == identifier }
    }

    @MainActor
    func testMinimumWidthShowsEveryToolbarItem() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 40, height: 30, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let c = EditorController(item: CaptureItem(url: URL(fileURLWithPath: "/tmp/editor-test.png"), kind: .image),
                                 source: ImageSource(image: image, unit: 1))
        items = [
            AnnotationEditor.toolbarItem(.init("leading"), ToolbarLeading(c: c)),
            AnnotationEditor.toolbarItem(.init("tools"), ToolPalette(c: c)),
            AnnotationEditor.toolbarItem(.init("trailing"), ToolbarTrailing(c: c)),
        ]
        let width = AnnotationEditor.minimumWidth(for: items)

        // Invisible: the test needs AppKit's toolbar layout, not a window on the user's screen.
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "editor-toolbar-test")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = NSWindow.ToolbarStyle.unified
        window.titleVisibility = .hidden
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.setContentSize(CGSize(width: width, height: 600))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
        XCTAssertEqual(visible.intersection(["leading", "tools", "trailing"]), ["leading", "tools", "trailing"],
                       "At \(width) points the toolbar shows only \(visible.sorted())")
    }
}
