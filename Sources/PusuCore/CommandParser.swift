import Foundation

/// Komut satırı, URL şeması ve dağıtık bildirim yollarının ortak komut kümesi.
public enum PusuCommand: Equatable {
    case toggle
    case on(minutes: Int?)
    case off
    case blackout
    case lock
    case vnc
    case wake
    case settings
    case diagnostics
    /// Kapak modu: `true` aç, `false` kapat, `nil` aç/kapat.
    case lid(on: Bool?)

    /// Dağıtık bildirim ve URL ana bilgisayar adı.
    public var wireName: String {
        switch self {
        case .toggle: return "toggle"
        case .on: return "on"
        case .off: return "off"
        case .blackout: return "blackout"
        case .lock: return "lock"
        case .vnc: return "vnc"
        case .wake: return "wake"
        case .settings: return "settings"
        case .diagnostics: return "diagnostics"
        case .lid(let on):
            switch on {
            case .some(true): return "lid-on"
            case .some(false): return "lid-off"
            case .none: return "lid"
            }
        }
    }

    public var minutes: Int? {
        if case .on(let minutes) = self { return minutes }
        return nil
    }

    public init?(wireName: String, minutes: Int?) {
        switch wireName {
        case "toggle": self = .toggle
        case "on": self = .on(minutes: minutes.flatMap { (1...CommandParser.maxMinutes).contains($0) ? $0 : nil })
        case "off": self = .off
        case "blackout": self = .blackout
        case "lock": self = .lock
        case "vnc": self = .vnc
        case "wake": self = .wake
        case "settings": self = .settings
        case "diagnostics": self = .diagnostics
        case "lid": self = .lid(on: nil)
        case "lid-on": self = .lid(on: true)
        case "lid-off": self = .lid(on: false)
        default: return nil
        }
    }
}

public enum CommandParser {
    /// `pusu on 90`, `pusu off`, eski `--on 90` bayrakları vb. `arguments[0]` program adıdır.
    public static func parse(_ arguments: [String]) -> PusuCommand? {
        let args = Array(arguments.dropFirst())
        if let subcommand = args.first, !subcommand.hasPrefix("-") {
            switch subcommand {
            case "toggle": return .toggle
            case "on": return .on(minutes: args.dropFirst().first.flatMap(parseDuration))
            case "off": return .off
            case "blackout": return .blackout
            case "lock": return .lock
            case "vnc": return .vnc
            case "wake": return .wake
            case "settings": return .settings
            case "lid":
                switch args.dropFirst().first?.lowercased() {
                case nil: return .lid(on: nil)
                case "on", "aç", "ac": return .lid(on: true)
                case "off", "kapat": return .lid(on: false)
                default: return nil
                }
            default: break
            }
        }

        if args.contains("--toggle") { return .toggle }
        if args.contains("--off") { return .off }
        if args.contains("--blackout") { return .blackout }
        if args.contains("--lock") { return .lock }
        if args.contains("--vnc") { return .vnc }
        if args.contains("--wake") { return .wake }
        if args.contains("--settings") { return .settings }

        if let index = args.firstIndex(of: "--on") {
            let value = args.indices.contains(index + 1) ? parseDuration(args[index + 1]) : nil
            return .on(minutes: value)
        }
        if let argument = args.first(where: { $0.hasPrefix("--on=") }) {
            return .on(minutes: parseDuration(String(argument.dropFirst("--on=".count))))
        }
        return nil
    }

    /// URL ile başlatılan oturumların üst sınırı (dakika). Web sayfaları da `pusu://`
    /// açabildiği için uzun oturumlar menüden veya komut satırından başlatılmalıdır.
    public static let maxURLMinutes = 8 * 60

    /// URL şemasının izin verdiği komutlar. Ekranı kilitleyen/karartan, kapak modunu açan
    /// veya panoya yazan komutlar bilerek dışarıda bırakılır.
    public static let urlAllowedCommands: Set<String> = ["on", "off", "toggle", "wake", "settings"]

    /// `pusu://on?minutes=60` gibi URL'leri çözer.
    public static func parse(url: URL) -> PusuCommand? {
        guard url.scheme?.lowercased() == "pusu",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let host = (components.host ?? "").lowercased()
        guard urlAllowedCommands.contains(host) else { return nil }
        var minutes = components.queryItems?
            .first(where: { $0.name == "minutes" })?
            .value
            .flatMap(parseDuration)
        if let value = minutes, value > maxURLMinutes { minutes = maxURLMinutes }
        return PusuCommand(wireName: host, minutes: minutes)
    }

    /// Aynı oturumdaki başka süreçlerin dağıtık bildirimle gönderebileceği komutlar
    /// (`pusu` komut satırı aracı bu yolu kullanır). Tanılama panoya yazdığı için yoktur.
    public static func isAllowedFromDistributedNotification(_ command: PusuCommand) -> Bool {
        if case .diagnostics = command { return false }
        return true
    }

    /// Bir yıldan uzun süreler reddedilir (taşma ve yazım hatalarına karşı).
    public static let maxMinutes = 60 * 24 * 365

    /// 60 → 60 dk, 90m → 90 dk, 2h → 120 dk, 1h30m → 90 dk. Türkçe kısaltmalar da geçerli:
    /// `2s` (saat), `45d` (dakika), `1s30d`.
    public static func parseDuration(_ raw: String) -> Int? {
        let limit = maxMinutes
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let minutes = Int(value), minutes > 0, minutes <= limit else { return nil }
            return minutes
        }

        var total = 0
        var number = ""
        var matched = false
        for character in value {
            if character.isASCII, character.isNumber {
                number.append(character)
                guard number.count <= 7 else { return nil }
            } else if character == "h" || character == "s" || character == "m" || character == "d" {
                guard let amount = Int(number) else { return nil }
                let isHours = character == "h" || character == "s"
                total += isHours ? amount * 60 : amount
                guard total <= limit else { return nil }
                number = ""
                matched = true
            } else {
                return nil
            }
        }
        guard matched, number.isEmpty, total > 0 else { return nil }
        return total
    }
}
