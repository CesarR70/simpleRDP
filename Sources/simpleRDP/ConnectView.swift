import SwiftUI

@MainActor
final class SessionViewModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var state: ConnectionState = .idle
    @Published var lastError: String?
    @Published var host = ""
    @Published var username = ""
    @Published var password = ""
    @Published var endpointKind: EndpointKind = .auto
    @Published var trustAllCertificates = false
    @Published var sharePath = ""
    @Published var resolution = RDPResolution.defaultResolution
    @Published var targetName = ""
    let session = RDPSession()
    private var observation: Task<Void, Never>?

    init() {
        let stream = session.stateStream
        observation = Task { [weak self] in
            for await state in stream {
                guard !Task.isCancelled else { break }
                self?.state = state
                if case .failed(let reason) = state { self?.lastError = reason }
            }
        }
    }
    deinit { observation?.cancel(); session.disconnect() }

    func connect() {
        lastError = nil
        do {
            let address = try ConnectionAddress(host)
            targetName = address.display
            try session.connect(to: address.display, username: username.isEmpty ? nil : username,
                                password: password, endpointKind: endpointKind,
                                trustAllCertificates: trustAllCertificates,
                                sharePath: sharePath.isEmpty ? nil : sharePath, resolution: resolution)
            password = ""
            state = .connecting(host: address.display)
        } catch { lastError = error.localizedDescription }
    }
    func disconnect() { session.disconnect() }

    func load(_ favorite: ServerFavorite) {
        host = favorite.displayHostPort
        username = favorite.username ?? ""
        password = ""
        endpointKind = favorite.endpointKind
        trustAllCertificates = favorite.trustAllCertificates
        sharePath = favorite.sharePath ?? ""
        resolution = favorite.resolution
    }

    func favoriteDraft() throws -> ServerFavorite {
        let address = try ConnectionAddress(host)
        return ServerFavorite(name: "", host: address.host, port: address.port,
                              username: username.isEmpty ? nil : username, endpointKind: endpointKind,
                              trustAllCertificates: trustAllCertificates,
                              sharePath: sharePath.isEmpty ? nil : sharePath, resolution: resolution)
    }
}

struct ConnectView: View {
    @EnvironmentObject var favorites: FavoritesStore
    @ObservedObject var vm: SessionViewModel
    @State private var selection: UUID?
    @State private var draft: ServerFavorite?
    @State private var isNewFavorite = false
    @State private var showOptions = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Favorites") {
                    ForEach(favorites.favorites) { favorite in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(favorite.name.isEmpty ? favorite.host : favorite.name)
                                Text(favorite.displayHostPort).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "desktopcomputer") }
                        .tag(favorite.id)
                        .contextMenu {
                            Button("Edit…") { isNewFavorite = false; draft = favorite }
                            Button("Delete", role: .destructive) { favorites.delete(favorite) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if favorites.favorites.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star").font(.title2)
                        Text("No favorites yet")
                        Text("Save a connection for next time.").font(.caption)
                    }.foregroundStyle(.secondary).padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .disabled(vm.state.isActive)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect to a Desktop").font(.title2.weight(.semibold))
                Form {
                    TextField("Server", text: $vm.host, prompt: Text("hostname or host:port"))
                        .disableAutocorrection(true)
                    TextField("Username", text: $vm.username, prompt: Text("Optional"))
                        .disableAutocorrection(true)
                    SecureField("Password", text: $vm.password)
                    DisclosureGroup("Connection Options", isExpanded: $showOptions) {
                        ConnectionOptions(endpoint: $vm.endpointKind, resolution: $vm.resolution,
                                          sharePath: $vm.sharePath, disableVerification: $vm.trustAllCertificates)
                    }
                }
                .formStyle(.grouped)
                .disabled(vm.state.isActive)
                HStack {
                    Button { saveFavorite() } label: { Label("Save Favorite…", systemImage: "star") }
                        .disabled(vm.host.trimmingCharacters(in: .whitespaces).isEmpty || vm.state.isActive)
                    Spacer()
                    if vm.state.isActive {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: vm.disconnect).keyboardShortcut(.cancelAction)
                    } else {
                        Button("Connect", action: vm.connect)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(vm.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text(vm.state.displayLabel).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(24)
            .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("simpleRDP")
        }
        .onChange(of: selection) { id in
            if let favorite = favorites.favorites.first(where: { $0.id == id }) { vm.load(favorite) }
        }
        .sheet(item: $draft) { favorite in
            FavoriteEditor(initial: favorite) { updated in
                if isNewFavorite { favorites.add(updated) } else { favorites.update(updated) }
                draft = nil
            }
        }
    }

    private func saveFavorite() {
        do { draft = try vm.favoriteDraft(); isNewFavorite = true }
        catch { vm.lastError = error.localizedDescription }
    }
}

struct ConnectionOptions: View {
    @Binding var endpoint: EndpointKind
    @Binding var resolution: RDPResolution
    @Binding var sharePath: String
    @Binding var disableVerification: Bool

    var body: some View {
        Picker("Endpoint", selection: $endpoint) {
            ForEach(EndpointKind.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Resolution", selection: $resolution) {
            ForEach(RDPResolution.presets) { Text($0.displayName).tag($0) }
        }
        HStack {
            TextField("Share folder", text: $sharePath, prompt: Text("Optional"))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Share"
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { result in
                        if result == .OK, let url = panel.url { sharePath = url.path }
                    }
                }
            }
        }
        Toggle("Disable certificate verification — Lab Use Only", isOn: $disableVerification)
            .help("Disables all server certificate checks, including identity and changed certificates. Use only on a trusted lab network.")
        if disableVerification {
            Label("Server identity will not be verified.", systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

private struct FavoriteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerFavorite
    @State private var address: String
    @State private var error: String?
    let onSave: (ServerFavorite) -> Void

    init(initial: ServerFavorite, onSave: @escaping (ServerFavorite) -> Void) {
        _draft = State(initialValue: initial)
        _address = State(initialValue: initial.displayHostPort)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Favorite").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Optional label"))
                TextField("Server", text: $address, prompt: Text("hostname or host:port"))
                TextField("Username", text: Binding(get: { draft.username ?? "" }, set: { draft.username = $0.isEmpty ? nil : $0 }))
                ConnectionOptions(endpoint: $draft.endpointKind, resolution: $draft.resolution,
                                  sharePath: Binding(get: { draft.sharePath ?? "" }, set: { draft.sharePath = $0.isEmpty ? nil : $0 }),
                                  disableVerification: $draft.trustAllCertificates)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        let parsed = try ConnectionAddress(address)
                        draft.host = parsed.host
                        draft.port = parsed.port
                        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = parsed.host }
                        onSave(draft)
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560, height: 480)
    }
}