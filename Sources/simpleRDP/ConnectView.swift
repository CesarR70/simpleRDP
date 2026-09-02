//
// ConnectView.swift — main SwiftUI screen with the connection form and a
// favorites list. Matches the layout sketched in RDP-Swift-Client-Plan.md §7.
//

import SwiftUI

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var state: ConnectionState = .idle
    @Published var lastError: String?

    let session: RDPSession

    init() {
        self.session = RDPSession()
        // Consume the actor's state stream and forward to UI.
        Task { [weak self] in
            guard let self else { return }
            for await s in self.session.stateStream {
                self.state = s
            }
        }
    }

    func connect(to hostPort: String,
                 username: String?,
                 password: String?,
                 endpointKind: EndpointKind,
                 trustAllCertificates: Bool,
                 sharePath: String? = nil,
                 resolution: RDPResolution? = nil) {
        lastError = nil
        Task {
            do {
                try await session.connect(to: hostPort,
                                          username: username,
                                          password: password,
                                          endpointKind: endpointKind,
                                          trustAllCertificates: trustAllCertificates,
                                          sharePath: sharePath,
                                          resolution: resolution)
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func disconnect() {
        Task { await session.disconnect() }
    }
}

struct ConnectView: View {
    @EnvironmentObject var favorites: FavoritesStore
    // Owned by ContentView so the window can switch to SessionView on connect.
    @ObservedObject var vm: SessionViewModel

    // Connection form fields.
    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var endpointKind: EndpointKind = .auto
    @State private var trustAllCertificates: Bool = false
    @State private var sharePath: String = ""
    @State private var resolution: RDPResolution = .defaultResolution
    @State private var showSaveFavorite: Bool = false
    @State private var editingFavorite: ServerFavorite?

    var body: some View {
        HSplitView {
            // Left: connection form
            VStack(alignment: .leading, spacing: 12) {
                Text("simpleRDP")
                    .font(.title)
                    .bold()
                    .fixedSize() // never clip the title

                GroupBox("Connection") {
                    // Explicit labels with a guaranteed label column: SwiftUI
                    // Form would otherwise clip leading placeholder text when
                    // the window or split divider shrinks this pane.
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                        GridRow {
                            Text("Server:")
                                .gridColumnAlignment(.trailing)
                            TextField("host or host:port", text: $host)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                        }
                        GridRow {
                            Text("Username:")
                            TextField("optional", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                        }
                        GridRow {
                            Text("Password:")
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Endpoint:")
                            Picker("", selection: $endpointKind) {
                                ForEach(EndpointKind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        GridRow {
                            Text("Resolution:")
                            Picker("", selection: $resolution) {
                                ForEach(RDPResolution.presets) { res in
                                    Text(res.displayName).tag(res)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        GridRow {
                            Text("Share folder:")
                            TextField("optional, e.g. ~/Documents", text: $sharePath)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                        }
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Toggle("Trust self-signed certificates (lab use only)",
                                   isOn: $trustAllCertificates)
                                .fixedSize()
                        }
                    }
                    .frame(minWidth: 430, alignment: .leading)
                    .padding(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                HStack {
                    Button(action: connectTapped) {
                        Label("Connect", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(vm.state.isActive || host.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Disconnect") { vm.disconnect() }
                        .disabled(!vm.state.isActive)

                    Spacer()

                    Button { showSaveFavorite = true } label: {
                        Label("Save as favorite", systemImage: "star")
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                statusBar
            }
            .padding(16)
            .frame(minWidth: 560, idealWidth: 580, maxWidth: .infinity,
                   maxHeight: .infinity, alignment: .topLeading)

            // Right: favorites list
            VStack(alignment: .leading, spacing: 8) {
                Text("Favorites").font(.headline)
                List {
                    ForEach(favorites.favorites) { fav in
                        FavoriteRow(fav: fav,
                                    connect: { loadFavorite(fav) },
                                    edit: { editingFavorite = fav },
                                    delete: { favorites.delete(fav) })
                    }
                }
                .listStyle(.inset)
            }
            .padding(16)
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .topLeading)
            .layoutPriority(-1)
        }
        .sheet(isPresented: $showSaveFavorite) {
            FavoriteEditor(initial: ServerFavorite(name: "",
                                                   host: host,
                                                   port: 3389,
                                                   username: username.isEmpty ? nil : username,
                                                   endpointKind: endpointKind)) { result in
                if let result { favorites.add(result) }
                showSaveFavorite = false
            }
        }
        .sheet(item: $editingFavorite) { fav in
            FavoriteEditor(initial: fav) { result in
                if let result { favorites.update(result) }
                editingFavorite = nil
            }
        }
        .alert("Connection error",
               isPresented: Binding(
                    get: { vm.lastError != nil },
                    set: { if !$0 { vm.lastError = nil } })) {
            Button("OK") { vm.lastError = nil }
        } message: {
            Text(vm.lastError ?? "")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            Text(vm.state.displayLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var statusColor: Color {
        switch vm.state {
        case .idle:        return .gray
        case .connecting:  return .yellow
        case .handshaking: return .orange
        case .connected:   return .green
        case .disconnected: return .secondary
        case .failed:      return .red
        }
    }

    private func connectTapped() {
        // Passwords are NEVER persisted (not in Keychain, not in favorites) —
        // the user types them per connection. Keeps remote credentials out of
        // local storage and avoids the macOS keychain-access prompt.
        vm.connect(to: host,
                   username: username.isEmpty ? nil : username,
                   password: password.isEmpty ? nil : password,
                   endpointKind: endpointKind,
                   trustAllCertificates: trustAllCertificates,
                   sharePath: sharePath.isEmpty ? nil : sharePath,
                   resolution: resolution)
    }

    /// Pre-populate the connect form from a favorite. Does NOT connect — the
    /// user types the password and clicks Connect. Optional fields that were
    /// left empty in the favorite are left empty here too.
    private func loadFavorite(_ fav: ServerFavorite) {
        host = fav.displayHostPort
        username = fav.username ?? ""
        endpointKind = fav.endpointKind
        trustAllCertificates = fav.trustAllCertificates
        sharePath = fav.sharePath ?? ""
        resolution = fav.resolution
        password = ""
    }
}

private struct FavoriteRow: View {
    let fav: ServerFavorite
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.name.isEmpty ? fav.host : fav.name)
                    .font(.body)
                Text("\(fav.displayHostPort) · \(fav.endpointKind.displayName) · \(fav.resolution.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: connect) { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Load into the connect form (then type password and Connect)")
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
    }
}

private struct FavoriteEditor: View {
    @State private var draft: ServerFavorite
    let onSave: (ServerFavorite?) -> Void

    init(initial: ServerFavorite,
         onSave: @escaping (ServerFavorite?) -> Void) {
        self._draft = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorite")
                .font(.headline)

            // Explicit labels with a guaranteed label column: SwiftUI Form
            // clips leading placeholder text on macOS (same fix as ConnectView).
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Name:")
                        .gridColumnAlignment(.trailing)
                    TextField("optional label (defaults to host)", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Host:")
                    TextField("host or host:port", text: $draft.host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port:")
                    HStack {
                        Stepper("\(draft.port)", value: $draft.port, in: 1...65535)
                        Spacer()
                    }
                }
                GridRow {
                    Text("Username:")
                    TextField("optional", text: Binding(
                        get: { draft.username ?? "" },
                        set: { draft.username = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Endpoint:")
                    Picker("", selection: $draft.endpointKind) {
                        ForEach(EndpointKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                GridRow {
                    Text("Resolution:")
                    Picker("", selection: $draft.resolution) {
                        ForEach(RDPResolution.presets) { res in
                            Text(res.displayName).tag(res)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                GridRow {
                    Text("Share folder:")
                    TextField("optional, e.g. ~/Documents", text: Binding(
                        get: { draft.sharePath ?? "" },
                        set: { draft.sharePath = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Toggle("Trust self-signed certificates (lab use only)",
                           isOn: $draft.trustAllCertificates)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { onSave(nil) }
                Button("Save") {
                    var toSave = draft
                    if toSave.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        toSave.name = toSave.host
                    }
                    if let s = toSave.sharePath,
                       s.trimmingCharacters(in: .whitespaces).isEmpty {
                        toSave.sharePath = nil
                    }
                    onSave(toSave)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}