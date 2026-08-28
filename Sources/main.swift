import AppKit
import SwiftUI

let agentLabel = "com.brianfu.deskstats"
let agentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

/// Where the widget sits in the window stack.
enum Placement: Int {
    case desktop = 0     // pinned to the wallpaper, under every app window
    case floating = 1    // above normal windows
    case gameOverlay = 2 // above fullscreen apps, and click-through

    var next: Placement { Placement(rawValue: (rawValue + 1) % 3) ?? .desktop }
    var title: String {
        switch self {
        case .desktop: return "On Desktop"
        case .floating: return "Float Above Windows"
        case .gameOverlay: return "Game Overlay (click-through)"
        }
    }
}

/// Hosts the SwiftUI content and owns the right-click menu.
final class ContainerView: NSView {
    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = app?.buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private var pendingPeek: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        switch event.clickCount {
        case 2:
            // Hold the peek briefly: a third click turns this into a quit instead.
            let work = DispatchWorkItem { [weak self] in self?.app?.togglePeek() }
            pendingPeek = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval,
                                          execute: work)
        case 3:
            pendingPeek?.cancel()
            pendingPeek = nil
            app?.quitCompletely()
        default:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging by hand invalidates the stashed position we would restore to.
        app?.clearPeek()
        super.mouseDragged(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = Model()
    private var hotkeyMonitor: Any?

    /// Frame to restore to when un-peeking. Persisted so quitting while tucked
    /// away does not strand the widget half off-screen on next launch.
    private var stashedFrame: NSRect? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "stashedFrame") else { return nil }
            return NSRectFromString(s)
        }
        set {
            let d = UserDefaults.standard
            newValue.map { d.set(NSStringFromRect($0), forKey: "stashedFrame") }
                ?? d.removeObject(forKey: "stashedFrame")
        }
    }

    /// Fraction of the card left on screen when peeked away.
    private static let peekVisible: CGFloat = 0.10

    /// Stored offset by one so an unset default (0) means "never chosen" rather
    /// than silently selecting the first case.
    var placement: Placement {
        get {
            let stored = UserDefaults.standard.integer(forKey: "placement")
            guard stored > 0 else { return .floating }
            return Placement(rawValue: stored - 1) ?? .floating
        }
        set {
            UserDefaults.standard.set(newValue.rawValue + 1, forKey: "placement")
            applyPlacement()
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // We hold no unsaved state, so the OS may kill us instantly at logout or
        // restart instead of waiting on a graceful quit. Keeps shutdown snappy.
        ProcessInfo.processInfo.enableSuddenTermination()

        let host = NSHostingView(rootView: WidgetView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        let container = ContainerView()
        container.addSubview(blur)
        container.addSubview(host)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 212),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true      // drag from anywhere on the card
        window.setFrameAutosaveName("DeskStatsWindow")

        if window.frame.origin == .zero, let screen = NSScreen.main {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.maxX - 232, y: v.maxY - 232))
        }
        // If we were left peeked, come back to the real position.
        if let restore = stashedFrame {
            window.setFrame(restore, display: false)
            stashedFrame = nil
        }
        applyPlacement()
        window.orderFront(nil)

        // Click-through mode would otherwise be a one-way door, so keep a way back.
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let wanted: NSEvent.ModifierFlags = [.control, .option, .command]
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == wanted,
               e.charactersIgnoringModifiers?.lowercased() == "d" {
                DispatchQueue.main.async { self?.placement = self?.placement.next ?? .floating }
            }
        }

        // Follow the display the widget lives on, so FPS tracks the screen you game on.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.retargetFPS()
        }
        retargetFPS()

        // Sleep/wake: idle completely while asleep, pick straight back up on wake.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.model.suspend()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.model.resume()
            self?.retargetFPS()
        }
        // Same for display sleep, which is the common case on a laptop.
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.model.suspend()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.model.resume()
        }

        // Monitors coming and going must not strand the widget off-screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.ensureOnScreen()
            self?.retargetFPS()
        }
    }

    /// If the display the widget lived on disappeared, bring it back into view.
    private func ensureOnScreen() {
        let frame = window.frame
        let visible = NSScreen.screens.contains { $0.frame.intersects(frame) }
        guard !visible, let screen = NSScreen.main else { return }
        clearPeek()
        let v = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: v.maxX - frame.width - 20, y: v.maxY - frame.height - 20))
    }

    private func retargetFPS() {
        guard let screen = window.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        model.fpsCounter.retarget(to: CGDirectDisplayID(id.uint32Value))
    }

    /// Double-click slides the card off the nearer vertical edge, X only, leaving
    /// a sliver to grab. Double-clicking the sliver brings it back.
    @objc func togglePeek() {
        if let restore = stashedFrame {
            stashedFrame = nil
            model.setThrottled(false)
            animate(to: restore)
            return
        }
        guard let screen = window.screen else { return }
        let f = window.frame
        let bounds = screen.frame
        let sliver = f.width * Self.peekVisible

        // Whichever edge it is already closer to is the one it hides behind.
        let gapLeft = f.minX - bounds.minX
        let gapRight = bounds.maxX - f.maxX
        let x = gapRight <= gapLeft ? bounds.maxX - sliver : bounds.minX + sliver - f.width

        stashedFrame = f
        model.setThrottled(true)        // barely visible, so barely sample
        animate(to: NSRect(x: x, y: f.minY, width: f.width, height: f.height))
    }

    func clearPeek() { stashedFrame = nil }

    /// Triple-click: leave nothing running. Exiting cleanly (status 0) means the
    /// LaunchAgent's KeepAlive rule declines to restart us, so the process stays
    /// gone until the next login or an explicit `stats`.
    @objc func quitCompletely() {
        model.suspend()
        NSApp.terminate(nil)
    }

    private func animate(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    func applyPlacement() {
        switch placement {
        case .desktop:
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
        case .gameOverlay:
            // Above the shield level, so it composites over fullscreen apps.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                         .fullScreenAuxiliary, .ignoresCycle]
            // Clicks must reach the game underneath.
            window.ignoresMouseEvents = true
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for p in [Placement.desktop, .floating, .gameOverlay] {
            let item = NSMenuItem(title: p.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.state = placement == p ? .on : .off
            item.tag = p.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fps = NSMenuItem(title: "FPS Counter", action: #selector(toggleFPS), keyEquivalent: "")
        fps.state = UserDefaults.standard.object(forKey: "fpsOff") == nil ? .on : .off
        fps.target = self
        menu.addItem(fps)
        menu.addItem(withTitle: "⌃⌥⌘D cycles placement", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Triple-click to quit · `stats` reopens",
                     action: nil, keyEquivalent: "")

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.state = FileManager.default.fileExists(atPath: agentPlist.path) ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DeskStats", action: #selector(NSApp.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc func pick(_ sender: NSMenuItem) {
        placement = Placement(rawValue: sender.tag) ?? .floating
    }

    @objc func toggleFPS() {
        let d = UserDefaults.standard
        if d.object(forKey: "fpsOff") == nil { d.set(true, forKey: "fpsOff") }
        else { d.removeObject(forKey: "fpsOff") }
        model.applyFPSPreference()
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlist.path) {
            try? fm.removeItem(at: agentPlist)
            shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        } else {
            let exe = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(agentLabel)</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><false/>
              <key>ProcessType</key><string>Background</string>
            </dict></plist>
            """
            try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? plist.write(to: agentPlist, atomically: true, encoding: .utf8)
            shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist.path])
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        model.suspend()                        // release the display stream promptly
    }

    private func shell(_ launch: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // no Dock icon, no menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
