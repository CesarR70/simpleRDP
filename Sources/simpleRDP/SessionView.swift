//
// SessionView.swift — live view of the active RDP session.
//
// Polls the session's Framebuffer at ~30 Hz and paints the latest CGImage.
// The Framebuffer is fed by FreeRDP's EndPaint callback on the event-loop
// thread and is lock-protected, so polling here is safe and cheap (no copy
// happens unless the frame changed).
//
// View-only for now: mouse/keyboard capture is the next Milestone 2 chunk.
//

import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    let state: ConnectionState
    let framebuffer: Framebuffer
    let input: RemoteInput
    let clipboard: ClipboardChannel
    let onDisconnect: () -> Void
    let onResize: (UInt32, UInt32) -> Void
    /// Session-reported current resolution (set on connect and after each
    /// successful resize reconnect). Polled by `statusText` on every refresh-
    /// timer repaint, so the status bar tracks resizes immediately instead of
    /// waiting for the first EndPaint at the new size.
    let currentResolution: () -> RDPResolution?

    @State private var image: CGImage?
    @State private var lastRevision: UInt64 = 0
    @State private var downloadStatus = ClipboardDownloadStatus()
    @State private var hasStagedFiles = false
    @State private var showSavePanel = false

    private let refreshTimer = Timer.publish(every: 1.0 / 30.0,
                                             on: .main,
                                             in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The NSView draws the frame AND captures input, so pointer
                // coordinate mapping and pixel placement always agree.
                RemoteDesktopView(image: image, input: input)
                if image == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Waiting for the first frame…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 10, height: 10)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if downloadStatus.isActive {
                    // Activity light: a server→Mac clipboard file download is
                    // staging into the cache directory.
                    Circle().fill(.orange).frame(width: 10, height: 10)
                        .padding(.leading, 8)
                    Text(downloadText)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Abort an accidental large copy: stops the download and
                    // clears the cache dir.
                    Button(role: .cancel) {
                        clipboard.cancelDownloads()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel download and clear the clipboard cache")
                }

                Spacer()

                Menu {
                    // Standard desktop sizes. Choosing one re-negotiates the live
                    // session's resolution via onResize (see RDPSession).
                    ForEach(RDPResolution.presets) { res in
                        Button(res.displayName) {
                            onResize(res.width, res.height)
                        }
                    }
                } label: {
                    Label("Resolution", systemImage: "rectangle.arrow.triangle.2.circlepath")
                }
                .fixedSize()
                .help("Change the remote desktop resolution")

                if hasStagedFiles && !downloadStatus.isActive {
                    // Server→Mac files are staged in the cache. Save-to MOVES
                    // (renames) them to a chosen folder — no second SSD write.
                    Button {
                        showSavePanel = true
                    } label: {
                        Label("Save to…", systemImage: "arrow.down.doc")
                    }
                    .help("Move the copied file(s) out of the cache to a folder you choose (move, not copy). In Finder, ⌥⌘V (“Move Item Here”) also moves instead of copying.")

                    // Remind the user the Save-to button is optional:
                    // ⌥⌘V in a Finder folder moves the staged file(s)
                    // out of the cache just the same.
                    Text("Hint: press ⌥⌘V in a Finder folder to move it there")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("⌘-shortcuts stay on the Mac · Ctrl-click = right-click")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Disconnect", action: onDisconnect)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(refreshTimer) { _ in
            if let (revision, latest) = framebuffer.latestImage(after: lastRevision) {
                lastRevision = revision
                image = latest
            }
            let status = clipboard.currentDownloadStatus()
            if status != downloadStatus { downloadStatus = status }
            // Retire the Save-to button if the staged files already left the
            // cache (e.g. moved out via Finder's ⌥⌘V "Move Item Here").
            clipboard.pruneStagedURLs()
            let staged = clipboard.hasStagedFiles
            if staged != hasStagedFiles { hasStagedFiles = staged }
        }
        .fileImporter(isPresented: $showSavePanel,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let dir = urls.first {
                clipboard.moveStaged(to: dir)
            }
        }
    }

    private var downloadText: String {
        let current = min(downloadStatus.filesDone + 1, downloadStatus.filesTotal)
        var text = "Downloading clipboard (\(current)/\(downloadStatus.filesTotal))"
        if !downloadStatus.currentFile.isEmpty {
            text += " — \(downloadStatus.currentFile)"
        }
        if downloadStatus.bytesTotal > 0 {
            let done = ByteCountFormatter.string(fromByteCount: Int64(downloadStatus.bytesDone),
                                                 countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(downloadStatus.bytesTotal),
                                                  countStyle: .file)
            text += " · \(done)/\(total)"
        }
        text += " · saved to ~/Library/Caches/simpleRDP/RemoteClipboard/"
        return text
    }

    private var statusText: String {
        var text = state.displayLabel
        // Prefer the session-reported resolution (updates the instant a resize
        // reconnect succeeds). Fall back to the framebuffer's frame-derived
        // dims for sessions without a reported resolution.
        if let res = currentResolution() {
            text += " · \(res.width)×\(res.height)"
        } else if let dims = framebuffer.dimensions {
            text += " · \(dims.width)×\(dims.height)"
        }
        return text
    }
}
