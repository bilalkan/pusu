import SwiftUI
import PusuCore

struct SessionHistoryView: View {
    @ObservedObject var history: SessionHistoryStore
    @ObservedObject var ui: SettingsUIModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    timelineCard(now: context.date)
                }
                recentCard
            }
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
        .alert(L("Geçmiş temizlensin mi?", "Clear history?"), isPresented: $ui.showHistoryClearConfirmation) {
            Button(L("Temizle", "Clear"), role: .destructive) {
                history.clear()
            }
            Button(L("Vazgeç", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("Tamamlanan oturum kayıtları silinir. Aktif oturum etkilenmez.", "Completed session records are deleted. The current session isn't affected."))
        }
    }

    private func timelineCard(now: Date) -> some View {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let completed = history.records(on: now, calendar: calendar)
        let startedToday = completed.filter { $0.startedAt >= dayStart }.count + (history.active == nil ? 0 : 1)
        let segments = makeSegments(
            completed: completed,
            active: history.active,
            dayStart: dayStart,
            dayEnd: dayEnd,
            now: now
        )
        let total = segments.reduce(0) { $0 + $1.duration }
        let hasEstimated = segments.contains { $0.isEstimated }

        return SettingsCard(
            title: L("Bugün", "Today"),
            subtitle: L("Pusu'nun açık olduğu aralıklar", "When Pusu was on")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HistoryTimelineBar(
                    segments: segments,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    accessibilitySummary: L("Bugün Pusu \(durationLabel(total)) açık, \(startedToday) oturum", "Pusu was on for \(durationLabel(total)) today, \(startedToday) sessions")
                )

                HStack {
                    Text("00:00")
                    Spacer()
                    Text("06:00")
                    Spacer()
                    Text("12:00")
                    Spacer()
                    Text("18:00")
                    Spacer()
                    Text("24:00")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)

                HStack(spacing: 14) {
                    Label(L("Toplam açık: \(durationLabel(total))", "Total on: \(durationLabel(total))"), systemImage: "sun.max")
                    if startedToday > 0 {
                        Label(L("\(startedToday) oturum", startedToday == 1 ? "1 session" : "\(startedToday) sessions"), systemImage: "clock")
                    }
                    if history.active != nil {
                        Label(L("Şu an açık", "On now"), systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if hasEstimated {
                    Label(L("Kesildi · bitiş son kayda göre tahmini", "Interrupted · end time estimated from the last record"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 12) {
                    legendDot(color: .accentColor, text: L("Pusu açık", "Pusu on"))
                    legendDot(color: .secondary.opacity(0.18), text: L("Kapalı / kayıt yok", "Off / no record"))
                    if hasEstimated {
                        legendDot(color: .orange, text: L("Kesinti", "Interrupted"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var recentCard: some View {
        let recent = Array(history.records.prefix(20))

        return SettingsCard(
            title: L("Son oturumlar", "Recent sessions"),
            subtitle: recent.isEmpty && history.active == nil ? L("Henüz kayıt yok.", "No records yet.") : L("Son 20 kayıt", "Last 20 records")
        ) {
            if let active = history.active {
                activeRow(active)
                if !recent.isEmpty {
                    Divider()
                }
            }

            if recent.isEmpty && history.active == nil {
                Text(L("Pusu bir oturum başlattığında burada görünecek.", "Sessions will show up here once Pusu runs."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { record in
                    historyRow(record)
                    if record.id != recent.last?.id {
                        Divider()
                    }
                }
            }

            if !recent.isEmpty {
                HStack {
                    Spacer()
                    Button(L("Geçmişi temizle", "Clear History"), role: .destructive) {
                        ui.showHistoryClearConfirmation = true
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 4)
            }
        }
    }

    private func activeRow(_ active: ActiveSessionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("Devam ediyor", "In progress"))
                        .font(.callout.weight(.medium))
                    Text(L("ŞU AN", "NOW"))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
                HStack(spacing: 6) {
                    Text(L("Başlangıç: \(startLabel(active.startedAt))", "Started: \(startLabel(active.startedAt))"))
                    if active.usedLid {
                        Label(L("Kapak", "Lid"), systemImage: "laptopcomputer")
                    }
                    if active.usedRemote {
                        Label("VNC", systemImage: "display")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(durationLabel(Date().timeIntervalSince(active.startedAt)))
                .font(.callout)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }

    private func historyRow(_ record: SessionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(startLabel(record.startedAt))
                        .font(.callout)
                    if record.endIsEstimated {
                        Text("≈")
                            .foregroundStyle(.orange)
                            .accessibilityLabel(L("tahmini bitiş", "estimated end"))
                    }
                }
                HStack(spacing: 6) {
                    Text(record.reasonLabel)
                    if record.usedLid {
                        Label(L("Kapak", "Lid"), systemImage: "laptopcomputer")
                    }
                    if record.usedRemote {
                        Label("VNC", systemImage: "display")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(durationLabel(record.duration))
                .font(.callout)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }

    private func makeSegments(
        completed: [SessionRecord],
        active: ActiveSessionRecord?,
        dayStart: Date,
        dayEnd: Date,
        now: Date
    ) -> [HistorySegment] {
        let clampedNow = min(now, dayEnd)
        var result: [HistorySegment] = completed.compactMap { record in
            let start = max(record.startedAt, dayStart)
            let end = min(min(record.endedAt, dayEnd), clampedNow)
            guard end > start else { return nil }
            return HistorySegment(
                start: start,
                end: end,
                isActive: false,
                isEstimated: record.endIsEstimated
            )
        }

        if let active {
            let start = max(active.startedAt, dayStart)
            let end = min(clampedNow, dayEnd)
            if end > start {
                result.append(
                    HistorySegment(
                        start: start,
                        end: end,
                        isActive: true,
                        isEstimated: false
                    )
                )
            }
        }

        return result.sorted { $0.start < $1.start }
    }

    private func startLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Localization.locale))
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            return rounded <= 0 ? L("0 dk", "0 min") : L("1 dk'dan az", "under 1 min")
        }
        return PusuDuration.humanLabel(seconds: seconds)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
        }
    }
}

private struct HistorySegment: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let isActive: Bool
    let isEstimated: Bool

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}

private struct HistoryTimelineBar: View {
    let segments: [HistorySegment]
    let dayStart: Date
    let dayEnd: Date
    let accessibilitySummary: String

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dayDuration = max(1, dayEnd.timeIntervalSince(dayStart))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.18))

                ForEach(segments) { segment in
                    let startFraction = segment.start.timeIntervalSince(dayStart) / dayDuration
                    let endFraction = segment.end.timeIntervalSince(dayStart) / dayDuration
                    let segmentWidth = max(2, width * max(0, endFraction - startFraction))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.isEstimated
                            ? Color.orange.opacity(0.75)
                            : Color.accentColor.opacity(segment.isActive ? 1 : 0.8))
                        .frame(width: segmentWidth)
                        .offset(x: width * max(0, startFraction))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}
