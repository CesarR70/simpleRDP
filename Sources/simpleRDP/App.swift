import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: RDPSession?
    private var terminationTimer: Timer?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        session.disconnect()
        session.clipboard.cancelDownloads()
        if session.isQuiescent() {
            session.clipboard.clearStagedFiles()
            return .terminateNow
        }
        // Keep the main run loop alive for queued clipboard completions. Never
        // delete a directory while a download worker can still write into it.
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard session.isQuiescent() else { return }
            session.clipboard.clearStagedFiles()
            timer.invalidate()
            self?.terminationTimer = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct simpleRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favorites = FavoritesStore()

    init() { ClipboardChannel.cleanClipboardCache() }

    var body: some Scene {
        // Deliberately one window/session: the system pasteboard has one owner.
        Window("simpleRDP", id: "main") {
            ContentView(appDelegate: appDelegate).environmentObject(favorites).frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 960, height: 680)
    }
}

struct ContentView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject var favorites: FavoritesStore
    @StateObject private var vm = SessionViewModel()

    var body: some View {
        Group {
            if case .connected = vm.state {
                SessionView(vm: vm)
            } else { ConnectView(vm: vm) }
        }
        .background(WindowCloseObserver { vm.disconnect() })
        .onAppear { appDelegate.session = vm.session }
        .alert("Connection error", isPresented: Binding(get: { vm.lastError != nil }, set: { if !$0 { vm.lastError = nil } })) {
            Button("OK") { vm.lastError = nil }
        } message: { Text(vm.lastError ?? "") }
        .alert("Favorites could not be saved or loaded", isPresented: Binding(get: { favorites.lastError != nil }, set: { if !$0 { favorites.lastError = nil } })) {
            Button("OK") { favorites.lastError = nil }
        } message: { Text(favorites.lastError ?? "") }
    }
}

private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) { view.onClose = onClose }

    final class ObserverView: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in self?.onClose?() }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}