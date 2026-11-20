import Foundation
import IOKit

public struct LidSnapshot: Equatable {
    public var isClosed: Bool?
    public var causesSleep: Bool?

    public init(isClosed: Bool?, causesSleep: Bool?) {
        self.isClosed = isClosed
        self.causesSleep = causesSleep
    }

    public var isClosedLabel: String {
        switch isClosed {
        case .some(true): return L("Kapalı", "Closed")
        case .some(false): return L("Açık", "Open")
        case .none: return L("Bilinmiyor", "Unknown")
        }
    }
}

public enum LidStateReader {
    public static func read() -> LidSnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return LidSnapshot(isClosed: nil, causesSleep: nil) }
        defer { IOObjectRelease(service) }

        let closed = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool

        let causesSleep = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellCausesSleep" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool

        return LidSnapshot(isClosed: closed, causesSleep: causesSleep)
    }
}
