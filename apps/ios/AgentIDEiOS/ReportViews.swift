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
                    Image(systemName: icon).foregroundStyle(tint)
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
            if expanded { details }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.2)))
    }

    @ViewBuilder private var summary: some View {
        switch event.payload {
        case let .testReport(report):
            HStack(spacing: 8) {
                metric("\(report.total)", "Total", .primary, identifier: "report-test-total")
                metric("\(report.passed)", "Passed", .green, identifier: "report-test-passed")
                metric("\(report.failed)", "Failed", report.failed == 0 ? .secondary : .red, identifier: "report-test-failed")
                metric("\(report.skipped)", "Skipped", .secondary, identifier: "report-test-skipped")
            }
        case let .plan(report):
            progressSummary(completed: report.steps.filter { $0.status == .completed }.count, total: report.steps.count)
        case let .todo(report):
            progressSummary(completed: report.items.filter { $0.status == .completed }.count, total: report.items.count)
        case let .diagnostics(report):
            HStack(spacing: 12) {
                metric("\(report.items.filter { $0.severity == .error }.count)", "Errors", .red, identifier: "report-diagnostics-errors")
                metric("\(report.items.filter { $0.severity == .warning }.count)", "Warnings", .orange, identifier: "report-diagnostics-warnings")
                metric("\(report.items.filter { $0.severity == .info }.count)", "Info", .blue, identifier: "report-diagnostics-info")
            }
        case .unknown:
            Label("Report \(event.kind)", systemImage: "doc.text.magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
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
        case .testReport: "checkmark.circle"
        case .plan: "list.number"
        case .todo: "checklist"
        case .diagnostics: "stethoscope"
        case .unknown: "doc.text"
        }
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

    private func metric(_ value: String, _ label: String, _ color: Color, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
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
        ReportRow(
            icon: diagnosticIcon(item.severity),
            title: item.message,
            detail: diagnosticLocation(item),
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

private struct ReportRow: View {
    let icon: String
    let title: String
    let detail: String?
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).multilineTextAlignment(.leading)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
