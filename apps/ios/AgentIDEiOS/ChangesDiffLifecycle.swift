import AgentIDEProtocol

struct ChangesRequestCompletion: Equatable {
    enum Outcome: Equatable {
        case succeeded
        case failed(RemoteRequestError)
    }

    let generation: Int
    let outcome: Outcome
}

/// Keeps request generations separate from the view cache so a delayed refresh cannot replace newer state.
final class ChangesDiffLifecycle {
    private var generations: [String: Int] = [:]

    func beginChangesRequest(projectId: String) -> Int {
        let generation = (generations[projectId] ?? 0) + 1
        generations[projectId] = generation
        return generation
    }

    func isCurrent(projectId: String, generation: Int) -> Bool {
        generations[projectId] == generation
    }

    func currentGeneration(projectId: String) -> Int {
        generations[projectId] ?? 0
    }

    func diffKey(projectId: String, path: String, area: GitChangeArea) -> String {
        "\(projectId):\(area.rawValue):\(path)"
    }

    func projectDiffPrefix(projectId: String) -> String {
        "\(projectId):"
    }
}
