import Foundation

enum Format {
    private static let gib = 1024.0 * 1024 * 1024

    /// Number with no decimals when >= 10, otherwise one decimal; a trailing ".0" is dropped.
    private static func compact(_ x: Double) -> String {
        if x >= 10 { return String(format: "%.0f", x) }
        let s = String(format: "%.1f", x)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// Byte count in the largest fitting binary unit (K, M, G, T).
    static func bytes(_ b: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(b)
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return compact(value) + units[i]
    }

    static func percent(_ r: Double) -> String {
        String(format: "%.0f%%", r * 100)
    }

    /// "used/totalG" in GiB, e.g. "42/56G".
    static func usage(_ used: Int64, _ total: Int64) -> String {
        "\(compact(Double(used) / gib))/\(compact(Double(total) / gib))G"
    }

    /// Free space in GiB, e.g. "232G free".
    static func free(_ used: Int64, _ total: Int64) -> String {
        "\(compact(Double(max(total - used, 0)) / gib))G free"
    }

    /// Uptime as "2d 22h", or "5h 12m" when under a day.
    static func uptime(_ seconds: Int64) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
    }

    /// Wall-clock time as "HH:mm".
    static func time(_ date: Date, _ tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "HH:mm" for today, "d MMM HH:mm" for any other day.
    static func stamp(_ date: Date, now: Date = .now, _ tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if cal.isDate(date, inSameDayAs: now) { return time(date, tz) }
        let c = cal.dateComponents([.day, .month], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(c.day ?? 1) \(months[((c.month ?? 1) - 1) % 12]) \(time(date, tz))"
    }
}
