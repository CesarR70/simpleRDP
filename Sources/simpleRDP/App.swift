import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var sessions: SessionStore?
    private var terminationTimer: Timer?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessions else { return .terminateNow }
        sessions.disconnectAll()
        if sessions.allSessions.allSatisfy({ $0.isQuiescent() }) { return .terminateNow }
        // Keep the main run loop alive for queued clipboard completions. Never
        // delete a directory while a download worker can still write into it.
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard sessions.allSessions.allSatisfy({ $0.isQuiescent() }) else { return }
                timer.invalidate()
                self?.terminationTimer = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct simpleRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var sessions = SessionStore()

    var body: some Scene {
        Window("simpleRDP", id: "main") {
            ContentView(appDelegate: appDelegate, sessions: sessions)
                .environmentObject(favorites).frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 960, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Connection Tab", action: sessions.addTab).keyboardShortcut("t")
            }
        }
    }
}

struct ContentView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject var favorites: FavoritesStore
    @ObservedObject var sessions: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(sessions.tabs) { vm in
                            SessionTab(vm: vm, selected: sessions.selectedID == vm.id,
                                       select: { sessions.select(vm.id) }, close: { sessions.close(vm.id) })
                        }
                    }
                }
                Button(action: sessions.addTab) { Image(systemName: "plus") }
                    .help("New connection tab (⌘T)").accessibilityLabel("New connection tab")
            }.padding(8)
            Divider()
            if let vm = sessions.selected { SessionContent(vm: vm).id(vm.id) }
        }
        .background(WindowCloseObserver { sessions.disconnectAll() })
        .onAppear { appDelegate.sessions = sessions; sessions.start(); if let id = sessions.selectedID { sessions.select(id) } }
        .alert("Favorites could not be saved or loaded", isPresented: Binding(get: { favorites.lastError != nil }, set: { if !$0 { favorites.lastError = nil } })) {
            Button("OK") { favorites.lastError = nil }
        } message: { Text(favorites.lastError ?? "") }
    }
}

private struct SessionContent: View {
    @ObservedObject var vm: SessionViewModel
    @State private var clipboardError: String?
    private let status = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if case .connected = vm.state { SessionView(vm: vm) }
            else { ConnectView(vm: vm) }
        }
        .alert("Connection error", isPresented: Binding(get: { vm.lastError != nil }, set: { if !$0 { vm.lastError = nil } })) {
            Button("OK") { vm.lastError = nil }
        } message: { Text(vm.lastError ?? "") }
        .onReceive(status) { _ in
            let clipboard = vm.session.clipboard
            if clipboardError == nil, let message = clipboard.currentDownloadStatus().error {
                clipboardError = message
                clipboard.updateDownloadStatus { if $0.error == message { $0.error = nil } }
            }
        }
        .alert("Clipboard transfer", isPresented: Binding(get: { clipboardError != nil }, set: { if !$0 { clipboardError = nil } })) {
            Button("OK") { clipboardError = nil }
        } message: { Text(clipboardError ?? "") }
    }
}

private struct SessionTab: View {
    @ObservedObject var vm: SessionViewModel
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var confirmClose = false
    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                Label(vm.targetName.isEmpty ? "New Connection" : vm.targetName,
                      systemImage: vm.state.isActive ? "desktopcomputer" : "network")
                    .lineLimit(1).frame(maxWidth: 180)
            }.buttonStyle(.plain)
            Button {
                if vm.state.isActive || vm.session.clipboard.currentDownloadStatus().isActive { confirmClose = true }
                else { close() }
            } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).accessibilityLabel("Close connection tab")
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .cornerRadius(6)
        .help(vm.state.displayLabel)
        .alert("Close this connection?", isPresented: $confirmClose) {
            Button("Close Tab", role: .destructive, action: close)
            Button("Cancel", role: .cancel) {}
        } message: { Text("This disconnects only this session and cancels its unfinished download.") }
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