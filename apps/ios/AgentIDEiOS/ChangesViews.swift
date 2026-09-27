import AgentIDEProtocol
import SwiftUI

enum ChangesListIdentifier {
    static func value(for change: GitChange) -> String {
        "\(change.area.rawValue):\(change.relativePath)"
    }
}

private extension GitChange {
    var changesListId: String { ChangesListIdentifier.value(for: self) }
}

struct ChangesView: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject

    var body: some View {
        Group {
            if let error = connection.changesError(projectId: project.id) {
                changesError(error, retry: { connection.requestChanges(projectId: project.id) })
            } else if let response = connection.changes(projectId: project.id) {
                if !response.isGitRepository {
                    empty("This project is not a Git repository.", icon: "tray")
                } else if response.changes.isEmpty {
                    empty("The working tree is clean.", icon: "checkmark.circle")
                } else {
                    List(response.changes, id: \.changesListId) { change in
                        NavigationLink {
                            DiffViewer(project: project, change: change)
                        } label: {
                            ChangeRow(change: change)
                        }
                        .accessibilityIdentifier("change-\(change.area.rawValue)-\(change.relativePath)")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Changes")
        .refreshable { connection.requestChanges(projectId: project.id) }
        .toolbar {
            Button { connection.requestChanges(projectId: project.id) } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityIdentifier("changes-refresh")
                .disabled(connection.isLoadingChanges(projectId: project.id))
        }
        .task { connection.requestChanges(projectId: project.id) }
    }

    private func empty(_ text: String, icon: String) -> some View {
        ContentUnavailableView("No Changes", systemImage: icon, description: Text(text))
    }

    private func changesError(_ error: RemoteRequestError, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("Changes Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            Button("Retry", action: retry)
        }
    }

}

struct ChangesWorkspaceContent: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let openDiff: (GitChange) -> Void

    var body: some View {
        Group {
            if let error = connection.changesError(projectId: project.id) {
                VStack(spacing: 12) {
                    ContentUnavailableView("Changes Unavailable", systemImage: "exclamationmark.triangle", description: Text(error.message))
                    Button("Retry") { connection.requestChanges(projectId: project.id) }
                }
            } else if let response = connection.changes(projectId: project.id) {
                if !response.isGitRepository { ContentUnavailableView("No Changes", systemImage: "tray", description: Text("This project is not a Git repository.")) }
                else if response.changes.isEmpty { ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean.")) }
                else {
                    List(response.changes, id: \.changesListId) { change in
                        Button { openDiff(change) } label: { ChangeRow(change: change) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("change-\(change.area.rawValue)-\(change.relativePath)")
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

private struct ChangeRow: View {
    let change: GitChange

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(change.relativePath).font(.body.monospaced()).lineLimit(2)
                if let previous = change.previousRelativePath { Text(previous).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text("\(change.area.rawValue.capitalized) · \(change.kind.rawValue.capitalized)\(change.isBinary ? " · Binary" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(size).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch change.kind {
        case .added, .untracked: "plus.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.left.arrow.right.circle.fill"
        case .modified: "circle.fill"
        }
    }

    private var tint: Color { change.kind == .deleted ? .red : (change.kind == .modified ? .orange : .green) }
    private var size: String { [change.oldSize, change.newSize].compactMap { $0 }.map { "\($0) B" }.joined(separator: " → ") }
}

struct DiffViewer: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let change: GitChange

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(displayChange.relativePath)
        .navigationBarTitleDisplayMode(.inline)
        .task { connection.requestDiff(projectId: project.id, change: change) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayChange.relativePath).font(.headline.monospaced())
            if let previous = displayChange.previousRelativePath { Text("from \(previous)").font(.caption.monospaced()).foregroundStyle(.secondary) }
            Text("\(displayChange.area.rawValue.capitalized) · \(displayChange.kind.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
    }

    @ViewBuilder private var content: some View {
        if let error = connection.diffError(projectId: project.id, change: change) {
            VStack(spacing: 12) {
                ContentUnavailableView("Diff Unavailable", systemImage: "exclamationmark.triangle", description: Text(error.message))
                Button("Retry") { connection.requestDiff(projectId: project.id, change: change) }
            }
        } else if displayChange.isBinary {
            ContentUnavailableView("Binary File", systemImage: "doc.fill", description: Text(binarySize))
        } else if let response = connection.diff(projectId: project.id, change: change) {
            DiffText(diff: response.diff ?? "")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var binarySize: String {
        let values = [displayChange.oldSize, displayChange.newSize].compactMap { $0 }.map { "\($0) bytes" }
        return values.isEmpty ? "Git does not provide a textual diff for this file." : values.joined(separator: " → ")
    }

    private var displayChange: GitChange {
        connection.diff(projectId: project.id, change: change)?.change ?? change
    }
}

private struct DiffText: View {
    let diff: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(DiffParser.parse(diff).enumerated()), id: \.offset) { _, line in
                    DiffLine(line: line)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
            .padding()
        }
    }

}

private struct DiffLine: View {
    let line: ParsedDiffLine
    var body: some View {
        HStack(spacing: 8) {
            Text(line.oldLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.text.isEmpty ? " " : line.text)
        }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(background)
            .accessibilityIdentifier(line.text.hasPrefix("@@") ? "diff-hunk" : "diff-line")
    }
    private var foreground: Color { line.text.hasPrefix("+") ? .green : (line.text.hasPrefix("-") ? .red : .primary) }
    private var background: Color { line.text.hasPrefix("+") ? .green.opacity(0.12) : (line.text.hasPrefix("-") ? .red.opacity(0.12) : .clear) }
}

struct ParsedDiffLine: Equatable {
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

enum DiffParser {
    static func parse(_ diff: String) -> [ParsedDiffLine] {
        var oldLine: Int?
        var newLine: Int?
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { raw in
            let line = String(raw)
            if let range = hunkRange(line) {
                oldLine = range.old
                newLine = range.new
                return ParsedDiffLine(text: line, oldLine: nil, newLine: nil)
            }
            if line.hasPrefix("\\ No newline") {
                return ParsedDiffLine(text: line, oldLine: nil, newLine: nil)
            }
            guard oldLine != nil, newLine != nil else { return ParsedDiffLine(text: line, oldLine: nil, newLine: nil) }
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                defer { newLine! += 1 }
                return ParsedDiffLine(text: line, oldLine: nil, newLine: newLine)
            }
            if line.hasPrefix("-") && !line.hasPrefix("---") {
                defer { oldLine! += 1 }
                return ParsedDiffLine(text: line, oldLine: oldLine, newLine: nil)
            }
            defer { oldLine! += 1; newLine! += 1 }
            return ParsedDiffLine(text: line, oldLine: oldLine, newLine: newLine)
        }
    }

    private static func hunkRange(_ line: String) -> (old: Int, new: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let values = line.split(separator: " ").filter { $0.hasPrefix("-") || $0.hasPrefix("+") }
        guard values.count >= 2,
              let old = Int(values[0].dropFirst().split(separator: ",")[0]),
              let new = Int(values[1].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }
}
