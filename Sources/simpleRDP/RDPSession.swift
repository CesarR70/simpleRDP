// RDPSession.swift — one worker owns allocation, connect, reconnect, and teardown.
// Only the documented abort API crosses threads; its pointer lifetime is locked.
import Foundation
import CFreeRDP

private final class CertTrustRegistry {
    static let shared = CertTrustRegistry()
    private let lock = NSLock()
    private var map: [UnsafeMutableRawPointer: Bool] = [:]

    func register(_ instance: UnsafeMutablePointer<freerdp>, trustAll: Bool) {
        lock.lock()
        map[UnsafeMutableRawPointer(instance)] = trustAll
        lock.unlock()
    }

    func unregister(_ instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        map.removeValue(forKey: UnsafeMutableRawPointer(instance))
        lock.unlock()
    }

    func trustAll(for instance: UnsafeMutablePointer<freerdp>?) -> Bool {
        guard let instance else { return false }
        lock.lock()
        defer { lock.unlock() }
        return map[UnsafeMutableRawPointer(instance)] ?? false
    }
}

private let verifyCertificateExCb: pVerifyCertificateEx = {
    (instance, host, port, commonName, subject, issuer, fingerprint, flags) in
    let trust = CertTrustRegistry.shared.trustAll(for: instance)
    // NOTE: use Swift string interpolation, NOT String(format:) with %s — %s
    // expects a C char* and would dereference a Swift String (segfault; the
    // crash that prompted this code path).
    let hostStr = host.map { String(cString: $0) } ?? "?"
    let cn = commonName.map { String(cString: $0) } ?? "?"
    let fp = fingerprint.map { String(cString: $0) } ?? "?"
    print("[RDPSession] certificate for \(hostStr):\(port) (CN \(cn)) fingerprint \(fp) "
          + "-> \(trust ? "ACCEPTED for this connection (verification disabled)" : "REJECTED")")
    return trust ? 2 : 0 // Accept once; never silently create a persistent pin.
}

private let verifyChangedCertificateExCb: pVerifyChangedCertificateEx = {
    (instance, host, port, commonName, subject, issuer, newFP, oldSubject, oldIssuer, oldFP, flags) in
    let trust = CertTrustRegistry.shared.trustAll(for: instance)
    let hostStr = host.map { String(cString: $0) } ?? "?"
    let cn = commonName.map { String(cString: $0) } ?? "?"
    print("[RDPSession] host key CHANGED for \(hostStr):\(port) (CN \(cn)) "
          + "-> \(trust ? "ACCEPTED for this connection (verification disabled)" : "REJECTED")")
    return trust ? 2 : 0 // Never overwrite a stored pin silently.
}

/// Top-level error type surfaced by `RDPSession`.
struct RDPError: Error, LocalizedError {
    let message: String
    let freerdpCode: UInt32?

    var errorDescription: String? { message }
}

final class RDPSession: @unchecked Sendable {
    let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    let framebuffer = Framebuffer()
    let input = RemoteInput()
    let clipboard = ClipboardChannel()

    private let control = NSLock()
    private var active = false
    private var stopping = false
    private var abortContext: UnsafeMutablePointer<rdpContext>?
    private var pendingResolution: RDPResolution?
    private var resolutionValue: RDPResolution?

    var currentResolution: RDPResolution? {
        control.lock()
        defer { control.unlock() }
        return resolutionValue
    }

    var isRunning: Bool {
        control.lock()
        defer { control.unlock() }
        return active
    }

    /// Used on application termination after disconnect has signalled abort.
    /// No resources are forcibly freed if a library call is slow to return.
    func isQuiescent() -> Bool { !isRunning && clipboard.fileDownloadQueue.operationCount == 0 }

    init() {
        _ = Self.registerAddinProviderOnce
        var continuation: AsyncStream<ConnectionState>.Continuation!
        stateStream = AsyncStream { continuation = $0 }
        stateContinuation = continuation
    }

    private static let registerAddinProviderOnce: Void = {
        _ = freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0)
    }()

    deinit { stateContinuation.finish() }

    private var shouldStop: Bool {
        control.lock()
        defer { control.unlock() }
        return stopping
    }

    func connect(to hostPort: String, username: String?, password: String?,
                 endpointKind: EndpointKind = .auto, trustAllCertificates: Bool = false,
                 sharePath: String? = nil, resolution: RDPResolution? = nil) throws {
        let address = try ConnectionAddress(hostPort)
        let size = resolution ?? .defaultResolution
        guard (200...8192).contains(size.width), (200...8192).contains(size.height) else {
            throw ValidationError("Desktop dimensions must be between 200 and 8192 pixels.")
        }
        if let sharePath, !sharePath.isEmpty {
            let path = (sharePath as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                throw ValidationError("The shared folder does not exist or is not a directory.")
            }
        }
        control.lock()
        guard !active else {
            control.unlock()
            throw ValidationError("Wait for the current session to disconnect.")
        }
        active = true
        stopping = false
        pendingResolution = nil
        resolutionValue = nil
        control.unlock()
        framebuffer.reset()
        stateContinuation.yield(.connecting(host: address.display))
        let worker = Thread { [self] in
            var finalState: ConnectionState = .disconnected(reason: nil)
            do {
                try runConnection(host: address.host, port: address.port, username: username,
                                  password: password, endpointKind: endpointKind,
                                  trustAllCertificates: trustAllCertificates,
                                  sharePath: sharePath, resolution: size)
            } catch {
                if !shouldStop { finalState = .failed(reason: error.localizedDescription) }
            }
            control.lock()
            active = false
            resolutionValue = nil
            control.unlock()
            // Only publish completion after all C resources have been destroyed.
            stateContinuation.yield(finalState)
        }
        worker.name = "simpleRDP.freerdp-worker"
        worker.start()
    }

    func disconnect() {
        control.lock()
        defer { control.unlock() }
        stopping = true
        pendingResolution = nil
        if let context = abortContext {
            _ = freerdp_abort_connect_context(context)
        }
    }

    func setResolution(width: UInt32, height: UInt32) {
        guard (200...8192).contains(width), (200...8192).contains(height) else { return }
        control.lock()
        defer { control.unlock() }
        guard active, !stopping else { return }
        pendingResolution = RDPResolution(width: width, height: height)
    }

    private func takeResolution() -> RDPResolution? {
        control.lock()
        defer { control.unlock() }
        let result = pendingResolution
        pendingResolution = nil
        return result
    }

    private func updateResolution(_ settings: UnsafePointer<rdpSettings>) {
        let size = RDPResolution(width: freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                                 height: freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight))
        control.lock()
        resolutionValue = size
        control.unlock()
    }

    private func runConnection(host: String, port: Int, username: String?, password: String?,
                               endpointKind: EndpointKind, trustAllCertificates: Bool,
                               sharePath: String?, resolution: RDPResolution) throws {
        guard !shouldStop else { return }
        guard let raw = freerdp_new() else { throw ValidationError("Unable to allocate an RDP session.") }
        var hasContext = false
        defer {
            // Prevent new input/channel sends, wait for any existing send to finish,
            // then destroy on this worker only. Never free after a timed-out join.
            input.releaseAllKeys()
            input.detach()
            clipboard.detach()
            control.lock()
            abortContext = nil
            control.unlock()
            if hasContext {
                freerdp_disconnect(raw)
                uninstallClipboardChannelHooks(for: raw, channel: clipboard)
                FramebufferRegistry.unregister(for: raw)
                CertTrustRegistry.shared.unregister(raw)
                freerdp_context_free(raw)
            }
            freerdp_free(raw)
        }
        guard freerdp_context_new(raw) else { throw ValidationError("Unable to allocate an RDP context.") }
        hasContext = true
        guard let ctx = raw.pointee.context, let settings = ctx.pointee.settings else {
            throw ValidationError("FreeRDP did not provide connection settings.")
        }
        control.lock()
        abortContext = ctx
        let cancelled = stopping
        control.unlock()
        guard !cancelled else { return }
        FramebufferRegistry.register(framebuffer, for: raw)
        installClipboardChannelHooks(on: raw, channel: clipboard)
        _ = freerdp_settings_set_string(settings, FreeRDP_ServerHostname, host)
        _ = freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, UInt32(port))
        if let username, !username.isEmpty {
            _ = freerdp_settings_set_string(settings, FreeRDP_Username, username)
        }
        if let password, !password.isEmpty {
            _ = freerdp_settings_set_string(settings, FreeRDP_Password, password)
        }

        // Auth/negotiation defaults per the plan's §9 recommendations.
        // In FreeRDP 3.x the per-protocol flags (TlsSecurity/NlaSecurity/RdpSecurity)
        // are Bool keys, and `NegotiateSecurityLayer` is the meta-bool that says
        // "let the server pick". We enable both TLS and NLA so the strongest
        // mutually-supported protocol wins; for the `.xrdp` case we turn NLA off
        // because most xrdp servers don't speak CredSSP.
        _ = freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, true)
        switch endpointKind {
        case .auto:
            _ = freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, true)
            _ = freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, true)
        case .windows:
            _ = freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, true)
            _ = freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, true)
        case .xrdp:
            _ = freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, false)
            _ = freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, false)
        }

        if trustAllCertificates {
            _ = freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, true)
        }
        CertTrustRegistry.shared.register(raw, trustAll: trustAllCertificates)
        raw.pointee.VerifyCertificateEx = verifyCertificateExCb
        raw.pointee.VerifyChangedCertificateEx = verifyChangedCertificateExCb

        // Enable the clipboard static channel; FreeRDP will advertise text
        // (and, on capable servers, file) clipboard formats.
        _ = freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, true)

        // Starting desktop size. Mid-session changes are handled by the
        // DesktopResize callback (gdi_resize), so this is just the negotiated
        // initial resolution; the user's pre-connect pick comes from the
        // connect form / favorite, defaulting to RDPResolution.defaultResolution.
        let startResolution = resolution
        _ = freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, startResolution.width)
        _ = freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, startResolution.height)

        // Optional drive redirection (rdpdr): share a Mac folder with the
        // session. On xrdp it appears under ~/thinclient_drives/<name>/.
        if let sharePath, !sharePath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (sharePath as NSString).expandingTildeInPath
            let shareName = URL(fileURLWithPath: expanded).lastPathComponent
            let added = "drive".withCString { typePtr in
                shareName.withCString { namePtr in
                    expanded.withCString { pathPtr in
                        var args: [UnsafePointer<CChar>?] = [typePtr, namePtr, pathPtr]
                        return freerdp_client_add_device_channel(settings, 3, &args)
                    }
                }
            }
            if !added {
                print("[RDPSession] warning: failed to register drive share at \(expanded)")
            }
        }

        // 2c) Channel loading is done via the LoadChannels callback (below),
        //     NOT here. See the callback comment for why timing is critical.

        // 2b) Lifecycle callbacks.
        //     PostConnect initializes the GDI software renderer, which wires up
        //     FreeRDP's update pipeline (pointer + bitmap caches, primary
        //     surface). Without it, the first pointer update from the server
        //     dereferences a NULL cache — this was the EXC_BAD_ACCESS in
        //     update_pointer_new() seen once auth succeeded and the session
        //     reached the ACTIVE state. PostDisconnect releases the GDI surface.
        //
        // 2d) LoadChannels callback. Setting RedirectClipboard=true only flips
        //     a settings flag; the cliprdr/rdpdr channels are instantiated by
        //     the client framework via freerdp_client_load_addins. That call
        //     MUST happen from LoadChannels (invoked by freerdp_connect →
        //     utils_reload_channels), NOT before connect: a channel add-in's
        //     VirtualChannelInit only registers the channel into the MCS
        //     ChannelDefArray (→ the GCC channel list the server sees) when it
        //     runs inside the connect sequence — g_Instance is thread-local and
        //     only set there. Loading early registers the channels locally but
        //     they are never advertised, so the server never opens them.
        //     (Symptom: entry point runs, then total silence — exactly what
        //     the debug log showed.)
        raw.pointee.LoadChannels = { instance in
            guard let instance, let context = instance.pointee.context,
                  let channels = context.pointee.channels,
                  let settings = context.pointee.settings
            else { return ObjCBool(false) }
            return ObjCBool(freerdp_client_load_addins(channels, settings))
        }

        // 2e) Lifecycle callbacks.
        //     Note the ObjCBool hop: WinPR's BOOL imports as Swift Bool on
        //     function declarations, but as ObjCBool in function-POINTER
        //     typedefs (ABI exactness), so a tiny non-capturing @convention(c)
        //     closure bridges the two.
        raw.pointee.PostConnect = { instance in
            guard let instance else { return ObjCBool(false) }
            guard simplerdp_post_connect(instance) else { return ObjCBool(false) }
            // gdi_init registered its own update callbacks; install ours on
            // top (same pattern as FreeRDP's sample client) so EndPaint feeds
            // the Framebuffer and DesktopResize reallocs the GDI surface.
            installFrameCallbacks(on: instance)
            return ObjCBool(true)
        }
        raw.pointee.PostDisconnect = gdi_free


        guard !shouldStop else { return }
        stateContinuation.yield(.handshaking)
        guard freerdp_connect(raw) else { throw connectionError(ctx) }
        guard !shouldStop else { return }
        input.attach(to: raw)
        updateResolution(settings)
        stateContinuation.yield(.connected)
        var handles = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        while !shouldStop && !freerdp_shall_disconnect_context(ctx) {
            if let size = takeResolution() {
                input.releaseAllKeys()
                input.detach()
                clipboard.detach()
                freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, size.width)
                freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, size.height)
                guard freerdp_reconnect(raw) else { throw connectionError(ctx) }
                guard !shouldStop else { break }
                input.attach(to: raw)
                updateResolution(settings)
                continue
            }
            let count = freerdp_get_event_handles(ctx, &handles, 64)
            if count == 0 { break }
            if WaitForMultipleObjects(count, &handles, false, 100) == 0xFFFF_FFFF { break }
            if !freerdp_check_event_handles(ctx) { break }
        }
        if !shouldStop, freerdp_get_last_error(ctx) != 0 { throw connectionError(ctx) }
    }

    private func connectionError(_ context: UnsafeMutablePointer<rdpContext>) -> RDPError {
        let code = freerdp_get_last_error(context)
        let reason = freerdp_get_last_error_string(code).map { String(cString: $0) } ?? "RDP connection ended."
        return RDPError(message: reason, freerdpCode: code)
    }
}
