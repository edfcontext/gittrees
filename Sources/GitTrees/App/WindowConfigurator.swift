import AppKit
import SwiftUI

/// Applies the window settings SwiftUI does not expose on macOS.
struct WindowConfigurator: NSViewRepresentable {
    let title: String
    var onBecomeKey: () -> Void = {}

    func makeNSView(context: Context) -> BecomeKeyView {
        let view = BecomeKeyView()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ view: BecomeKeyView, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.window?.title = title
        view.window?.minSize = NSSize(width: 860, height: 520)
    }
}

/// Observes its window becoming key so each repository window can register as the
/// target for Settings and menu commands.
final class BecomeKeyView: NSView {
    var onBecomeKey: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(becameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        if window.isKeyWindow {
            DispatchQueue.main.async { [onBecomeKey] in
                onBecomeKey()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func becameKey() {
        DispatchQueue.main.async { [onBecomeKey] in
            onBecomeKey()
        }
    }
}
