import Combine
import Foundation

public struct ActiveSessionRecord: Codable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var requestedDuration: TimeInterval?
    public var lastSeenAt: Date
    public var usedLid: Bool
    public var usedRemote: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        requestedDuration: TimeInterval?,
        lastSeenAt: Date,
        usedLid: Bool = false,
        usedRemote: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.requestedDuration = requestedDuration
        self.lastSeenAt = lastSeenAt
        self.usedLid = usedLid
        self.usedRemote = usedRemote
    }
}

public struct SessionRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date
    public var endReason: SessionStopReason
    public var endIsEstimated: Bool
    public var requestedDuration: TimeInterval?
    public var usedLid: Bool
    public var usedRemote: Bool
    public var batteryPercentAtEnd: Int?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        endReason: SessionStopReason,
        endIsEstimated: Bool = false,
        requestedDuration: TimeInterval? = nil,
        usedLid: Bool = false,
        usedRemote: Bool = false,
        batteryPercentAtEnd: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.endIsEstimated = endIsEstimated
        self.requestedDuration = requestedDuration
        self.usedLid = usedLid
        self.usedRemote = usedRemote
        self.batteryPercentAtEnd = batteryPercentAtEnd
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case endedAt
        case endReason
        case endIsEstimated
        case requestedDuration
        case usedLid
        case usedRemote
        case batteryPercentAtEnd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        let reason = try container.decodeIfPresent(String.self, forKey: .endReason) ?? ""
        endReason = SessionStopReason(rawValue: reason) ?? .error
        endIsEstimated = try container.decodeIfPresent(Bool.self, forKey: .endIsEstimated) ?? false
        requestedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .requestedDuration)
        usedLid = try container.decodeIfPresent(Bool.self, forKey: .usedLid) ?? false
        usedRemote = try container.decodeIfPresent(Bool.self, forKey: .usedRemote) ?? false
        batteryPercentAtEnd = try container.decodeIfPresent(Int.self, forKey: .batteryPercentAtEnd)
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    public var reasonLabel: String {
        endReason.label
    }
}

private struct SessionHistoryFile: Codable {
    var schemaVersion: Int
    var records: [SessionRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    init(schemaVersion: Int, records: [SessionRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let decoded = try container.decodeIfPresent([LossyRecord].self, forKey: .records) ?? []
        records = decoded.compactMap(\.value)
    }
}

private struct LossyRecord: Decodable {
    let value: SessionRecord?

    init(from decoder: Decoder) {
        value = try? SessionRecord(from: decoder)
    }
}

public final class SessionHistoryStore: ObservableObject {
    @Published public private(set) var records: [SessionRecord] = []
    @Published public private(set) var active: ActiveSessionRecord?

    private let historyURL: URL
    private let activeURL: URL
    private let maxRecords: Int
    private let schemaVersion = 1

    public init(
        historyURL: URL = RuntimePaths.history,
        activeURL: URL = RuntimePaths.activeSession,
        maxRecords: Int = 500
    ) {
        self.historyURL = historyURL
        self.activeURL = activeURL
        self.maxRecords = max(1, maxRecords)
        load()
        recoverInterruptedSession()
    }

    @discardableResult
    public func begin(
        duration: PusuDuration,
        at date: Date = Date()
    ) -> ActiveSessionRecord {
        if let active { return active }

        let session = ActiveSessionRecord(
            startedAt: date,
            requestedDuration: duration.seconds,
            lastSeenAt: date
        )
        active = session
        saveActive()
        return session
    }

    public func updateRequestedDuration(_ duration: PusuDuration, at date: Date = Date()) {
        guard var active else { return }
        active.requestedDuration = duration.seconds
        active.lastSeenAt = max(active.lastSeenAt, date)
        self.active = active
        saveActive()
    }

    public func markLidUsed(at date: Date = Date()) {
        guard var active, !active.usedLid else { return }
        active.usedLid = true
        active.lastSeenAt = max(active.lastSeenAt, date)
        self.active = active
        saveActive()
    }

    public func markRemoteUsed(at date: Date = Date()) {
        guard var active, !active.usedRemote else { return }
        active.usedRemote = true
        active.lastSeenAt = max(active.lastSeenAt, date)
        self.active = active
        saveActive()
    }

    public func heartbeat(at date: Date = Date()) {
        guard var active else { return }
        active.lastSeenAt = max(active.lastSeenAt, date)
        self.active = active
        saveActive()
    }

    public func end(
        reason: SessionStopReason,
        battery: BatteryStatus?,
        at date: Date = Date()
    ) {
        guard let active else { return }

        let endedAt = max(date, active.startedAt)
        let record = SessionRecord(
            id: active.id,
            startedAt: active.startedAt,
            endedAt: endedAt,
            endReason: reason,
            requestedDuration: active.requestedDuration,
            usedLid: active.usedLid,
            usedRemote: active.usedRemote,
            batteryPercentAtEnd: battery?.percent
        )

        var updated = records
        updated.insert(record, at: 0)
        updated.sort { $0.startedAt > $1.startedAt }
        if updated.count > maxRecords {
            updated.removeLast(updated.count - maxRecords)
        }

        guard saveHistory(updated) else { return }
        records = updated
        self.active = nil
        try? FileManager.default.removeItem(at: activeURL)
    }

    public func clear() {
        guard saveHistory([]) else { return }
        records.removeAll()
    }

    public func records(
        on day: Date,
        calendar: Calendar = .current
    ) -> [SessionRecord] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }

        return records
            .filter { record in
                record.startedAt < end && record.endedAt > start
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: historyURL) {
            if let file = try? decoder.decode(SessionHistoryFile.self, from: data) {
                records = file.records
                    .sorted { $0.startedAt > $1.startedAt }
                    .prefix(maxRecords)
                    .map { $0 }
            } else {
                backupCorruptHistory()
            }
        }

        guard let activeData = try? Data(contentsOf: activeURL),
              let activeSession = try? decoder.decode(ActiveSessionRecord.self, from: activeData)
        else { return }
        active = activeSession
    }

    private func recoverInterruptedSession() {
        guard let active else { return }

        if records.contains(where: { $0.id == active.id }) {
            self.active = nil
            try? FileManager.default.removeItem(at: activeURL)
            return
        }

        let record = SessionRecord(
            id: active.id,
            startedAt: active.startedAt,
            endedAt: max(active.lastSeenAt, active.startedAt),
            endReason: .interrupted,
            endIsEstimated: true,
            requestedDuration: active.requestedDuration,
            usedLid: active.usedLid,
            usedRemote: active.usedRemote
        )
        var updated = records
        updated.insert(record, at: 0)
        if updated.count > maxRecords {
            updated.removeLast(updated.count - maxRecords)
        }

        guard saveHistory(updated) else { return }
        records = updated
        self.active = nil
        try? FileManager.default.removeItem(at: activeURL)
    }

    private func saveActive() {
        guard let active else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(active) else { return }
        try? data.write(to: activeURL, options: .atomic)
    }

    private func saveHistory(_ records: [SessionRecord]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = SessionHistoryFile(schemaVersion: schemaVersion, records: records)
        guard let data = try? encoder.encode(file) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: historyURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func backupCorruptHistory() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backup = historyURL
            .deletingLastPathComponent()
            .appendingPathComponent("history.corrupt-\(timestamp).json")
        try? FileManager.default.moveItem(at: historyURL, to: backup)
    }
}
