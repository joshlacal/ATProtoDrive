import AppKit
import SwiftUI

public enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case active = "Active"
    case completed = "Completed"
    case attention = "Failed / Interrupted"

    public var id: String { rawValue }

    public func matches(_ job: TransferJobRecord) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            job.state.isActive
        case .completed:
            job.state == .completed
        case .attention:
            switch job.state {
            case .failed, .interrupted, .cancelled:
                true
            default:
                false
            }
        }
    }
}

/// Native macOS Activity view displaying durable transfer history, live progress,
/// filter pills, cancellation, retry, Reveal in Finder, and Clear Finished controls.
public struct ActivityView: View {
    @Environment(TransferQueue.self) private var environmentQueue: TransferQueue?
    private let explicitQueue: TransferQueue?

    @State private var selectedFilter: ActivityFilter = .all

    public init(transferQueue: TransferQueue? = nil) {
        self.explicitQueue = transferQueue
    }

    private var queue: TransferQueue? {
        explicitQueue ?? environmentQueue
    }

    public var body: some View {
        Group {
            if let queue {
                activityContent(queue: queue)
            } else {
                ContentUnavailableView(
                    "Activity Unavailable",
                    systemImage: "arrow.left.arrow.right.circle",
                    description: Text("No transfer queue is attached to this window.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Activity")
    }

    private func activityContent(queue: TransferQueue) -> some View {
        let filteredJobs = queue.jobs.filter { selectedFilter.matches($0) }

        return VStack(spacing: 0) {
            headerBar(queue: queue)
            Divider()
            if let persistenceError = queue.lastPersistenceError {
                InlineErrorBanner(
                    message: "Transfer history could not be saved: \(persistenceError)"
                )
            }
            if queue.jobs.isEmpty {
                ContentUnavailableView(
                    "No Transfers",
                    systemImage: "arrow.down.circle",
                    description: Text("File downloads, previews, and verified backups appear here with live progress and recovery status.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Transfers", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No transfers match the \(selectedFilter.rawValue) filter.")
                } actions: {
                    Button("Show All") {
                        selectedFilter = .all
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredJobs) { job in
                        ActivityJobRow(
                            job: job,
                            canRetry: queue.canRetry(jobID: job.id),
                            onCancel: { queue.cancel(jobID: job.id) },
                            onRetry: { queue.retry(jobID: job.id) },
                            onRevealInFinder: revealInFinder
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func headerBar(queue: TransferQueue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity")
                        .font(.title3.weight(.semibold))
                    Text(summaryText(queue: queue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Finished") {
                    queue.clearFinished()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(queue.finishedCount == 0)
            }

            HStack(spacing: 8) {
                ForEach(ActivityFilter.allCases) { filter in
                    let count = queue.jobs.filter { filter.matches($0) }.count
                    filterPill(filter: filter, count: count)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func filterPill(filter: ActivityFilter, count: Int) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                if count > 0 || filter == .all {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected
                                ? AnyShapeStyle(Color.white.opacity(0.22))
                                : AnyShapeStyle(Color.secondary.opacity(0.15)),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(Color.secondary.opacity(0.12)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func summaryText(queue: TransferQueue) -> String {
        let active = queue.activeCount
        let total = queue.jobs.count
        if total == 0 {
            return "No recent transfers"
        }
        if active == 0 {
            return "\(total) transfer\(total == 1 ? "" : "s") · none active"
        }
        return "\(active) active · \(total) total"
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ActivityJobRow: View {
    let job: TransferJobRecord
    let canRetry: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRevealInFinder: (String) -> Void

    private var destinationExists: Bool {
        guard let path = job.destinationPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: job.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(stateTint)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        stateBadge
                    }

                    if let subtitle = job.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 8) {
                        Text(job.kind.displayLabel)
                        Text("·")
                        Text(job.updatedAt, format: .relative(presentation: .named))
                        if let byteSummary = byteProgressLabel {
                            Text("·")
                            Text(byteSummary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                actionButtons
            }

            if job.state.isActive {
                if let fraction = job.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: job.state == .failed ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(job.state == .failed ? .red : .orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    private var stateBadge: some View {
        Label(job.state.displayLabel, systemImage: job.state.symbolName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(stateTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(stateTint.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if job.state.isActive {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if canRetry {
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let destinationPath = job.destinationPath, destinationExists {
                Button("Reveal in Finder") {
                    onRevealInFinder(destinationPath)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var byteProgressLabel: String? {
        if let totalBytes = job.totalBytes, totalBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: job.bytesCompleted, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            if job.state == .completed {
                return total
            }
            return "\(done) of \(total)"
        }
        if job.bytesCompleted > 0 {
            return ByteCountFormatter.string(fromByteCount: job.bytesCompleted, countStyle: .file)
        }
        return nil
    }

    private var stateTint: Color {
        switch job.state {
        case .queued, .discovering:
            .secondary
        case .waitingForPermission, .interrupted:
            .orange
        case .running, .verifying:
            .blue
        case .completed:
            .green
        case .cancelled:
            .secondary
        case .failed:
            .red
        }
    }
}
