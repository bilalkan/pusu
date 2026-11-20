import Foundation

public struct PusuDuration: Codable, Hashable, Identifiable {
    /// nil means indefinite.
    public let seconds: TimeInterval?

    public var id: String {
        if let seconds { return "s-\(Int(seconds))" }
        return "indefinite"
    }

    public var isIndefinite: Bool { seconds == nil }

    public init(seconds: TimeInterval?) {
        if let seconds, seconds > 0 {
            self.seconds = seconds
        } else {
            self.seconds = nil
        }
    }

    public init(minutes: Int) {
        self.init(seconds: TimeInterval(minutes) * 60)
    }

    public static let indefinite = PusuDuration(seconds: nil)
    public static let fifteenMinutes = PusuDuration(minutes: 15)
    public static let thirtyMinutes = PusuDuration(minutes: 30)
    public static let oneHour = PusuDuration(minutes: 60)
    public static let twoHours = PusuDuration(minutes: 120)
    public static let fourHours = PusuDuration(minutes: 240)
    public static let eightHours = PusuDuration(minutes: 480)

    public static let presets: [PusuDuration] = [
        .indefinite,
        .fifteenMinutes,
        .thirtyMinutes,
        .oneHour,
        .twoHours,
        .fourHours,
        .eightHours,
    ]

    public var label: String {
        guard let seconds else { return L("Süresiz", "Indefinitely") }
        return PusuDuration.humanLabel(seconds: seconds)
    }

    public var shortLabel: String {
        guard let seconds else { return "∞" }
        return PusuDuration.compactLabel(seconds: seconds)
    }

    public func endDate(from now: Date = Date()) -> Date? {
        guard let seconds else { return nil }
        return now.addingTimeInterval(seconds)
    }

    public func remaining(until endDate: Date?, now: Date = Date()) -> TimeInterval? {
        guard let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(now))
    }

    public static func humanLabel(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total <= 0 { return L("Süresiz", "Indefinitely") }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 && minutes > 0 { return L("\(hours) sa \(minutes) dk", "\(hours) h \(minutes) min") }
        if hours > 0 { return L("\(hours) saat", hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { return L("\(minutes) dakika", minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return L("\(total) saniye", total == 1 ? "1 second" : "\(total) seconds")
    }

    public static func compactLabel(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (d, h, m, sec) = Localization.isTurkish ? ("g", "s", "d", "sn") : ("d", "h", "m", "s")
        if total >= 86400 {
            let days = total / 86400
            let hours = (total % 86400) / 3600
            return hours > 0 ? "\(days)\(d) \(hours)\(h)" : "\(days)\(d)"
        }
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes > 0 ? "\(hours)\(h) \(minutes)\(m)" : "\(hours)\(h)"
        }
        if total >= 60 {
            let minutes = total / 60
            return "\(minutes)\(m)"
        }
        return "\(total)\(sec)"
    }
}

public enum TimeText {
    /// Monospaced menu-bar countdown: 1:23:45, 23:45 or 2g 03:12.
    public static func countdown(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%d%@ %02d:%02d", days, L("g", "d"), hours, minutes)
        }
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Localization.isTurkish {
            formatter.locale = Locale(identifier: "tr_TR")
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}
