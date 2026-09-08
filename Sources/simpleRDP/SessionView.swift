import SwiftUI

struct SessionView: View {
    @ObservedObject var vm: SessionViewModel
    @State private var image: CGImage?
    @State private var lastRevision: UInt64 = 0
    @State private var download = ClipboardDownloadStatus()
    @State private var offer: RemoteFileOffer?
    @State private var dimensions: RDPResolution?
    private let frames = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    private let status = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RemoteDesktopView(image: image, input: vm.session.input,
                                  beforePaste: { vm.session.clipboard.coordinator?.poll() })
                if image == nil { ProgressView("Waiting for the desktop…").padding().background(.regularMaterial).cornerRadius(8) }
            }
            HStack(spacing: 8) {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                if let dimensions { Text(dimensions.displayName).foregroundStyle(.secondary) }
                Spacer()
                if download.isActive {
                    ProgressView(value: Double(download.bytesDone), total: Double(max(1, download.bytesTotal))).frame(width: 100)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(download.bytesDone), countStyle: .file))
                    Button { vm.session.clipboard.cancelDownloads() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Cancel clipboard download").accessibilityLabel("Cancel clipboard download")
                } else if let directory = download.savedDirectory {
                    Button("Show Download in Finder") { NSWorkspace.shared.open(directory) }
                }
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle(vm.targetName)
        .toolbar {
            ToolbarItemGroup {
                if let offer {
                    Button { downloadFiles(offer) } label: { Label("Download Remote Files…", systemImage: "arrow.down.doc") }
                        .disabled(download.isActive)
                        .help("Download \(offer.itemCount) item(s) from \(vm.targetName) — \(ByteCountFormatter.string(fromByteCount: Int64(offer.bytesTotal), countStyle: .file))")
                    Button { vm.session.clipboard.dismissFileOffer(offer.id); self.offer = nil } label: { Image(systemName: "xmark.circle") }
                        .help("Dismiss remote file offer").accessibilityLabel("Dismiss remote file offer")
                }
                Menu {
                    ForEach(RDPResolution.presets) { size in
                        Button(size.displayName) { vm.session.setResolution(width: size.width, height: size.height) }
                    }
                } label: { Label("Display", systemImage: "display") }
                .help("Change resolution by reconnecting to the desktop")
                Button("Disconnect", action: vm.disconnect)
            }
        }
        .onReceive(frames) { _ in
            if let frame = vm.session.framebuffer.latestImage(after: lastRevision) {
                lastRevision = frame.revision
                image = frame.image
            }
        }
        .onReceive(status) { _ in
            let clipboard = vm.session.clipboard
            offer = clipboard.currentFileOffer()
            download = clipboard.currentDownloadStatus()
            dimensions = vm.session.currentResolution
        }
    }

    private func downloadFiles(_ offer: RemoteFileOffer) {
        let clipboard = vm.session.clipboard
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"
        panel.message = "Choose where to save \(offer.itemCount) item(s) from \(vm.targetName). No files are downloaded until you confirm."
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { clipboard.downloadRemoteFiles(offer, to: url) }
        }
    }
}