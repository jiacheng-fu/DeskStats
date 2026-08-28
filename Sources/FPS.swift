import CoreGraphics
import Foundation

/// Counts display presentation events to estimate frame rate.
///
/// macOS gives no public way to read another process's frame rate — overlays like
/// RTSS or MangoHud do it by injecting into the graphics API, which is not possible
/// here without disabling SIP. What we can do is watch how often the display's
/// contents actually change: when a fullscreen game is presenting, that rate tracks
/// the game's output (bounded above by the display's refresh rate).
///
/// Costs almost nothing: the output surface is 2x2, so the compositor hands us a
/// notification rather than any real pixel work. Requires Screen Recording
/// permission; degrades to `available == false` without it.
final class FPSCounter {
    private var stream: CGDisplayStream?
    private var display: CGDirectDisplayID = CGMainDisplayID()
    private let queue = DispatchQueue(label: "com.brianfu.deskstats.fps", qos: .utility)
    private let lock = NSLock()

    private var frames = 0
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var lastFrameAt = CFAbsoluteTimeGetCurrent()

    private(set) var fps: Double = 0
    private(set) var available = false

    func start(on display: CGDirectDisplayID? = nil) {
        if let display { self.display = display }
        stop()

        stream = CGDisplayStream(
            dispatchQueueDisplay: self.display,
            outputWidth: 2, outputHeight: 2,
            pixelFormat: Int32(bitPattern: 0x42475241),   // 'BGRA'
            properties: [CGDisplayStream.showCursor: false] as CFDictionary,
            queue: queue
        ) { [weak self] status, _, _, _ in
            guard let self, status == .frameComplete else { return }
            self.lock.lock()
            self.frames += 1
            self.lastFrameAt = CFAbsoluteTimeGetCurrent()
            self.lock.unlock()
        }

        available = (stream?.start() == .success)
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    /// Move the counter to whichever display the widget currently sits on.
    func retarget(to display: CGDirectDisplayID) {
        guard display != self.display else { return }
        start(on: display)
    }

    /// Fold the counted frames into a rate. Call on the sampling tick.
    func tick() {
        guard available else { fps = 0; return }
        lock.lock()
        let counted = frames
        let idleFor = CFAbsoluteTimeGetCurrent() - lastFrameAt
        frames = 0
        lock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        windowStart = now
        guard elapsed > 0.05 else { return }

        // A static screen produces no frames at all; report 0 rather than a stale rate.
        let measured = idleFor > 1.0 ? 0 : Double(counted) / elapsed
        // Light smoothing so the number is readable instead of jittering every tick.
        fps = fps == 0 ? measured : fps * 0.4 + measured * 0.6
    }
}
