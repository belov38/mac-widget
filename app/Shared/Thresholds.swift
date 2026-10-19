import Foundation

enum Level: Sendable, Equatable {
    case ok, warn, crit
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
}

extension Temp {
    var level: Level { Threshold(warn: warn, crit: crit).level(value) }
}
