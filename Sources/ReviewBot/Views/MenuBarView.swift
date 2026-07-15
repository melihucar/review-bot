import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var history: HistoryStore

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        history = model.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionButtons
            queueSection
            Divider()
            configRow
            activitySection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .task { model.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: model.statusSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(statusColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Review Bot")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            statusBadge
        }
    }

    private var statusBadge: some View {
        let descriptor = statusDescriptor
        return Text(descriptor.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(descriptor.color.opacity(0.15), in: Capsule())
            .foregroundStyle(descriptor.color)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.runNow()
            } label: {
                Label("Run now", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)

            Button {
                model.togglePaused()
            } label: {
                Label(
                    settings.configuration.isPaused ? "Resume" : "Pause",
                    systemImage: settings.configuration.isPaused ? "play.circle" : "pause.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatChip(
                    icon: "sparkles",
                    label: "Running",
                    value: model.runningReview == nil ? 0 : 1,
                    tint: model.runningReview == nil ? .secondary : .blue
                )
                StatChip(
                    icon: "hourglass",
                    label: "Pending",
                    value: model.pendingReviews.count,
                    tint: model.pendingReviews.isEmpty ? .secondary : .orange
                )
                Spacer()
            }

            if let running = model.runningReview {
                QueueRow(item: running, state: "Running", color: .blue, showsProgress: true)
            }

            ForEach(model.pendingReviews.prefix(3)) { item in
                QueueRow(item: item, state: "Pending", color: .orange, showsProgress: false)
            }

            if model.pendingReviews.count > 3 {
                Text("+ \(model.pendingReviews.count - 3) more pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private var configRow: some View {
        HStack(spacing: 8) {
            Label("Every \(intervalLabel)", systemImage: "timer")
            Spacer()
            Label("\(enabledRepositoryCount) enabled", systemImage: "shippingbox")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var activitySection: some View {
        if history.entries.isEmpty {
            ContentUnavailableView(
                "No activity yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Review requests and decisions appear here.")
            )
            .frame(height: 110)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(history.entries.prefix(4)) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var statusColor: Color {
        if settings.configuration.isPaused { return .orange }
        if history.entries.first?.kind == .failed { return .red }
        return .accentColor
    }

    private var statusDescriptor: (label: String, color: Color) {
        if model.isRunning { return ("Reviewing", .blue) }
        if settings.configuration.isPaused { return ("Paused", .orange) }
        if history.entries.first?.kind == .failed { return ("Attention", .red) }
        return ("Active", .green)
    }

    private var enabledRepositoryCount: Int {
        settings.configuration.repositories.filter(\.enabled).count
    }

    private var intervalLabel: String {
        let minutes = settings.configuration.pollIntervalMinutes
        return minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }
}

private struct StatChip: View {
    let icon: String
    let label: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(label)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

private struct ActivityRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.kind.label)
                    .font(.caption.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        if let number = entry.pullRequestNumber {
            return "\(entry.repositoryName) #\(number)"
        }
        return entry.repositoryName
    }
}

private struct QueueRow: View {
    let item: ReviewQueueItem
    let state: String
    let color: Color
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(item.repositoryName) #\(item.pullRequestNumber)")
                    .font(.caption.weight(.semibold))
                Text(item.pullRequestTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(state)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(7)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension HistoryEventKind {
    var tint: Color {
        switch self {
        case .requestDetected, .reviewStarted: .blue
        case .approved: .green
        case .changesRequested: .orange
        case .commented: .purple
        case .failed: .red
        }
    }
}
