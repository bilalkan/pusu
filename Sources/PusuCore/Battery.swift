import Foundation
import IOKit.ps

public struct BatteryStatus: Codable, Equatable {
    public var percent: Int
    public var isOnBattery: Bool
    public var isCharging: Bool
    public var isPresent: Bool
    public var minutesRemaining: Int?
    public var name: String

    public init(
        percent: Int,
        isOnBattery: Bool,
        isCharging: Bool,
        isPresent: Bool,
        minutesRemaining: Int? = nil,
        name: String = "Battery"
    ) {
        self.percent = percent
        self.isOnBattery = isOnBattery
        self.isCharging = isCharging
        self.isPresent = isPresent
        self.minutesRemaining = minutesRemaining
        self.name = name
    }

    public var powerLabel: String {
        let value = Localization.percent(percent)
        guard isPresent else { return L("Masaüstü", "Desktop") }
        if isCharging { return L("Şarjda · \(value)", "Charging · \(value)") }
        if isOnBattery { return L("Pilde · \(value)", "On battery · \(value)") }
        return L("Güç bağlı · \(value)", "Plugged in · \(value)")
    }

    public var remainingLabel: String? {
        guard let minutesRemaining, minutesRemaining > 0 else { return nil }
        let h = minutesRemaining / 60
        let m = minutesRemaining % 60
        return h > 0 ? L("\(h) sa \(m) dk", "\(h) h \(m) min") : L("\(m) dk", "\(m) min")
    }
}

public enum BatteryReader {
    public static func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            let type = description[kIOPSTypeKey] as? String
            let name = (description[kIOPSNameKey] as? String) ?? "Battery"
            guard type == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0
                ? min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
                : current

            let state = description[kIOPSPowerSourceStateKey] as? String
            let onBattery = state == kIOPSBatteryPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let present = description[kIOPSIsPresentKey] as? Bool ?? true

            let timeKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let rawMinutes = description[timeKey] as? Int
            let minutes = (rawMinutes ?? 0) > 0 ? rawMinutes : nil

            return BatteryStatus(
                percent: percent,
                isOnBattery: onBattery,
                isCharging: charging,
                isPresent: present,
                minutesRemaining: minutes,
                name: name
            )
        }

        return BatteryStatus(
            percent: 0,
            isOnBattery: false,
            isCharging: false,
            isPresent: false,
            name: "Desktop"
        )
    }
}

public enum BatteryPolicy {
    public static func shouldStop(
        battery: BatteryStatus?,
        cutoffEnabled: Bool,
        cutoffPercent: Int
    ) -> Bool {
        guard cutoffEnabled, let battery, battery.isPresent, battery.isOnBattery, !battery.isCharging else {
            return false
        }
        return battery.percent <= max(1, min(90, cutoffPercent))
    }

    public static func shouldDisableLid(
        battery: BatteryStatus?,
        floorEnabled: Bool,
        floorPercent: Int
    ) -> Bool {
        guard floorEnabled, let battery, battery.isPresent, battery.isOnBattery, !battery.isCharging else {
            return false
        }
        return battery.percent <= max(5, min(80, floorPercent))
    }
}
