import SwiftUI

struct SessionView: View {
    @ObservedObject var vm: SessionViewModel
    @State private var image: CGImage?
    @State private var lastRevision: UInt64 = 0
    @State private var download = ClipboardDownloadStatus()
    @State private var hasFiles = false
    @State private var showFiles = false
    @State private var error: String?
    @State private var dimensions: RDPResolution?
    private let frames = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    private let status = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RemoteDesktopView(image: image, input: vm.session.input)
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
                }
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle(vm.targetName)
        .toolbar {
            ToolbarItemGroup {
                if hasFiles {
                    Button { showFiles.toggle() } label: { Label("Files Ready", systemImage: "arrow.down.doc") }
                        .popover(isPresented: $showFiles) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Clipboard Files Ready").font(.headline)
                                Text("Use ⌥⌘V in a Finder folder to move the files, or choose a destination below.").fixedSize(horizontal: false, vertical: true)
                                Text("Moves within the same volume avoid a second copy. Other volumes require copying the data.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Save to…", action: saveFiles)
                            }.padding().frame(width: 290)
                        }
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
            clipboard.pruneStagedURLs()
            hasFiles = clipboard.hasStagedFiles
            download = clipboard.currentDownloadStatus()
            dimensions = vm.session.currentResolution
            if let message = download.error {
                error = message
                clipboard.updateDownloadStatus { $0.error = nil }
            }
        }
        .alert("Clipboard transfer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func saveFiles() {
        showFiles = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { vm.session.clipboard.moveStaged(to: url) }
        }
    }
}