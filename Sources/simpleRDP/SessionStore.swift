import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var tabs: [SessionViewModel] = []
    @Published private(set) var selectedID: UUID?
    let clipboard: ClipboardCoordinator
    // Retain closing sessions until workers finish, including during app termination.
    private var closing: [SessionViewModel] = []
    private var cleanupTimer: Timer?

    init(clipboard: ClipboardCoordinator = ClipboardCoordinator()) {
        self.clipboard = clipboard
        addTab()
    }

    var selected: SessionViewModel? { tabs.first { $0.id == selectedID } }
    var allSessions: [RDPSession] { (tabs + closing).map(\.session) }

    func start() { clipboard.start() }

    func addTab() {
        let vm = SessionViewModel()
        vm.session.clipboard.coordinator = clipboard
        tabs.append(vm)
        select(vm.id)
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selected?.session.input.releaseAllKeys()
        selectedID = id
        clipboard.select(tab.session.clipboard)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let vm = tabs.remove(at: index)
        vm.session.input.releaseAllKeys()
        vm.disconnect()
        vm.session.clipboard.cancelDownloads()
        closing.append(vm)
        if selectedID == id {
            if tabs.isEmpty { addTab() }
            else { select(tabs[min(index, tabs.count - 1)].id) }
        }
        reapClosedSessions()
        if !closing.isEmpty, cleanupTimer == nil {
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapClosedSessions() }
            }
        }
    }

    private func reapClosedSessions() {
        closing.removeAll { $0.session.isQuiescent() }
        if closing.isEmpty { cleanupTimer?.invalidate(); cleanupTimer = nil }
    }

    func disconnectAll() {
        clipboard.select(nil)
        for session in allSessions {
            session.input.releaseAllKeys()
            session.disconnect()
            session.clipboard.cancelDownloads()
        }
    }

    deinit { cleanupTimer?.invalidate() }
}