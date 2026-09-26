import AppKit
import SwiftUI

/// Applies the window settings SwiftUI does not expose on macOS.
///
/// The window *title* is deliberately not one of them: it is owned by
/// `.navigationTitle` in `MainView`, which shows the repository's name. Setting
/// `window.title` here too made the two race — whichever ran last won — so the
/// same window showed the bare name in one moment and a prefixed name the next.
struct WindowConfigurator: NSViewRepresentable {
    var onBecomeKey: () -> Void = {}
    var onAppActive: () -> Void = {}
    var onWillClose: () -> Void = {}

    func makeNSView(context: Context) -> BecomeKeyView {
        let view = BecomeKeyView()
        view.onBecomeKey = onBecomeKey
        view.onAppActive = onAppActive
        view.onWillClose = onWillClose
        return view
    }

    func updateNSView(_ view: BecomeKeyView, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.onAppActive = onAppActive
        view.onWillClose = onWillClose
        view.window?.minSize = NSSize(width: 860, height: 520)
        // Session restore is ours: reopen the repositories that were open, not
        // however many empty windows AppKit last snapshot.
        view.window?.isRestorable = false
    }
}

/// Observes its window becoming key so each repository window can register as the
/// target for Settings and menu commands.
final class BecomeKeyView: NSView {
    var onBecomeKey: () -> Void = {}
    var onAppActive: () -> Void = {}
    var onWillClose: () -> Void = {}
    private var didNotifyClose = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        didNotifyClose = false
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(becameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willClose),
            name: NSWindow.willCloseNotification,
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

    @objc private func appBecameActive() {
        // Do not require `isKeyWindow`. Activation is posted before the window is
        // key again (Dock click, click on an already-focused pane), so that guard
        // skipped the refresh until a later view update.
        DispatchQueue.main.async { [onAppActive] in
            onAppActive()
        }
    }

    @objc private func willClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onWillClose()
    }
}
