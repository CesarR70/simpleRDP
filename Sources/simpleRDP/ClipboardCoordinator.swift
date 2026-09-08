import AppKit

/// One Mac pasteboard reader for the entire window. All access is main-thread only.
/// Snapshots are offered once, never broadcast or replayed merely on tab selection.
final class ClipboardCoordinator {
    let pasteboard: NSPasteboard
    private let maySendLocal: () -> Bool
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pendingLocal: LocalClipboardSnapshot?
    private(set) weak var selectedChannel: ClipboardChannel?
    private(set) var selectionID = UUID()

    init(pasteboard: NSPasteboard = .general, maySendLocal: @escaping () -> Bool = { NSApp?.isActive == true }) {
        self.pasteboard = pasteboard
        self.maySendLocal = maySendLocal
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit { timer?.invalidate() }

    func select(_ channel: ClipboardChannel?) {
        precondition(Thread.isMainThread)
        guard selectedChannel !== channel else { return }
        selectedChannel?.setActiveSelection(nil)
        selectedChannel = channel
        selectionID = UUID()
        channel?.setActiveSelection(selectionID)
        channel?.coordinator = self
        poll()
    }

    func poll() {
        precondition(Thread.isMainThread)
        if pasteboard.changeCount != lastChangeCount {
            lastChangeCount = pasteboard.changeCount
            pendingLocal = LocalClipboardSnapshot(pasteboard: pasteboard)
        }
        guard maySendLocal(), let channel = selectedChannel,
              let snapshot = pendingLocal, channel.canAnnounceLocalClipboard else { return }
        if channel.announceLocalFormats(snapshot) { pendingLocal = nil }
    }

    @discardableResult
    func publishRemoteText(_ text: String, from channel: ClipboardChannel,
                           selection: UUID?, pasteboardChange: Int) -> Bool {
        precondition(Thread.isMainThread)
        guard selectedChannel === channel, selection == selectionID,
              pasteboard.changeCount == pasteboardChange else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        // Remote text is never echoed to this or another session.
        pendingLocal = nil
        return true
    }
}

struct LocalClipboardSnapshot {
    let files: [ServedFile]
    let text: String?

    init(pasteboard: NSPasteboard) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        files = urls.prefix(10_000).compactMap { ServedFile(url: $0) }
        // Files take precedence over their alternate path-list text representation.
        let string = files.isEmpty ? pasteboard.string(forType: .string) : nil
        text = string.flatMap { $0.utf16.count <= 8 * 1024 * 1024 - 1 ? $0 : nil }
    }
}