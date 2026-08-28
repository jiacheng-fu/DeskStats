import SwiftUI

/// Drives the UI. One timer, one sample, published on the main actor.
final class Model: ObservableObject {
    @Published var s = Sample()
    @Published var mini = UserDefaults.standard.bool(forKey: "mini")
    @Published var history: [Double] = []      // recent system watts, for the sparkline

    private let cpu = CPUSampler()
    let fpsCounter = FPSCounter()
    private var timer: Timer?

    static let interval: TimeInterval = 1.0
    static let throttledInterval: TimeInterval = 5.0
    static let historyLength = 40

    private var throttled = false
    private var tick = 0
    private var cachedPower = Sample()      // power fields, refreshed slowly

    /// Battery and adapter change on the order of seconds, and reading them pulls
    /// AppleSmartBattery's entire property tree (kilobytes of nested state). No
    /// reason to pay that every second.
    static let powerEveryNTicks = 5
    private var fpsEnabled: Bool { UserDefaults.standard.object(forKey: "fpsOff") == nil }

    init() {
        _ = cpu.sample()                       // prime the tick baseline
        resume()
    }

    /// Stop all work. Called when the machine sleeps so we neither burn power nor
    /// hold anything that could keep the system awake.
    func suspend() {
        timer?.invalidate()
        timer = nil
        fpsCounter.stop()
    }

    func setMini(_ on: Bool) {
        mini = on
        UserDefaults.standard.set(on, forKey: "mini")
    }

    /// Sample far less often while the widget is peeked off-screen.
    func setThrottled(_ on: Bool) {
        guard on != throttled else { return }
        throttled = on
        if timer != nil { suspend(); resume() }
    }

    func applyFPSPreference() {
        fpsEnabled ? fpsCounter.start() : fpsCounter.stop()
    }

    func resume() {
        guard timer == nil else { return }
        if fpsEnabled { fpsCounter.start() }
        _ = cpu.sample()                       // discard ticks accumulated while asleep
        refresh()
        let t = Timer(timeInterval: throttled ? Self.throttledInterval : Self.interval,
                      repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Tolerance lets the OS coalesce our wakeups with others instead of
        // scheduling a dedicated timer interrupt.
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        var next = Sample()
        let c = cpu.sample()
        next.cpu = c.overall
        next.cores = c.cores
        let g = Metrics.gpu()
        next.gpu = g.device
        next.gpuRenderer = g.renderer
        next.gpuTiler = g.tiler
        let m = Metrics.memory()
        next.mem = m.fraction
        next.memUsedGB = m.usedGB
        next.memTotalGB = m.totalGB
        tick += 1
        if tick % Self.powerEveryNTicks == 1 {
            var fresh = Sample()
            Metrics.power(into: &fresh)
            cachedPower = fresh
        }
        next.batteryPct = cachedPower.batteryPct
        next.charging = cachedPower.charging
        next.external = cachedPower.external
        next.batteryWatts = cachedPower.batteryWatts
        next.adapterWatts = cachedPower.adapterWatts
        next.systemWatts = cachedPower.systemWatts
        next.batteryTempC = cachedPower.batteryTempC
        next.minutesRemaining = cachedPower.minutesRemaining
        next.adapters = cachedPower.adapters
        next.activeAdapter = cachedPower.activeAdapter

        if fpsEnabled {
            fpsCounter.tick()
            next.fps = fpsCounter.fps
            next.fpsAvailable = fpsCounter.available
        }
        s = next

        history.append(next.systemWatts)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// Load -> colour ramp. Cool blues idle, warm through to red under pressure.
private func heat(_ v: Double) -> Color {
    switch v {
    case ..<0.35: return Color(red: 0.30, green: 0.78, blue: 0.95)   // cyan
    case ..<0.60: return Color(red: 0.36, green: 0.85, blue: 0.55)   // green
    case ..<0.82: return Color(red: 0.98, green: 0.78, blue: 0.30)   // amber
    default:      return Color(red: 0.98, green: 0.42, blue: 0.42)   // red
    }
}

/// One slim bar per core. Height and colour both track how hard it is working.
struct CoreBars: View {
    let cores: [Double]
    let performanceCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                if i == performanceCount && performanceCount > 0 {
                    // Divider marks where performance cores end and efficiency begin.
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.white.opacity(0.14))
                        .frame(width: 1, height: 14).padding(.horizontal, 1.5)
                }
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.07))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(heat(v))
                        .frame(height: max(2, 14 * v))
                }
                .frame(width: 5.5, height: 14)
            }
        }
        // No animation: ten bars interpolating between samples is pure redraw cost.
    }
}

/// Square gauge for mini mode — same trick as a bar, folded into a small box so
/// three of them fit where one line chart used to.
struct SquareMeter: View {
    let value: Double
    let label: String
    var side: CGFloat = 36

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 5)
                    .fill(heat(value).opacity(0.55))
                    .frame(height: max(3, side * min(1, value)))
                Text("\(Int(value * 100))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxHeight: .infinity)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.5).foregroundStyle(.tertiary)
        }
    }
}

/// Rounded track with a tinted fill.
struct Bar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(1, value)))
            }
        }
        .frame(height: height)
    }
}

/// Smoothed, filled trace of recent power draw.
struct Spark: View {
    let points: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Track the window's own range rather than zero-to-peak: a steady draw
            // should read as a line near the bottom, not a filled block.
            let lo = max(0, (points.min() ?? 0) - 2)
            let hi = max(lo + 10, (points.max() ?? 10) + 3)
            let span = hi - lo
            let n = max(points.count, 2)
            let step = w / CGFloat(n - 1)
            let pt: (Int) -> CGPoint = { i in
                let v = i < points.count ? points[i] : lo
                return CGPoint(x: CGFloat(i) * step,
                               y: h - CGFloat((v - lo) / span) * h)
            }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    for i in 0..<n { p.addLine(to: pt(i)) }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    for i in 0..<n { i == 0 ? p.move(to: pt(i)) : p.addLine(to: pt(i)) }
                }
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct WidgetView: View {
    @ObservedObject var model: Model
    var s: Sample { model.s }

    private let power = Color(red: 0.40, green: 0.88, blue: 0.58)

    static let fullSize = CGSize(width: 212, height: 212)
    static let miniSize = CGSize(width: 136, height: 100)

    var body: some View {
        if model.mini { miniBody } else { fullBody }
    }

    /// Mini mode: the four numbers worth glancing at mid-game, nothing else.
    private var miniBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(s.fpsAvailable && s.fps > 0 ? "\(Int(s.fps.rounded()))" : "––")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(s.fps >= 90 ? power : (s.fps >= 45 ? .yellow : .secondary))
                Text(s.fpsAvailable ? "FPS" : "FPS · OFF")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.8).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                SquareMeter(value: s.cpu, label: "CPU")
                SquareMeter(value: s.gpu, label: "GPU")
                SquareMeter(value: s.mem, label: "MEM")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: Self.miniSize.width, height: Self.miniSize.height)
        .background(
            RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            heroes
            ZStack(alignment: .topLeading) {
                Spark(points: model.history, tint: s.external ? power : .orange)
                    .frame(height: 28)
                HStack(spacing: 0) {
                    Text("POWER DRAW · \(Int(Model.historyLength * Int(Model.interval)))s")
                        .font(.system(size: 6.5, weight: .bold, design: .rounded))
                        .tracking(0.5).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(String(format: "peak %.0f W", model.history.max() ?? 0))
                        .font(.system(size: 6.5, weight: .bold, design: .rounded))
                        .tracking(0.3).foregroundStyle(.tertiary)
                }
            }
            meters
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.fullSize.width, height: Self.fullSize.height)
        .background(
            // Hairline edge gives the card definition against any wallpaper.
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(.white.opacity(0.35), lineWidth: 1).frame(width: 19, height: 10)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(s.charging ? power : (s.batteryPct <= 20 ? .red : .white.opacity(0.8)))
                    .frame(width: max(2, 17 * CGFloat(s.batteryPct) / 100), height: 7.5)
                    .padding(.leading, 1)
            }


            Text("\(s.batteryPct)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
            if s.charging {
                Image(systemName: "bolt.fill").font(.system(size: 7)).foregroundStyle(power)
            }
            Spacer(minLength: 0)
            if !clock.isEmpty {
                Text(s.charging ? "FULL IN" : "LEFT")
                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
                    .tracking(0.5).foregroundStyle(.tertiary)
                Text(clock).font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text("BATT")
                .font(.system(size: 6.5, weight: .bold, design: .rounded))
                .tracking(0.5).foregroundStyle(.tertiary)
                .padding(.leading, 1)
            Text(String(format: "%.0f°C", s.batteryTempC))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// The two numbers worth reading from across the room.
    private var heroes: some View {
        HStack(alignment: .top, spacing: 0) {
            hero(value: s.fpsAvailable && s.fps > 0 ? "\(Int(s.fps.rounded()))" : "––",
                 caption: s.fpsAvailable ? "FPS" : "FPS · OFF",
                 tint: s.fps >= 90 ? power : (s.fps >= 45 ? .yellow : .secondary))
            Spacer(minLength: 0)
            Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: 30)
            Spacer(minLength: 0)
            hero(value: String(format: "%.0f", s.systemWatts), caption: "WATTS USED", tint: .white)
        }
    }

    private func hero(value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
            Text(caption)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.9).foregroundStyle(.tertiary)
        }
        .frame(width: 84, alignment: .leading)
    }

    private var meters: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                label("CPU")
                CoreBars(cores: s.cores, performanceCount: Metrics.performanceCoreCount)
                Spacer(minLength: 0)
                value("\(Int(s.cpu * 100))%", heat(s.cpu))
            }
            HStack(spacing: 7) {
                label("GPU")
                VStack(spacing: 2) {
                    Bar(value: s.gpu, tint: heat(s.gpu), height: 5)
                    HStack(spacing: 3) {
                        Bar(value: s.gpuRenderer, tint: Color(red: 0.72, green: 0.55, blue: 0.98),
                            height: 2)
                        Bar(value: s.gpuTiler, tint: Color(red: 0.40, green: 0.80, blue: 0.85),
                            height: 2)
                    }
                }
                value("\(Int(s.gpu * 100))%", heat(s.gpu))
            }
            HStack(spacing: 7) {
                label("MEM")
                Bar(value: s.mem, tint: s.mem < 0.80
                    ? Color(red: 0.45, green: 0.68, blue: 0.98) : .orange)
                value(String(format: "%.0f/%.0f", s.memUsedGB, s.memTotalGB), .white)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(chargeLabel.uppercased())
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.7).foregroundStyle(.tertiary)
            Text(chargeValue)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(chargeColor)
            Spacer(minLength: 0)
            Text(sourceLabel)
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.5).foregroundStyle(.secondary)
            .frame(width: 24, alignment: .leading)
    }

    private func value(_ t: String, _ tint: Color) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit().foregroundStyle(tint)
            .frame(width: 40, alignment: .trailing)
    }

    // MARK: power wording

    private var chargeLabel: String {
        if s.charging && s.batteryWatts > 0.1 { return "Charging" }
        if s.batteryWatts < -0.1 { return s.external ? "Draining" : "On battery" }
        return "Battery"
    }

    private var chargeValue: String {
        abs(s.batteryWatts) < 0.1 ? "held" : String(format: "%+.0f W", s.batteryWatts)
    }

    private var chargeColor: Color {
        if s.batteryWatts > 0.1 { return power }
        if s.batteryWatts < -0.1 { return s.external ? .orange : .secondary }
        return .secondary
    }

    private var activeAdapter: AdapterSource? {
        s.adapters.indices.contains(s.activeAdapter) ? s.adapters[s.activeAdapter] : s.adapters.first
    }

    /// Reads "45 W in", and flags when the source could actually give more.
    private var sourceLabel: String {
        guard s.external, let a = activeAdapter else { return "unplugged" }
        var text = String(format: "%.0f W in", a.watts)
        if a.maxWatts > a.watts + 4 { text += String(format: " of %.0f", a.maxWatts) }
        if s.adapters.count > 1 { text += " · \(s.adapters.count) ports" }
        return text
    }

    private var clock: String {
        guard s.minutesRemaining > 0 else { return "" }
        return String(format: "%d:%02d", s.minutesRemaining / 60, s.minutesRemaining % 60)
    }
}
