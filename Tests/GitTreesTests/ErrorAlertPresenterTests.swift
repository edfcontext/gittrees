import AppKit
import GitTreesCore
import Testing
@testable import GitTrees

@Suite("Scrollable error alerts", .serialized)
@MainActor
struct ErrorAlertPresenterTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The native sheet transition should finish within one second.")
    }

    @Test("long diagnostics fit the screen and keep actions outside the scrolling area", arguments: [
        NSSize(width: 1280, height: 720),
        NSSize(width: 1024, height: 600),
        NSSize(width: 640, height: 400)
    ])
    func boundedLayout(_ screenSize: NSSize) throws {
        _ = NSApplication.shared
        let diagnostics = (1...2_000).map { "line \($0): error details" }.joined(separator: "\n")
            + "\n" + String(repeating: "x", count: 50_000)
        let error = PresentableError(title: "Could Not Complete Operation", message: "A file needs review.", detail: diagnostics)
        let alert = ErrorAlertPresenter.makeAlert(for: error, visibleFrame: NSRect(origin: .zero, size: screenSize))
        alert.layout()
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        #expect(scroll.hasVerticalScroller)
        #expect(text.isSelectable && !text.isEditable)
        #expect(text.string.contains(diagnostics))
        #expect(text.string.contains("What happened"))
        #expect(text.string.contains("How to resolve"))
        #expect(text.string.contains("Technical details"))
        #expect(alert.window.frame.width <= screenSize.width)
        #expect(alert.window.frame.height <= screenSize.height)
        #expect(text.frame.height > scroll.contentSize.height)
        #expect(alert.buttons.map(\.title) == ["OK", "Copy Details"])
        for button in alert.buttons {
            #expect(!button.isDescendant(of: scroll))
            let frame = button.convert(button.bounds, to: alert.window.contentView)
            #expect(alert.window.contentView?.bounds.contains(frame) == true)
        }
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        // The tail remains reachable, including a very long line without spaces.
        text.scrollRangeToVisible(NSRange(location: text.string.utf16.count - 1, length: 1))
        #expect(scroll.contentView.bounds.origin.y > 0)
    }

    @Test("Copy Details retains the alert, and OK returns to the existing form")
    func copyAndDismissAboveForm() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let form = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        form.isReleasedWhenClosed = false
        window.orderFront(nil)
        window.beginSheet(form, completionHandler: { _ in })
        defer {
            if let sheet = form.attachedSheet { form.endSheet(sheet) }
            window.endSheet(form)
            form.close()
            window.close()
        }
        let error = PresentableError(title: "Operation Failed", message: "Review the affected file.", detail: "complete output")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let alert = ErrorAlertPresenter.makeAlert(
            for: error, visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 600), pasteboard: pasteboard
        )
        var completed = false
        alert.beginSheetModal(for: form) { _ in completed = true }
        try await waitFor { form.attachedSheet === alert.window }
        alert.buttons[1].performClick(nil)
        #expect(pasteboard.string(forType: .string) == error.reportText)
        #expect(!completed)
        #expect(form.attachedSheet === alert.window)
        #expect(window.attachedSheet === form)
        alert.buttons[0].performClick(nil)
        try await waitFor { completed }
        #expect(form.attachedSheet == nil)
        #expect(window.attachedSheet === form)
    }
}
