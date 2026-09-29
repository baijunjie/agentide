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
                    ContentUnavailableView("Not a Git Repository", systemImage: "tray", description: Text("This project is not a Git repository."))
                } else if response.changes.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
                } else {
                    List {
                        ForEach(groupedChanges(response.changes), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.changes, id: \.changesListId) { change in
                                    NavigationLink {
                                        DiffViewer(project: project, change: change)
                                    } label: {
                                        ChangeRow(change: change, showsDisclosure: false)
                                    }
                                    .accessibilityIdentifier("change-\(change.area.rawValue)-\(change.relativePath)")
                                }
                            }
                        }
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

    private func changesError(_ error: RemoteRequestError, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("Changes Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(MobileFailureCopy.message(error.message, code: error.code))
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
                ContentUnavailableView {
                    Label("Changes Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(MobileFailureCopy.message(error.message, code: error.code))
                } actions: {
                    Button("Retry") { connection.requestChanges(projectId: project.id) }
                }
            } else if let response = connection.changes(projectId: project.id) {
                if !response.isGitRepository { ContentUnavailableView("Not a Git Repository", systemImage: "tray", description: Text("This project is not a Git repository.")) }
                else if response.changes.isEmpty { ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean.")) }
                else {
                    List {
                        ForEach(groupedChanges(response.changes), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.changes, id: \.changesListId) { change in
                                    Button {
                                        connection.requestDiff(projectId: project.id, change: change)
                                        openDiff(change)
                                    } label: { ChangeRow(change: change, showsDisclosure: true) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("change-\(change.area.rawValue)-\(change.relativePath)")
                                }
                            }
                        }
                    }
                }
            } else if connection.isLoadingChanges(projectId: project.id) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ChangeRow: View {
    let change: GitChange
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(change.relativePath)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let previous = change.previousRelativePath {
                    Text(previous)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(change.area.rawValue.capitalized) · \(change.kind.rawValue.capitalized)\(change.isBinary ? " · Binary" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(size).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHint("View diff")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .belowWorkspaceNavigationBar()
        .task(id: change.changesListId) { connection.requestDiff(projectId: project.id, change: change) }
        .onChange(of: connection.loadingDiffs) { _, _ in retryDiffIfIdle() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let previous = displayChange.previousRelativePath {
                Text("From \(previous)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(displayChange.area.rawValue.capitalized) · \(displayChange.kind.rawValue.capitalized)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
    }

    @ViewBuilder private var content: some View {
        if let error = connection.diffError(projectId: project.id, change: change) {
            ContentUnavailableView {
                Label("Diff Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(diffFailureDetail(error))
            } actions: {
                Button(diffRetryTitle(error)) { connection.requestDiff(projectId: project.id, change: change) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayChange.isBinary {
            ContentUnavailableView("Binary File", systemImage: "doc.fill", description: Text(binarySize))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let response = connection.diff(projectId: project.id, change: change) {
            DiffText(diff: response.diff ?? "")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        }
    }

    private func retryDiffIfIdle() {
        guard connection.diff(projectId: project.id, change: change) == nil,
              connection.diffError(projectId: project.id, change: change) == nil,
              !connection.isLoadingDiff(projectId: project.id, change: change) else { return }
        connection.requestDiff(projectId: project.id, change: change)
    }

    private var binarySize: String {
        let values = [displayChange.oldSize, displayChange.newSize].compactMap { $0 }.map { "\($0) bytes" }
        return values.isEmpty ? "Git does not provide a textual diff for this file." : values.joined(separator: " → ")
    }

    private var displayChange: GitChange {
        connection.diff(projectId: project.id, change: change)?.change ?? change
    }
}

private struct ChangeGroup: Identifiable {
    let title: String
    let changes: [GitChange]
    var id: String { title }
}

private func groupedChanges(_ changes: [GitChange]) -> [ChangeGroup] {
    let staged = changes.filter { $0.area == .staged }
    let unstaged = changes.filter { $0.area == .unstaged }
    return [("Staged", staged), ("Unstaged", unstaged)]
        .filter { !$0.1.isEmpty }
        .map { ChangeGroup(title: $0.0, changes: $0.1) }
}

private func diffFailureDetail(_ error: RemoteRequestError) -> String {
    if error.code == "DIFF_TOO_LARGE" {
        return "\(error.message). Trying again sends the same request. The diff stays over the transfer limit until it is smaller."
    }
    return MobileFailureCopy.message(error.message, code: error.code)
}

private func diffRetryTitle(_ error: RemoteRequestError) -> String {
    error.code == "DIFF_TOO_LARGE" ? "Request this diff again" : "Retry"
}

private struct DiffText: View {
    let diff: String

    var body: some View {
        // One scroll view on both axes centers a short diff and clips the leading edge of the first line.
        ScrollView {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(DiffParser.parse(diff).enumerated()), id: \.offset) { _, line in
                        DiffLine(line: line)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .padding()
            }
            .defaultScrollAnchor(.leading)
        }
        .defaultScrollAnchor(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
