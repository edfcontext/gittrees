import AppKit
import GitTreesCore
import SwiftUI

/// NSAlert keeps its buttons outside the scrolling diagnostic text. Presenting
/// through the window also allows errors above an existing SwiftUI form sheet.
struct ErrorAlertPresenter: NSViewRepresentable {
    @Binding var error: PresentableError?

    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }

    func makeNSView(context: Context) -> AlertAnchorView {
        let view = AlertAnchorView()
        view.onWindowChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.schedulePresentation(from: view)
        }
        return view
    }

    func updateNSView(_ view: AlertAnchorView, context: Context) {
        context.coordinator.error = $error
        context.coordinator.schedulePresentation(from: view)
    }

    @MainActor
    final class Coordinator {
        var error: Binding<PresentableError?>
        private var alert: NSAlert?
        private var presentedID: UUID?

        init(error: Binding<PresentableError?>) { self.error = error }

        func schedulePresentation(from view: NSView) {
            // Binding changes and sheet presentation must happen after SwiftUI's update.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.presentIfNeeded(from: view)
            }
        }

        private func presentIfNeeded(from view: NSView) {
            if let alert {
                if error.wrappedValue?.id != presentedID {
                    alert.window.sheetParent?.endSheet(alert.window)
                }
                return
            }
            guard let error = error.wrappedValue, var parent = view.window else { return }
            while let sheet = parent.attachedSheet { parent = sheet }
            let alert = ErrorAlertPresenter.makeAlert(
                for: error,
                visibleFrame: (parent.screen ?? NSScreen.main)?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            self.alert = alert
            presentedID = error.id
            alert.beginSheetModal(for: parent) { [weak self, weak view] _ in
                guard let self else { return }
                self.alert = nil
                self.presentedID = nil
                // A newer failure must not be cleared when an older alert closes.
                if self.error.wrappedValue?.id == error.id { self.error.wrappedValue = nil }
                if let view { self.schedulePresentation(from: view) }
            }
        }
    }

    static func makeAlert(
        for error: PresentableError, visibleFrame: NSRect, pasteboard: NSPasteboard = .general
    ) -> NSAlert {
        let alert = ErrorDetailsAlert(report: error.reportText, pasteboard: pasteboard)
        alert.alertStyle = .warning
        alert.messageText = error.title
        let button = alert.addButton(withTitle: "OK")
        button.keyEquivalent = "\r"
        let copyButton = alert.addButton(withTitle: "Copy Details")
        copyButton.target = alert
        copyButton.action = #selector(ErrorDetailsAlert.copyDetails(_:))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "Copy the explanation, recovery steps and complete technical details."

        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: 0,
            width: min(560, max(1, visibleFrame.width - 160)),
            height: min(380, max(1, visibleFrame.height - 260))
        ))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let content = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        func appendSection(_ heading: String, _ body: String, font: NSFont) {
            if content.length > 0 { content.append(NSAttributedString(string: "\n\n")) }
            content.append(NSAttributedString(string: "\(heading)\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
            content.append(NSAttributedString(string: body, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        appendSection("What happened", error.summary, font: .systemFont(ofSize: 13))
        appendSection("How to resolve", error.recoveryText, font: .systemFont(ofSize: 13))
        if error.hasTechnicalDetails {
            appendSection("Technical details", error.diagnosticText,
                          font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        }
        textView.textStorage?.setAttributedString(content)
        textView.setAccessibilityLabel("Error explanation, recovery steps and technical details")
        scrollView.documentView = textView
        scrollView.setAccessibilityLabel("Scrollable error details")
        alert.accessoryView = scrollView
        return alert
    }
}

/// Copy is an auxiliary action: it leaves the alert and any underlying form open.
@MainActor
private final class ErrorDetailsAlert: NSAlert {
    private let report: String
    private let pasteboard: NSPasteboard

    init(report: String, pasteboard: NSPasteboard) {
        self.report = report
        self.pasteboard = pasteboard
        super.init()
    }

    @objc func copyDetails(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
    }
}

final class AlertAnchorView: NSView {
    var onWindowChanged: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged()
    }
}
