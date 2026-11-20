import Foundation
import Darwin

public final class SingleInstance {
    private var fileDescriptor: Int32 = -1

    public init() {}

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    @discardableResult
    public func acquire() -> Bool {
        let path = RuntimePaths.supportDirectory.appendingPathComponent("pusu.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        fileDescriptor = fd
        return true
    }
}
