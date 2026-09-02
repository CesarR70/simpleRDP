//
// RDPSession.swift — Swift wrapper around a libfreerdp session.
//
// Architecture (per RDP-Swift-Client-Plan.md §3, §6):
//   - All FreeRDP interaction is hidden behind this type. UI never touches C.
//   - The FreeRDP event loop runs on a dedicated pthread off the main thread.
//     The actor isolates pointer lifetime; UI updates marshal back to MainActor
//     via `stateStream`.
//
// Lifecycle:
//   1. `connect(...)` calls `freerdp_new` + `freerdp_context_new`, configures
//      settings via the modern `freerdp_settings_set_*` API, and finally
//      `freerdp_connect`.
//   2. A background thread drives `freerdp_check_fds` until the session ends.
//   3. `disconnect()` calls `freerdp_disconnect`, then `freerdp_context_free`
//      and `freerdp_free` (context must be freed BEFORE the instance).
//
// Framebuffer + input (Milestone 2):
//   - PostConnect initializes the GDI software renderer, then installs
//     BeginPaint/EndPaint/DesktopResize callbacks. EndPaint copies each
//     composited frame into `framebuffer` (see Framebuffer.swift); SessionView
//     polls it at ~30 Hz and paints a CGImage.
//   - Input flows through `input` (RemoteInput): RemoteDesktopView captures
//     AppKit key/mouse events on the main thread and forwards them as RDP
//     input PDUs.
//   - CLIPRDR clipboard (Milestone 4): ClipboardChannel bridges NSPasteboard.
//     Text works both directions. File copy/paste works BOTH ways:
//     Mac → server serves FileGroupDescriptorW + FileContents (the xrdp
//     thinclient_drives path is server-side); server → Mac downloads via
//     FileContents RANGE requests into a cache dir and publishes real file
//     URLs (Finder won't paste file promises). Image clipboard is future work.
//   - No certificate trust callback yet (cert-pinning is Milestone 5). We
//     expose a `trustAllCertificates` flag for lab/test setups.
//

import Foundation
import CFreeRDP

// MARK: - Certificate verification callbacks
//
// FreeRDP's TLS layer calls these when it cannot decide a certificate's fate
// on its own: an unknown host with no pinned key, a PINNED KEY THAT CHANGED
// (VerifyChangedCertificateEx — the "REMOTE HOST IDENTIFICATION HAS CHANGED"
// case), or a name mismatch. Without them the handshake aborts with
// ERRCONNECT_TLS_CONNECT_FAILED.
//
// Policy for a lab/dev client: when the connection opted into
// `trustAllCertificates`, accept the presented certificate and REPLACE the
// stored pin (return 1). When it did not, reject (return 0). A future
// Milestone-5 nicety is a real "accept once / accept always" prompt driving
// the return value.
//
// `@convention(c)` closures cannot capture Swift context, so the
// trust-all flag is looked up per-instance via a small registry, mirroring
// FramebufferRegistry.

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
          + "-> \(trust ? "ACCEPTED & stored (trust-all)" : "REJECTED")")
    return trust ? 1 : 0 // 1 = accept & store, 0 = reject
}

private let verifyChangedCertificateExCb: pVerifyChangedCertificateEx = {
    (instance, host, port, commonName, subject, issuer, newFP, oldSubject, oldIssuer, oldFP, flags) in
    let trust = CertTrustRegistry.shared.trustAll(for: instance)
    let hostStr = host.map { String(cString: $0) } ?? "?"
    let cn = commonName.map { String(cString: $0) } ?? "?"
    print("[RDPSession] host key CHANGED for \(hostStr):\(port) (CN \(cn)) "
          + "-> \(trust ? "ACCEPTED, pin replaced (trust-all)" : "REJECTED")")
    return trust ? 1 : 0 // 1 = accept new key and overwrite the stored pin
}

/// Top-level error type surfaced by `RDPSession`.
struct RDPError: Error, LocalizedError {
    let message: String
    let freerdpCode: UInt32?

    var errorDescription: String? { message }
}

actor RDPSession {
    // MARK: - Public state

    /// Stream of connection lifecycle events. Safe to consume from MainActor;
    /// the actor publishes each transition exactly once.
    nonisolated let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    private(set) var state: ConnectionState = .idle {
        didSet { stateContinuation.yield(state) }
    }

    // MARK: - FreeRDP handles

    /// Pointer to `freerdp` (typedef for `struct rdp_freerdp`).
    /// Held only inside the actor to enforce single-threaded access.
    /// Released on `disconnect()` and deinit.
    private var instance: UnsafeMutablePointer<freerdp>?

    /// Latest remote frame, fed by the EndPaint callback. Read by SessionView
    /// on the main thread. `let` of a Sendable type, so it is safe to access
    /// cross-actor without `await`.
    let framebuffer = Framebuffer()

    /// Keyboard/mouse input sender. Attached once the handshake completes
    /// (the rdpInput handle is valid earlier, but sending before the input
    /// channel is up would just error out). Same cross-actor `let` story.
    let input = RemoteInput()

    /// CLIPRDR clipboard bridge (text both ways, files Mac→server). Hooks are
    /// installed before connect; the channel attaches when FreeRDP's cliprdr
    /// add-in reports itself via the ChannelConnected PubSub event.
    let clipboard = ClipboardChannel()

    /// Worker thread driving `freerdp_check_fds`.
    private var loopThread: Thread?
    /// Loop sentinel. Marked `nonisolated(unsafe)` so the worker thread can
    /// read it without an actor hop. Writes are infrequent (only on connect
    /// start and disconnect), reads are a `Bool` aligned load — a torn read
    /// is impossible on x86/arm64.
    private nonisolated(unsafe) var stopFlag = false

    /// Pending client-initiated resize. Written by the main actor in
    /// `setResolution(width:height:)` and consumed/cleared by the event-loop
    /// thread at the top of its loop, which is the ONLY place that actually
    /// calls `freerdp_reconnect` — so a resize request can never race the loop
    /// and tear a connection. Same nonisolated(unsafe) reasoning as stopFlag:
    /// request is a fire-and-forget from the UI, and the loop drains it once.
    private nonisolated(unsafe) var resizeWidth: UInt32 = 0
    private nonisolated(unsafe) var resizeHeight: UInt32 = 0
    private nonisolated(unsafe) var resizePending = false

    /// Session-reported resolution backing `currentResolution`. Set on connect
    /// and after each successful resize reconnect, so the status bar reflects
    /// the negotiated desktop size without depending on EndPaint timing. Same
    /// nonisolated(unsafe) reasoning as stopFlag: pair of aligned UInt32s written
    /// once per resize, read by the UI's 30 Hz poll.
    private nonisolated(unsafe) var currentResolutionValue: RDPResolution?

    /// The resolution the active session is currently running at, readable
    /// from the UI without an actor hop.
    nonisolated var currentResolution: RDPResolution? { currentResolutionValue }

    // MARK: - Init / deinit

    init() {
        // Static channel add-ins (cliprdr, rdpdr, …) are located through a
        // process-wide provider chain. The full client framework registers the
        // static-table provider inside freerdp_client_context_new() — which we
        // don't use — so we must register it ourselves, exactly once. Without
        // it, EVERY static channel lookup fails, freerdp_client_load_addins()
        // errors out, and no virtual channel (clipboard included) ever loads.
        _ = Self.registerAddinProviderOnce

        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.stateStream = AsyncStream { c in continuation = c }
        self.stateContinuation = continuation
    }

    private static let registerAddinProviderOnce: Void = {
        _ = freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0)
    }()

    deinit {
        // Synchronously free the FreeRDP instance if the user forgot to disconnect.
        if let raw = instance {
            freerdp_disconnect(raw)
            destroyInstance(raw)
        }
        stateContinuation.finish()
    }

    // MARK: - Public API

    /// Establish an RDP connection. Returns once the synchronous handshake
    /// completes (success or failure). The session continues running in the
    /// background until `disconnect()` is called.
    func connect(to hostPort: String,
                 username: String?,
                 password: String?,
                 endpointKind: EndpointKind = .auto,
                 trustAllCertificates: Bool = false,
                 sharePath: String? = nil,
                 resolution: RDPResolution? = nil) async throws {
        guard !state.isActive else {
            throw RDPError(message: "Session is already active.", freerdpCode: nil)
        }

        let (host, port) = FavoritesStore.splitHostPort(hostPort)
        state = .connecting(host: "\(host):\(port)")

        // 1) Allocate instance.
        guard let raw: UnsafeMutablePointer<freerdp> = freerdp_new() else {
            state = .failed(reason: "freerdp_new() returned NULL")
            throw RDPError(message: "freerdp_new() returned NULL", freerdpCode: nil)
        }
        self.instance = raw

        // 1b) Allocate the context. In FreeRDP 3.x, `freerdp_new()` ONLY
        //     allocates the `rdp_freerdp` options struct — `instance.context`
        //     stays NULL until `freerdp_context_new()` runs. The context owns
        //     the settings, channels, and event-loop state, so omitting this
        //     call is exactly the "FreeRDP instance has no context" failure.
        guard freerdp_context_new(raw) else {
            destroyInstance(raw)
            self.instance = nil
            state = .failed(reason: "freerdp_context_new() failed")
            throw RDPError(message: "freerdp_context_new() failed", freerdpCode: nil)
        }

        // The C paint callbacks can't capture Swift context, so they find this
        // session's Framebuffer via the registry (keyed by instance address).
        // Registered before connect because frames can arrive DURING the
        // synchronous handshake. Unregistered in destroyInstance().
        FramebufferRegistry.register(framebuffer, for: raw)

        // Clipboard: subscribe to the cliprdr channel's lifecycle events.
        // ChannelConnected fires during freerdp_connect, so hooks go in now.
        installClipboardChannelHooks(on: raw, channel: clipboard)

        // 2) Configure settings via the modern *_set_* API.
        //    Settings live on `rdp_context` (NOT on the freerdp struct — the
        //    `freerdp.settings` field is deprecated and only present when
        //    built with WITH_FREERDP_DEPRECATED). Reach them via the context.
        //    After freerdp_context_new() succeeds both pointers are guaranteed;
        //    the guards stay as defensive checks against future API changes.
        guard let ctx = raw.pointee.context else {
            destroyInstance(raw)
            self.instance = nil
            state = .failed(reason: "freerdp instance had no context")
            throw RDPError(message: "freerdp instance had no context", freerdpCode: nil)
        }
        guard let settings = ctx.pointee.settings else {
            let code = freerdp_get_last_error(ctx)
            destroyInstance(raw)
            self.instance = nil
            state = .failed(reason: "missing settings pointer")
            throw RDPError(message: "freerdp instance had no settings", freerdpCode: code)
        }

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
        // Register the trust-all decision for the cert callbacks, and install
        // the callbacks themselves. IgnoreCertificate only bypasses CA/chain
        // validation; the known-hosts PIN-CHANGE check (which is what fails on
        // a re-imaged/reinstalled server) is only bypassable via
        // VerifyChangedCertificateEx. Unregistered on teardown.
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
        let startResolution = resolution ?? .defaultResolution
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
        //     reached the ACTIVE state. The framebuffer stays headless until
        //     Milestone 2 paints it. PostDisconnect releases the GDI surface.
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

        // 3) Synchronous handshake.
        state = .handshaking
        let ok = freerdp_connect(raw)
        if !ok {
            let code = freerdp_get_last_error(ctx)
            let reason = freerdp_get_last_error_string(code).map { String(cString: $0) }
                ?? "freerdp_connect failed (code \(code))"
            // Safe on a partially-connected instance; runs PostDisconnect
            // (gdi_free) if PostConnect already fired, avoiding a GDI leak.
            freerdp_disconnect(raw)
            destroyInstance(raw)
            self.instance = nil
            state = .failed(reason: reason)
            throw RDPError(message: reason, freerdpCode: code)
        }

        // Input channel is live once the handshake completes.
        input.attach(to: raw)

        // Publish the negotiated starting size for the status bar.
        currentResolutionValue = startResolution

        state = .connected

        // 4) Spawn the event-loop thread.
        stopFlag = false
        // Capture the raw pointer's address as a Sendable Int, then
        // reconstruct on the worker thread. This avoids the strict-concurrency
        // warning about non-Sendable pointer capture in @Sendable closures.
        let rawAddress = Int(bitPattern: raw)
        let thread = Thread { [weak self] in
            let typed = UnsafeMutablePointer<freerdp>(bitPattern: rawAddress)
            self?.runEventLoop(typed)
        }
        thread.name = "simpleRDP.freerdp-loop"
        thread.start()
        self.loopThread = thread
    }

    /// Request a live change of the ACTIVE session's desktop size.
    ///
    /// This only queues the request; the event-loop thread applies it (routes
    /// through `freerdp_reconnect`), so there is no visible disconnect and the
    /// session's swap between ConnectView/SessionView is never triggered. The
    /// chosen resolution is reflected in the status bar via `framebuffer.dimensions`
    /// once the server negotiates the new size and EndPaint re-publishes.
    ///
    /// No-op when the session isn't active. If the server rejects the new size,
    /// it simply stays at its current resolution — no harm done.
    func setResolution(width: UInt32, height: UInt32) {
        guard state == .connected, let raw = instance, raw.pointee.context != nil else { return }
        // Fire-and-forget: the event-loop thread picks this up on its next
        // pass (within ~100 ms, the loop's wait timeout).
        resizeWidth = width
        resizeHeight = height
        resizePending = true
    }

    /// Tear down the session.
    func disconnect() {
        stopFlag = true
        if let raw = instance {
            // Politely release held keys before the channel goes away.
            input.releaseAllKeys()
            clipboard.detach()
            freerdp_disconnect(raw)
        }
        // Bounded join so we don't deadlock if the C call is stuck.
        loopThread?.cancel()
        let deadline = Date().addingTimeInterval(2.0)
        while loopThread?.isExecuting == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        loopThread = nil
        if let raw = instance {
            destroyInstance(raw)
            instance = nil
        }
        state = .disconnected(reason: nil)
    }

    // MARK: - Internals

    /// Release a FreeRDP instance completely. The header contract on
    /// `rdp_freerdp.context` requires `freerdp_context_free()` to run BEFORE
    /// `freerdp_free()` — freeing the instance alone leaks the context,
    /// settings, and channel state.
    private nonisolated func destroyInstance(_ raw: UnsafeMutablePointer<freerdp>) {
        FramebufferRegistry.unregister(for: raw)
        CertTrustRegistry.shared.unregister(raw)
        input.detach()
        uninstallClipboardChannelHooks(for: raw, channel: clipboard)
        if raw.pointee.context != nil {
            freerdp_context_free(raw)
        }
        freerdp_free(raw)
    }

    /// Drives FreeRDP's event loop until disconnect. Called on a dedicated
    /// thread. Mirrors the FreeRDP sample client's loop.
    ///
    /// In FreeRDP 3.x the naming is a trap:
    ///   - `freerdp_check_fds(instance)`        — transport/RDP PDUs ONLY.
    ///   - `freerdp_check_event_handles(ctx)`   — that PLUS the channel-manager
    ///     queue drain (`freerdp_channels_check_fds`).
    /// Channel writes (VirtualChannelWriteEx — used by every cliprdr/rdpdr
    /// send) are ENQUEUED on `channels->queue`; only the queue drain puts
    /// those bytes on the socket. Looping on bare freerdp_check_fds therefore
    /// starves ALL outgoing channel traffic while incoming channel data keeps
    /// arriving — which is exactly the failure we chased (channels connect,
    /// server greets us, then goes silent the moment we answer).
    ///
    /// `freerdp_get_event_handles` includes the channel queue's event handle,
    /// so a queued channel write wakes the wait immediately. The 100 ms cap
    /// bounds stopFlag latency; WAIT_TIMEOUT turns are harmless no-ops.
    ///
    /// The build warnings about calling actor-isolated methods from a Thread
    /// closure are intentional: `runEventLoop` only reads `stopFlag` via its
    /// nonisolated accessor and publishes results through `Task { await ... }`
    /// which hops back to the actor.
    private nonisolated func runEventLoop(_ raw: UnsafeMutablePointer<freerdp>?) {
        guard let raw, let ctx = raw.pointee.context else {
            Task { [weak self] in await self?.markDisconnected() }
            return
        }

        var handles = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let waitFailed: UInt32 = 0xFFFF_FFFF // WAIT_FAILED

        while !stopFlag {
            // Drain any client-initiated resize before touching handles. Applied
            // here so freerdp_reconnect (which re-establishes the same session at
            // the new size) runs on THIS thread — the only thread driving the event
            // loop — never racing freerdp_check_event_handles. The next pass then
            // waits on the fresh handle set.
            if resizePending {
                resizePending = false
                applyResize(on: raw, ctx: ctx)
                if stopFlag { break }
                continue
            }

            let count = freerdp_get_event_handles(ctx, &handles, 64)
            if count == 0 { break } // instance is going away

            let waitStatus = WaitForMultipleObjects(count, &handles, false, 100)
            if waitStatus == waitFailed { break }

            if !freerdp_check_event_handles(ctx) { break } // fatal or disconnected
        }

        // After the loop, hop back to the actor to publish the final state.
        Task { [weak self] in
            await self?.markDisconnected()
        }
    }

    /// Apply a queued resolution change to the live session. Runs on the
    /// event-loop thread. Updates the stored desktop settings, then asks FreeRDP
    /// to reconnect the session at the new size; the server replies with a
    /// Deactivate-Reactivate sequence and the existing DesktopResize callback
    /// reallocs the GDI surface, after which EndPaint re-publishes the frame at
    /// the new dimensions.
    private nonisolated func applyResize(on raw: UnsafeMutablePointer<freerdp>, ctx: UnsafeMutablePointer<rdpContext>) {
        guard let settings = ctx.pointee.settings else { return }
        let w = resizeWidth
        let h = resizeHeight
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, w)
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, h)
        guard freerdp_reconnect(raw) else {
            let code = freerdp_get_last_error(ctx)
            let reason = freerdp_get_last_error_string(code).map { String(cString: $0) } ?? "unknown"
            print("[RDPSession] resize reconnect failed: \(reason)")
            return
        }
        currentResolutionValue = RDPResolution(width: w, height: h)
        print("[RDPSession] resize applied at \(w)×\(h)")
    }

    private func markDisconnected() {
        guard state.isActive else { return }
        let reason: String?
        if let raw = instance, let ctx = raw.pointee.context {
            let code = freerdp_get_last_error(ctx)
            reason = freerdp_get_last_error_string(code).map { String(cString: $0) }
        } else {
            reason = nil
        }
        state = .disconnected(reason: reason)
    }
}

// MARK: - Bridge helpers

extension RDPSession {
    /// Convenience for the UI: returns a string identifying the current target.
    var target: String? {
        switch state {
        case .connecting(let h): return h
        case .connected:         return "connected"
        default:                 return nil
        }
    }
}