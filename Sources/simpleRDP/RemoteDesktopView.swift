//
// RemoteDesktopView.swift — NSView-backed remote desktop surface.
//
// One view owns BOTH drawing and input geometry: the aspect-fit rectangle is
// computed once (imageRect) and used to place pixels and to map local clicks
// back to remote coordinates, so the two can never drift apart.
//
// Input notes:
//   - Keyboard: keyDown/keyUp go through MacToRDPKeyMap (physical-position
//     mapping); flagsChanged handles the modifiers. Unmapped printable keys
//     fall back to Unicode PDUs inside RemoteInput.
//   - Mouse: left/right/middle + drag + move (throttled to ~60 Hz). Ctrl-click
//     is treated as right-click, per Mac convention.
//   - Scroll: macOS trackpads emit many small deltas; we accumulate them into
//     whole RDP wheel notches (120 units each).
//   - Focus: grabbing first-responder status on click, and releasing all
//     held keys when the window resigns key, so no stuck keys server-side.
//   - ⌘-based menu shortcuts (⌘Q etc.) are still handled by the app menu and
//     never reach the remote session — standard behavior for Mac RDP clients.
//

import SwiftUI
import AppKit

struct RemoteDesktopView: NSViewRepresentable {
    let image: CGImage?
    let input: RemoteInput

    func makeNSView(context: Context) -> RemoteDesktopNSView {
        let view = RemoteDesktopNSView()
        view.input = input
        return view
    }

    func updateNSView(_ nsView: RemoteDesktopNSView, context: Context) {
        nsView.image = image
    }
}

final class RemoteDesktopNSView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }
    var input: RemoteInput?

    private var lastMoveSent = Date.distantPast
    private var wheelRemainder = CGPoint.zero
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        guard let window else { return }
        // Release held keys if the user switches away mid-press.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.input?.releaseAllKeys()
        }
        // Grab keyboard focus as soon as we're in a window.
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    override func resignFirstResponder() -> Bool {
        input?.releaseAllKeys()
        return super.resignFirstResponder()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.interpolationQuality = .high
        context?.draw(image, in: imageRect())
    }

    /// Aspect-fit rectangle of the remote frame inside our bounds.
    /// The view is NOT flipped (default AppKit coords, y grows upward).
    private func imageRect() -> CGRect {
        guard let image else { return .zero }
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let size = CGSize(width: iw * scale, height: ih * scale)
        return CGRect(origin: CGPoint(x: (bounds.width - size.width) / 2,
                                      y: (bounds.height - size.height) / 2),
                      size: size)
    }

    /// Maps a point in view coordinates to remote desktop coordinates.
    /// Returns nil when the point is in the letterbox margin.
    private func remotePoint(for viewPoint: NSPoint) -> (x: Int, y: Int)? {
        guard let image else { return nil }
        let target = imageRect()
        guard target.contains(viewPoint) else { return nil }
        let x = Int((viewPoint.x - target.minX) * CGFloat(image.width) / target.width)
        // y grows upward in AppKit (unflipped view), downward on the remote.
        let y = Int((target.maxY - viewPoint.y) * CGFloat(image.height) / target.height)
        return (x, y)
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int)? {
        remotePoint(for: convert(event.locationInWindow, from: nil))
    }

    /// Like remotePoint(for:) but clamps into the remote rect instead of
    /// returning nil. Used for button events: a mouseUp delivered outside the
    /// image (drag released past the edge) must still reach the server,
    /// otherwise the remote is left with a stuck pressed button.
    private func remotePointClamped(for event: NSEvent) -> (x: Int, y: Int)? {
        guard let image else { return nil }
        let target = imageRect()
        let viewPoint = convert(event.locationInWindow, from: nil)
        let px = min(max(viewPoint.x, target.minX), target.maxX)
        let py = min(max(viewPoint.y, target.minY), target.maxY)
        let x = Int((px - target.minX) * CGFloat(image.width) / target.width)
        let y = Int((target.maxY - py) * CGFloat(image.height) / target.height)
        return (min(max(x, 0), image.width - 1), min(max(y, 0), image.height - 1))
    }

    // MARK: - Mouse buttons

    private func sendButton(_ button: RemoteMouseButton, down: Bool, event: NSEvent) {
        guard let p = remotePointClamped(for: event) else { return }
        input?.mouseButton(button, down: down, x: p.x, y: p.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Mac convention: Ctrl-click == right-click.
        let button: RemoteMouseButton = event.modifierFlags.contains(.control) ? .right : .left
        sendButton(button, down: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        let button: RemoteMouseButton = event.modifierFlags.contains(.control) ? .right : .left
        sendButton(button, down: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) { sendButton(.right, down: true, event: event) }
    override func rightMouseUp(with event: NSEvent)   { sendButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) { sendButton(.middle, down: true, event: event) }
    override func otherMouseUp(with event: NSEvent)   { sendButton(.middle, down: false, event: event) }

    // MARK: - Mouse movement

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // .inVisibleRect keeps the area in sync with layout automatically.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    private func sendMove(_ event: NSEvent) {
        // Input PDUs are tiny, but there is no point exceeding ~60 Hz.
        let now = Date()
        guard now.timeIntervalSince(lastMoveSent) >= 1.0 / 60.0 else { return }
        lastMoveSent = now
        guard let p = remotePoint(for: event) else { return }
        input?.mouseMoved(toX: p.x, y: p.y)
    }

    override func mouseMoved(with event: NSEvent)        { sendMove(event) }
    override func mouseDragged(with event: NSEvent)      { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    // MARK: - Scroll wheel

    override func scrollWheel(with event: NSEvent) {
        guard let p = remotePoint(for: event) else { return }

        // Mice report whole line units (±1 per detent); trackpads report many
        // small point deltas. Normalize both into RDP notches.
        let pointsPerNotch: CGFloat = event.hasPreciseScrollingDeltas ? 15.0 : 1.0
        wheelRemainder.x += event.scrollingDeltaX / pointsPerNotch
        wheelRemainder.y += event.scrollingDeltaY / pointsPerNotch

        let xSteps = Int32(wheelRemainder.x.rounded(.towardZero))
        let ySteps = Int32(wheelRemainder.y.rounded(.towardZero))
        if xSteps != 0 {
            wheelRemainder.x -= CGFloat(xSteps)
            input?.mouseWheel(steps: xSteps, horizontal: true, x: p.x, y: p.y)
        }
        if ySteps != 0 {
            wheelRemainder.y -= CGFloat(ySteps)
            input?.mouseWheel(steps: ySteps, horizontal: false, x: p.x, y: p.y)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        input?.sendKey(event.keyCode, down: true, characters: event.characters)
    }

    override func keyUp(with event: NSEvent) {
        input?.sendKey(event.keyCode, down: false, characters: event.characters)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keys don't generate keyDown/keyUp; derive the new state
        // from modifierFlags for whichever modifier this keyCode belongs to.
        let isDown: Bool
        switch event.keyCode {
        case 0x38, 0x3C: isDown = event.modifierFlags.contains(.shift)
        case 0x3B, 0x3E: isDown = event.modifierFlags.contains(.control)
        case 0x3A, 0x3D: isDown = event.modifierFlags.contains(.option)
        case 0x37, 0x36: isDown = event.modifierFlags.contains(.command)
        case 0x39:       isDown = event.modifierFlags.contains(.capsLock)
        default:         return // e.g. Fn — no RDP equivalent
        }
        input?.sendKey(event.keyCode, down: isDown, characters: nil)
    }
}

