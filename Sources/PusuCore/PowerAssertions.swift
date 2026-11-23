import Foundation
import IOKit.pwr_mgt

public final class PowerAssertions: PowerAsserting {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0

    public var isSystemHeld: Bool { systemAssertion != 0 }
    public var isDisplayHeld: Bool { displayAssertion != 0 }
    public var isUserActivityHeld: Bool { userActivityAssertion != 0 }

    public init() {}

    deinit {
        releaseAll()
    }

    @discardableResult
    public func acquire(system: Bool, display: Bool, reason: String) -> Bool {
        var ok = true

        if system, systemAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                systemAssertion = id
            } else {
                ok = false
            }
        } else if !system {
            releaseSystem()
        }

        if display, displayAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                // Kendi adı: `pmset -g assertions` çıktısında sistem kaydından ayırt edilsin.
                "Pusu keeps the display on" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                displayAssertion = id
            } else {
                ok = false
            }
        } else if !display {
            releaseDisplay()
        }

        return ok
    }

    public func releaseSystem() {
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
    }

    public func releaseDisplay() {
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    public func releaseUserActivity() {
        if userActivityAssertion != 0 {
            IOPMAssertionRelease(userActivityAssertion)
            userActivityAssertion = 0
        }
    }

    @discardableResult
    public func declareUserActivity(reason: String) -> Bool {
        releaseUserActivity()
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString,
            kIOPMUserActiveLocal,
            &id
        )
        if result == kIOReturnSuccess {
            userActivityAssertion = id
            return true
        }
        return false
    }

    public func releaseAll() {
        releaseSystem()
        releaseDisplay()
        releaseUserActivity()
    }
}
