//
// RemoteInput.swift — keyboard/mouse input sender (client → server).
//
// Input PDUs are sent from the main thread while the event-loop thread
// concurrently runs freerdp_check_fds. This mirrors FreeRDP's own Mac client
// (MRDPView sends input from the AppKit thread): all output converges on
// transport_write(), which is internally locked in FreeRDP 3.x, and the input
// path only reads session state that is stable after connect. Our NSLock
// serializes senders and protects attach/detach.
//
// Keyboard: physical-position mapping — macOS virtual keyCodes translate to
// RDP (PC AT set-1) scancodes, so shortcuts and games behave regardless of
// the Mac's layout. Keys outside the ANSI set fall back to Unicode keyboard
// PDUs, which are layout-independent.
//

import Foundation
import CFreeRDP

/// Mouse buttons, in RDP terms.
enum RemoteMouseButton {
    case left, right, middle
}

final class RemoteInput: @unchecked Sendable {
    // MS-RDPBCGR 2.2.8.1.1.3.1.1.1 (keyboard) / 2.2.8.1.1.3.1.1.3 (pointer).
    // Defined here because the KBD_FLAGS_*/PTR_FLAGS_* macros in
    // freerdp/input.h use line continuations and may not survive the Clang
    // importer.
    private enum KBD {
        static let extended: UInt16 = 0x0100
        static let down: UInt16     = 0x4000
        static let release: UInt16  = 0x8000
    }
    private enum PTR {
        static let move: UInt16          = 0x0800
        static let down: UInt16          = 0x8000
        static let wheel: UInt16         = 0x0200
        static let hwheel: UInt16        = 0x0400
        static let wheelNegative: UInt16 = 0x0100
        static let wheelMask: Int32      = 0x01FF
        static func buttonFlag(_ b: RemoteMouseButton) -> UInt16 {
            switch b {
            case .left:   return 0x1000
            case .right:  return 0x2000
            case .middle: return 0x4000
            }
        }
    }

    // Pressed-key tags: bit 16 = extended scancode, bit 17 = unicode key.
    private static let extendedTag: UInt32 = 1 << 16
    private static let unicodeTag: UInt32  = 1 << 17

    private let lock = NSLock()
    private var input: UnsafeMutablePointer<rdpInput>?

    /// Keys currently held down. Used to release everything on focus loss or
    /// disconnect so the server never sees a stuck key.
    private var pressed: Set<UInt32> = []

    // MARK: - Lifecycle (called from RDPSession)

    func attach(to instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        input = instance.pointee.context?.pointee.input
        pressed.removeAll()
        lock.unlock()
    }

    func detach() {
        lock.lock()
        input = nil
        pressed.removeAll()
        lock.unlock()
    }

    /// Release every key we believe is down. Called on window focus loss and
    /// before disconnect. Safe to call when detached.
    func releaseAllKeys() {
        lock.lock()
        defer { lock.unlock() }
        guard let input else { pressed.removeAll(); return }
        for tag in pressed {
            if tag & Self.unicodeTag != 0 {
                _ = freerdp_input_send_unicode_keyboard_event(input, KBD.release,
                                                              UInt16(tag & 0xFFFF))
            } else {
                var flags = KBD.release
                if tag & Self.extendedTag != 0 { flags |= KBD.extended }
                _ = freerdp_input_send_keyboard_event(input, flags, UInt8(tag & 0xFF))
            }
        }
        pressed.removeAll()
    }

    // MARK: - Keyboard

    /// Press or release a physical key, addressed by macOS virtual keyCode.
    /// Unmapped printable keys fall back to a Unicode keyboard PDU.
    func sendKey(_ keyCode: UInt16, down: Bool, characters: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let input else { return }

        if let mapped = MacToRDPKeyMap.table[keyCode] {
            let tag = UInt32(mapped.code) | (mapped.extended ? Self.extendedTag : 0)
            // Dedupe: flagsChanged reports modifier "down" on every modifier
            // transition, not just for the key that changed.
            if down, pressed.contains(tag) { return }
            if !down, !pressed.contains(tag) { return }
            var flags: UInt16 = down ? KBD.down : KBD.release
            if mapped.extended { flags |= KBD.extended }
            _ = freerdp_input_send_keyboard_event(input, flags, mapped.code)
            if down { pressed.insert(tag) } else { pressed.remove(tag) }
            return
        }

        // Unicode fallback for keys outside the ANSI map (ISO § key,
        // international layouts, …). Layout-independent. Unlike scancode
        // keys, repeats are sent through so held keys keep typing.
        guard let scalar = characters?.utf16.first, scalar > 0x1F else { return }
        let tag = Self.unicodeTag | UInt32(scalar)
        if !down, !pressed.contains(tag) { return }
        _ = freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD.release, scalar)
        if down { pressed.insert(tag) } else { pressed.remove(tag) }
    }

    // MARK: - Mouse

    func mouseMoved(toX x: Int, y: Int) {
        sendPointer(flags: PTR.move, x: x, y: y)
    }

    func mouseButton(_ button: RemoteMouseButton, down: Bool, x: Int, y: Int) {
        var flags = PTR.buttonFlag(button)
        if down { flags |= PTR.down }
        sendPointer(flags: flags, x: x, y: y)
    }

    /// steps: signed number of wheel notches (positive = up / left).
    func mouseWheel(steps: Int32, horizontal: Bool, x: Int, y: Int) {
        guard steps != 0 else { return }
        var flags: UInt16 = horizontal ? PTR.hwheel : PTR.wheel
        // One notch == 120 units, capped at the 9-bit WheelRotationMask.
        let rotation = min(abs(steps) * 120, PTR.wheelMask)
        if steps < 0 { flags |= PTR.wheelNegative }
        flags |= UInt16(rotation)
        sendPointer(flags: flags, x: x, y: y)
    }

    private func sendPointer(flags: UInt16, x: Int, y: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let input else { return }
        _ = freerdp_input_send_mouse_event(input, flags,
                                           UInt16(clamping: x), UInt16(clamping: y))
    }
}

// MARK: - macOS keyCode → RDP scancode table

/// Physical-position mapping from macOS virtual keyCodes (Carbon kVK_*)
/// to RDP keyboard scancodes (PC AT set 1; `extended` sets KBD_FLAGS_EXTENDED
/// for keys in the extended set: arrows, nav cluster, right modifiers, etc.).
enum MacToRDPKeyMap {
    static let table: [UInt16: (code: UInt8, extended: Bool)] = [
        // Row: function / escape
        0x35: (0x01, false), // Escape
        0x7A: (0x3B, false), // F1
        0x78: (0x3C, false), // F2
        0x63: (0x3D, false), // F3
        0x76: (0x3E, false), // F4
        0x60: (0x3F, false), // F5
        0x61: (0x40, false), // F6
        0x62: (0x41, false), // F7
        0x64: (0x42, false), // F8
        0x65: (0x43, false), // F9
        0x6D: (0x44, false), // F10
        0x67: (0x57, false), // F11
        0x6F: (0x58, false), // F12
        0x69: (0x64, false), // F13
        0x6B: (0x65, false), // F14
        0x71: (0x66, false), // F15
        0x6A: (0x67, false), // F16
        0x40: (0x68, false), // F17
        0x4F: (0x69, false), // F18
        0x50: (0x6A, false), // F19
        0x5A: (0x6B, false), // F20

        // Number row
        0x32: (0x29, false), // ` grave
        0x12: (0x02, false), // 1
        0x13: (0x03, false), // 2
        0x14: (0x04, false), // 3
        0x15: (0x05, false), // 4
        0x17: (0x06, false), // 5
        0x16: (0x07, false), // 6
        0x1A: (0x08, false), // 7
        0x1C: (0x09, false), // 8
        0x19: (0x0A, false), // 9
        0x1D: (0x0B, false), // 0
        0x1B: (0x0C, false), // - minus
        0x18: (0x0D, false), // = equals
        0x33: (0x0E, false), // Backspace (Delete on Mac)

        // QWERTY row
        0x30: (0x0F, false), // Tab
        0x0C: (0x10, false), // Q
        0x0D: (0x11, false), // W
        0x0E: (0x12, false), // E
        0x0F: (0x13, false), // R
        0x11: (0x14, false), // T
        0x10: (0x15, false), // Y
        0x20: (0x16, false), // U
        0x22: (0x17, false), // I
        0x1F: (0x18, false), // O
        0x23: (0x19, false), // P
        0x21: (0x1A, false), // [
        0x1E: (0x1B, false), // ]
        0x2A: (0x2B, false), // \ backslash
        0x24: (0x1C, false), // Return


        // Home row
        0x00: (0x1E, false), // A
        0x01: (0x1F, false), // S
        0x02: (0x20, false), // D
        0x03: (0x21, false), // F
        0x05: (0x22, false), // G
        0x04: (0x23, false), // H
        0x26: (0x24, false), // J
        0x28: (0x25, false), // K
        0x25: (0x26, false), // L
        0x29: (0x27, false), // ; semicolon
        0x27: (0x28, false), // ' quote
        0x39: (0x3A, false), // CapsLock

        // Bottom letter row
        0x38: (0x2A, false), // Left Shift
        0x06: (0x2C, false), // Z
        0x07: (0x2D, false), // X
        0x08: (0x2E, false), // C
        0x09: (0x2F, false), // V
        0x0B: (0x30, false), // B
        0x2D: (0x31, false), // N
        0x2E: (0x32, false), // M
        0x2B: (0x33, false), // , comma
        0x2F: (0x34, false), // . period
        0x2C: (0x35, false), // / slash
        0x3C: (0x36, false), // Right Shift

        // Modifier row (Command maps to the Windows/Super key, matching what
        // Windows App and other Mac RDP clients do)
        0x3B: (0x1D, false), // Left Control
        0x3A: (0x38, false), // Left Option → Left Alt
        0x37: (0x5B, true),  // Left Command → Left Win (extended)
        0x31: (0x39, false), // Space
        0x36: (0x5C, true),  // Right Command → Right Win (extended)
        0x3D: (0x38, true),  // Right Option → Right Alt (extended)
        0x3E: (0x1D, true),  // Right Control (extended)

        // Navigation cluster (extended set)
        0x72: (0x52, true),  // Help/Insert
        0x75: (0x53, true),  // Forward Delete
        0x73: (0x47, true),  // Home
        0x77: (0x4F, true),  // End
        0x74: (0x49, true),  // Page Up
        0x79: (0x51, true),  // Page Down
        0x7E: (0x48, true),  // Up arrow
        0x7D: (0x50, true),  // Down arrow
        0x7B: (0x4B, true),  // Left arrow
        0x7C: (0x4D, true),  // Right arrow

        // Numpad
        0x47: (0x45, false), // Keypad Clear → NumLock
        0x4B: (0x35, true),  // Keypad / (extended)
        0x43: (0x37, false), // Keypad *
        0x4E: (0x4A, false), // Keypad -
        0x45: (0x4E, false), // Keypad +
        0x4C: (0x1C, true),  // Keypad Enter (extended)
        0x41: (0x53, false), // Keypad .
        0x52: (0x52, false), // Keypad 0
        0x53: (0x4F, false), // Keypad 1
        0x54: (0x50, false), // Keypad 2
        0x55: (0x51, false), // Keypad 3
        0x56: (0x4B, false), // Keypad 4
        0x57: (0x4C, false), // Keypad 5
        0x58: (0x4D, false), // Keypad 6
        0x59: (0x47, false), // Keypad 7
        0x5B: (0x48, false), // Keypad 8
        0x5C: (0x49, false), // Keypad 9
    ]
}

