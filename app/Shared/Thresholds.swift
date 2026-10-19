import Foundation

enum Level: Int, Sendable, Equatable, Comparable {
    case ok, warn, crit

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Threshold: Sendable {
    let warn: Double
    let crit: Double

    func level(_ v: Double) -> Level {
        if v >= crit { return .crit }
        if v >= warn { return .warn }
        return .ok
    }
}

extension Threshold {
    static let cpu = Threshold(warn: 0.70, crit: 0.90)
    static let mem = Threshold(warn: 0.90, crit: 0.95)
    static let disk = Threshold(warn: 0.80, crit: 0.90)

    /// PSI "some": share of time at least one task waited for CPU or IO.
    static let cpuPressure = Threshold(warn: 0.10, crit: 0.25)
    static let ioPressure = Threshold(warn: 0.10, crit: 0.25)
    /// PSI "full": share of time all tasks stalled on memory.
    static let memPressure = Threshold(warn: 0.01, crit: 0.05)
    /// Memory pressure rises late, close to OOM, so near-full memory stays red on its own.
    static let memNearFull = Threshold(warn: 0.95, crit: 0.95)
}

/// Turns a usage value and its pressure into a level.
///
/// With pressure, the level comes from pressure, raised by `usageWithPressure` when set.
/// Without pressure (old data, missing PSI), it falls back to `usage`.
struct LevelRule: Sendable {
    let usage: Threshold
    var pressure: Threshold? = nil
    var usageWithPressure: Threshold? = nil

    func level(_ value: Double, pressure p: Double?) -> Level {
        guard let pressure, let p else { return usage.level(value) }
        let byPressure = pressure.level(p)
        guard let usageWithPressure else { return byPressure }
        return Swift.max(byPressure, usageWithPressure.level(value))
    }
}

extension LevelRule {
    init(_ usage: Threshold) { self.usage = usage }

    /// Busy cores are fine as long as nothing waits for them.
    static let hostCPU = LevelRule(usage: .cpu, pressure: .cpuPressure)
    static let hostMem = LevelRule(usage: .mem, pressure: .memPressure, usageWithPressure: .memNearFull)
}

extension Guest {
    var isVM: Bool { type == "qemu" }

    /// A VM's PSI is the host side of its QEMU process: it shows vCPUs waiting for host cores,
    /// not load inside the guest, so VM usage still counts.
    var cpuRule: LevelRule {
        isVM ? LevelRule(usage: .cpu, pressure: .cpuPressure, usageWithPressure: .cpu) : .hostCPU
    }

    var cpuLevel: Level { cpuRule.level(cpu.now, pressure: cpu.pressure?.now) }

    /// Host-side memory PSI says nothing about memory inside a VM, so only containers use it.
    var memLevel: Level {
        isVM ? Threshold.mem.level(mem.ratio) : LevelRule.hostMem.level(mem.ratio, pressure: memPressure)
    }
}

extension Temp {
    var level: Level { Threshold(warn: warn, crit: crit).level(value) }
}
