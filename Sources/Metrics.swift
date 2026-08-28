import Foundation
import IOKit

/// One point-in-time reading of everything the widget displays.
struct Sample {
    var cpu = 0.0              // 0...1
    var cores: [Double] = []   // per-core busy fraction, P-cores first
    var gpu = 0.0              // 0...1  (Device Utilization)
    var gpuRenderer = 0.0      // 0...1
    var gpuTiler = 0.0         // 0...1
    var fps = 0.0              // screen presentation rate
    var fpsAvailable = false
    var mem = 0.0              // 0...1
    var memUsedGB = 0.0
    var memTotalGB = 0.0

    var batteryPct = 0
    var charging = false
    var external = false
    var batteryWatts = 0.0     // signed: + into battery, - out of battery
    var adapterWatts = 0.0
    var systemWatts = 0.0
    var batteryTempC = 0.0
    var minutesRemaining = 0

    var adapters: [AdapterSource] = []      // one per connected power source
    var activeAdapter = 0                   // index of the one macOS selected
}

/// A single power source. Macs can see more than one at a time (multiple USB-C
/// ports); macOS picks one via BestAdapterIndex rather than summing them.
struct AdapterSource {
    var watts = 0.0
    var volts = 0.0
    var amps = 0.0
    var label = ""                          // e.g. "pd charger"
    var maxWatts = 0.0                      // best profile the source advertises
}

/// CPU busy fraction, derived from per-core tick deltas between calls.
final class CPUSampler {
    private var previous: [UInt32] = []

    func sample() -> (overall: Double, cores: [Double]) {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks = [UInt32](repeating: 0, count: Int(coreCount) * states)
        for i in 0..<(Int(coreCount) * states) {
            ticks[i] = UInt32(bitPattern: Int32(info[i]))
        }
        defer { previous = ticks }
        guard previous.count == ticks.count else { return (0, []) }

        var busy = 0.0, total = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let b = core * states
            // &- so a counter wrap yields a small delta rather than a huge one.
            let user = Double(ticks[b + Int(CPU_STATE_USER)]   &- previous[b + Int(CPU_STATE_USER)])
            let sys  = Double(ticks[b + Int(CPU_STATE_SYSTEM)] &- previous[b + Int(CPU_STATE_SYSTEM)])
            let nice = Double(ticks[b + Int(CPU_STATE_NICE)]   &- previous[b + Int(CPU_STATE_NICE)])
            let idle = Double(ticks[b + Int(CPU_STATE_IDLE)]   &- previous[b + Int(CPU_STATE_IDLE)])
            let coreBusy = user + sys + nice
            let coreTotal = coreBusy + idle
            perCore.append(coreTotal > 0 ? min(1, coreBusy / coreTotal) : 0)
            busy  += coreBusy
            total += coreTotal
        }
        return (total > 0 ? min(1, busy / total) : 0, perCore)
    }
}

enum Metrics {

    /// GPU load. Apple Silicon publishes only these three aggregate counters —
    /// there is no per-GPU-core utilization exposed to userspace.
    static func gpu() -> (device: Double, renderer: Double, tiler: Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0, 0) }
        defer { IOObjectRelease(iterator) }

        var device = 0.0, renderer = 0.0, tiler = 0.0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = raw?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }
            if let v = stats["Device Utilization %"] as? Int   { device   = max(device,   Double(v) / 100) }
            if let v = stats["Renderer Utilization %"] as? Int { renderer = max(renderer, Double(v) / 100) }
            if let v = stats["Tiler Utilization %"] as? Int    { tiler    = max(tiler,    Double(v) / 100) }
        }
        return (min(1, device), min(1, renderer), min(1, tiler))
    }

    /// Core split reported by the kernel: perflevel0 are the performance cores.
    static let performanceCoreCount: Int = {
        var n = 0, size = MemoryLayout<Int>.size
        return sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0 ? n : 0
    }()

    /// Memory footprint the way Activity Monitor counts it: active + wired + compressed.
    static func memory() -> (fraction: Double, usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return (0, 0, 0) }

        let page = Double(vm_kernel_page_size)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * page
        let gb = 1024.0 * 1024 * 1024
        return (total > 0 ? min(1, used / total) : 0, used / gb, total / gb)
    }

    /// Battery charge, power flow and adapter contract from AppleSmartBattery.
    static func power(into s: inout Sample) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = raw?.takeRetainedValue() as? [String: Any] else { return }

        s.batteryPct = d["CurrentCapacity"] as? Int ?? 0
        s.charging   = d["IsCharging"] as? Bool ?? false
        s.external   = d["ExternalConnected"] as? Bool ?? false
        s.batteryTempC = Double(d["Temperature"] as? Int ?? 0) / 100

        let millivolts = Double(d["Voltage"] as? Int ?? 0)
        // Amperage is signed; IOKit hands it back as a wrapped UInt64 on discharge.
        var milliamps = Double(d["Amperage"] as? Int ?? 0)
        if milliamps > 1e12 { milliamps -= 18446744073709551616.0 }
        s.batteryWatts = (milliamps / 1000) * (millivolts / 1000)

        // Enumerate every source, not just the active one.
        let rawList = (d["AppleRawAdapterDetails"] as? [[String: Any]])
            ?? (d["AdapterDetails"] as? [String: Any]).map { [$0] }
            ?? []
        s.activeAdapter = d["BestAdapterIndex"] as? Int ?? 0
        s.adapters = rawList.map { a in
            var src = AdapterSource()
            src.watts = Double(a["Watts"] as? Int ?? 0)
            src.volts = Double(a["AdapterVoltage"] as? Int ?? 0) / 1000
            src.amps  = Double(a["Current"] as? Int ?? 0) / 1000
            src.label = (a["Description"] as? String) ?? "adapter"
            // UsbHvcMenu lists the PD profiles the source advertises; the best of
            // them is the ceiling this charger can ever deliver.
            if let menu = a["UsbHvcMenu"] as? [[String: Any]] {
                src.maxWatts = menu.reduce(0.0) { best, p in
                    let v = Double(p["MaxVoltage"] as? Int ?? 0) / 1000
                    let c = Double(p["MaxCurrent"] as? Int ?? 0) / 1000
                    return max(best, v * c)
                }
            }
            return src
        }
        if s.adapters.indices.contains(s.activeAdapter) {
            s.adapterWatts = s.adapters[s.activeAdapter].watts
        } else {
            s.adapterWatts = s.adapters.first?.watts ?? 0
        }

        // Draw is what the adapter supplies minus whatever the battery absorbs;
        // on battery it is simply the discharge rate.
        s.systemWatts = s.external ? max(0, s.adapterWatts - s.batteryWatts) : abs(s.batteryWatts)

        if let minutes = d["AvgTimeToEmpty"] as? Int, !s.charging, minutes > 0, minutes < 1200 {
            s.minutesRemaining = minutes
        } else if let minutes = d["AvgTimeToFull"] as? Int, s.charging, minutes > 0, minutes < 1200 {
            s.minutesRemaining = minutes
        }
    }
}
