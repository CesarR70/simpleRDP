//
// Framebuffer.swift — thread-safe holder for the latest remote frame.
//
// Written by the FreeRDP event-loop thread (from the EndPaint callback, which
// fires after each batch of screen updates has been composited into the GDI
// primary buffer) and read by the main thread (SessionView's refresh timer).
//
// Threading model:
//   - publishFrame() runs on whatever thread FreeRDP is dispatching on. It
//     takes the lock, memcpy's the frame, and bumps `revision`.
//   - latestImage() runs on the main thread. It only copies when the revision
//     changed, so an idle desktop costs ~nothing at 30 Hz polling.
//   - The UI never touches the GDI buffer directly, so a server-side update
//     can never tear a frame that is on screen.
//

import Foundation
import CoreGraphics
import CFreeRDP

final class Framebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: UnsafeMutableRawPointer?
    private var capacity = 0
    private var width = 0
    private var height = 0
    private var revision: UInt64 = 0

    /// Current remote desktop size in points (nil until the first frame).
    var dimensions: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return width > 0 ? (width, height) : nil
    }

    deinit { free(pixels) }

    /// Called from the EndPaint callback (FreeRDP dispatch thread). Copies the
    /// full GDI primary buffer — BGRA32, top-down in FreeRDP 3.x — into our
    /// private storage. Full-frame copies keep this simple; dirty-rect
    /// tracking via `update->SetBounds` is a later optimization.
    func publishFrame(from instance: UnsafeMutablePointer<freerdp>) {
        guard let src = simplerdp_gdi_primary_buffer(instance) else { return }
        let w = Int(simplerdp_gdi_width(instance))
        let h = Int(simplerdp_gdi_height(instance))
        let stride = Int(simplerdp_gdi_stride(instance))
        guard w > 0, h > 0, stride >= w * 4 else { return }

        lock.lock()
        defer { lock.unlock() }

        let needed = w * h * 4
        if needed > capacity {
            free(pixels)
            pixels = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
            capacity = needed
        }
        width = w
        height = h

        if stride == w * 4 {
            memcpy(pixels, src, needed)
        } else {
            for row in 0..<h {
                memcpy(pixels! + row * w * 4, src + row * stride, w * 4)
            }
        }
        revision &+= 1
    }

    /// Main-thread snapshot. Returns the current revision and a CGImage when
    /// the frame changed since `lastSeen`, otherwise nil. The image owns a
    /// private copy of the pixels, so it stays valid across later updates.
    func latestImage(after lastSeen: UInt64) -> (revision: UInt64, image: CGImage)? {
        lock.lock()
        defer { lock.unlock() }

        guard revision != lastSeen, let pixels, width > 0, height > 0 else { return nil }

        let count = width * height * 4
        let copy = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        memcpy(copy, pixels, count)
        let data = Data(bytesNoCopy: copy, count: count, deallocator: .free)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        // GDI buffer is BGRA in memory == little-endian 0xAARRGGBB per 32-bit
        // word → .byteOrder32Little + .noneSkipFirst. Alpha is ignored; the
        // GDI surface does not guarantee meaningful alpha bytes.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { return nil }

        return (revision, image)
    }
}


// MARK: - Instance → Framebuffer registry

/// Maps a `freerdp*` instance to its `Framebuffer` so the @convention(c)
/// paint callbacks (which cannot capture Swift context) can find their target.
enum FramebufferRegistry {
    private static let lock = NSLock()
    private static var map: [Int: Framebuffer] = [:]

    static func register(_ fb: Framebuffer, for instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        map[Int(bitPattern: instance)] = fb
        lock.unlock()
    }

    static func unregister(for instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        map.removeValue(forKey: Int(bitPattern: instance))
        lock.unlock()
    }

    static func publishFrame(from instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        let fb = map[Int(bitPattern: instance)]
        lock.unlock()
        fb?.publishFrame(from: instance)
    }
}

// MARK: - FreeRDP update callbacks

/// Invoked when FreeRDP starts compositing a new frame. We copy the full
/// surface in EndPaint, so there is no invalid-region bookkeeping to reset.
private let beginPaintCallback: pBeginPaint = { _ in ObjCBool(true) }

/// Invoked after each composited frame batch, on FreeRDP's dispatch thread
/// (the event-loop thread during the session, the caller's thread during the
/// synchronous connect handshake). FramebufferRegistry/Framebuffer are
/// lock-protected, so both are safe.
private let endPaintCallback: pEndPaint = { context in
    guard let context, let instance = context.pointee.instance else { return ObjCBool(true) }
    FramebufferRegistry.publishFrame(from: instance)
    return ObjCBool(true)
}

/// Server asked to change the desktop size; realloc the GDI surface. The next
/// EndPaint publishes the new dimensions automatically.
private let desktopResizeCallback: pDesktopResize = { context in
    guard let context else { return ObjCBool(false) }
    return ObjCBool(simplerdp_desktop_resize(context))
}

/// Installs the frame-delivery callbacks on the update interface.
/// Must be called AFTER `gdi_init` (it registers its own update callbacks and
/// would overwrite anything installed earlier — this mirrors the sample
/// client's tf_post_connect).
func installFrameCallbacks(on instance: UnsafeMutablePointer<freerdp>) {
    guard let context = instance.pointee.context,
          let update = context.pointee.update else { return }
    update.pointee.BeginPaint = beginPaintCallback
    update.pointee.EndPaint = endPaintCallback
    update.pointee.DesktopResize = desktopResizeCallback
}
