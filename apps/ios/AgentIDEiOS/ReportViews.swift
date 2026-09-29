import AgentIDEProtocol
import SwiftUI

enum ReportPresentation {
    static let detailLimit = 50

    static func truncationText(total: Int) -> String? {
        guard total > detailLimit else { return nil }
        return "Showing the first \(detailLimit) of \(total) items"
    }
}

struct ReportBlock: View {
    let event: ReportEvent
    let expanded: Bool
    let toggleExpanded: (Bool) -> Void
    let openFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { toggleExpanded(!expanded) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .accessibilityIdentifier(reportIconIdentifier)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.headline)
                        Text(event.summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("report-\(event.kind)")

            summary
            if expanded { expandedDetails }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.2)))
    }

    @ViewBuilder private var summary: some View {
        switch event.payload {
        case let .testReport(report):
            MetricGroup(metrics: [
                .init(id: "report-test-total", value: "\(report.total)", label: "Total", color: .primary),
                .init(id: "report-test-passed", value: "\(report.passed)", label: "Passed", color: .green),
                .init(id: "report-test-failed", value: "\(report.failed)", label: "Failed", color: report.failed == 0 ? .secondary : .red),
                .init(id: "report-test-skipped", value: "\(report.skipped)", label: "Skipped", color: .secondary),
            ])
        case let .plan(report):
            progressSummary(completed: report.steps.filter { $0.status == .completed }.count, total: report.steps.count)
        case let .todo(report):
            progressSummary(completed: report.items.filter { $0.status == .completed }.count, total: report.items.count)
        case let .diagnostics(report):
            MetricGroup(metrics: [
                .init(id: "report-diagnostics-errors", value: "\(report.items.filter { $0.severity == .error }.count)", label: "Errors", color: .red),
                .init(id: "report-diagnostics-warnings", value: "\(report.items.filter { $0.severity == .warning }.count)", label: "Warnings", color: .orange),
                .init(id: "report-diagnostics-info", value: "\(report.items.filter { $0.severity == .info }.count)", label: "Info", color: .blue),
            ])
        case .unknown:
            EmptyView()
        }
    }

    private var detailCount: Int {
        switch event.payload {
        case let .testReport(report): report.failures.count
        case let .plan(report): report.steps.count
        case let .todo(report): report.items.count
        case let .diagnostics(report): report.items.count
        case .unknown: 1
        }
    }

    @ViewBuilder private var expandedDetails: some View {
        // The feed is already a scroll view, so this list only scrolls once it has a fixed height.
        if detailCount > 8 {
            ScrollView { details }
                .frame(height: 320)
        } else {
            details
        }
    }

    @ViewBuilder private var details: some View {
        Divider()
        switch event.payload {
        case let .testReport(report):
            if report.failures.isEmpty {
                Text("No failing tests").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.failures.prefix(ReportPresentation.detailLimit).enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(failure.name, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        if let message = failure.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                truncationNotice(total: report.failures.count)
            }
        case let .plan(report):
            ForEach(Array(report.steps.prefix(ReportPresentation.detailLimit).enumerated()), id: \.offset) { index, step in
                ReportRow(icon: statusIcon(step.status.rawValue), title: "\(index + 1). \(step.title)", detail: statusLabel(step.status.rawValue), color: statusColor(step.status.rawValue))
            }
            truncationNotice(total: report.steps.count)
        case let .todo(report):
            ForEach(Array(report.items.prefix(ReportPresentation.detailLimit).enumerated()), id: \.offset) { _, item in
                ReportRow(icon: statusIcon(item.status.rawValue), title: item.title, detail: statusLabel(item.status.rawValue), color: statusColor(item.status.rawValue))
            }
            truncationNotice(total: report.items.count)
        case let .diagnostics(report):
            ForEach(Array(report.items.prefix(ReportPresentation.detailLimit).enumerated()), id: \.offset) { _, item in
                if let path = item.relativePath {
                    Button { openFile(path) } label: { diagnosticRow(item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("diagnostic-file-\(path)")
                } else {
                    diagnosticRow(item)
                }
            }
            truncationNotice(total: report.items.count)
        case .unknown:
            Text("This report type is not supported by this version of AgentIDE.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("report-unknown-fallback")
        }
    }

    private var icon: String {
        switch event.payload {
        case let .testReport(report): report.failed == 0 ? "checkmark.circle" : "xmark.circle"
        case .plan: "list.number"
        case .todo: "checklist"
        case .diagnostics: "stethoscope"
        case .unknown: "doc.text"
        }
    }

    private var reportIconIdentifier: String {
        if case let .testReport(report) = event.payload, report.failed > 0 { return "report-icon-failed" }
        return "report-icon"
    }

    private var tint: Color {
        switch event.payload {
        case let .testReport(report): report.failed == 0 ? .green : .red
        case .plan: .blue
        case .todo: .purple
        case .diagnostics: .orange
        case .unknown: .secondary
        }
    }

    private func progressSummary(completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(completed) of \(total) completed").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: total == 0 ? 0 : Double(completed), total: Double(max(total, 1)))
        }
    }

    @ViewBuilder private func truncationNotice(total: Int) -> some View {
        if let text = ReportPresentation.truncationText(total: total) {
            Text(text)
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("report-details-truncated")
        }
    }

    private func diagnosticRow(_ item: DiagnosticReportItem) -> some View {
        let location = diagnosticLocation(item)
        return ReportRow(
            icon: diagnosticIcon(item.severity),
            title: item.message,
            detail: location,
            spokenDetail: location,
            color: diagnosticColor(item.severity)
        )
    }

    private func diagnosticLocation(_ item: DiagnosticReportItem) -> String? {
        item.relativePath.map { path in
            let line = item.line.map { ":\($0)" } ?? ""
            let column = item.column.map { ":\($0)" } ?? ""
            return "\(path)\(line)\(column)"
        }
    }

    private func diagnosticIcon(_ severity: DiagnosticReportItem.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func diagnosticColor(_ severity: DiagnosticReportItem.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        case "blocked": "exclamationmark.octagon.fill"
        default: "circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": .green
        case "in_progress": .blue
        case "blocked": .red
        default: .secondary
        }
    }

    private func statusLabel(_ status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct MetricGroup: View {
    struct Metric: Identifiable {
        let id: String
        let value: String
        let label: String
        let color: Color
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let metrics: [Metric]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                spread
                stacked
            }
        }
    }

    private var spread: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { Spacer(minLength: 12) }
                metricView(metric)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metrics) { metricView($0) }
        }
    }

    private func metricView(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.value).font(.headline.monospacedDigit()).foregroundStyle(metric.color)
            Text(metric.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(metric.id)
    }
}

private struct ReportRow: View {
    let icon: String
    let title: String
    let detail: String?
    var spokenDetail: String? = nil
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let spokenDetail {
                    WrappingPath(path: spokenDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}
