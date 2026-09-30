import AgentIDEProtocol

struct NotificationOutboxDiagnostics: Equatable {
    private(set) var overflow: String?
    private(set) var deliveryError: String?

    mutating func record(page: NotificationOutboxPage) {
        guard page.overflowed else { return }
        let suffix = page.droppedThroughCursor.map { " through cursor \($0)" } ?? ""
        overflow = "Notification outbox exceeded its retention limit and dropped items\(suffix)"
    }

    mutating func record(deliveryError: Error) {
        self.deliveryError = deliveryError.localizedDescription
    }

    mutating func recordSuccessfulDrain() {
        deliveryError = nil
    }
}

struct NotificationDeliveryResponse: Equatable {
    let statusCode: Int
    let accepted: Bool
}

enum NotificationDrainError: Error, Equatable {
    case relayDidNotAccept
}

@MainActor
struct NotificationOutboxDrainer {
    func drain(
        page: NotificationOutboxPage,
        projectNames: [String: String],
        submit: (NotificationIntent) async throws -> NotificationDeliveryResponse,
        acknowledge: (Int) async throws -> Void
    ) async throws {
        for item in page.items {
            let intent = NotificationIntent(
                projectId: item.projectId,
                sessionId: item.sessionId,
                sequence: item.sequence,
                category: item.category,
                projectName: truncatedDisplayMetadata(projectNames[item.projectId] ?? "Agent IDE"),
                sessionTitle: truncatedDisplayMetadata(item.sessionTitle),
                createdAt: item.createdAt
            )
            let response = try await submit(intent)
            guard response.statusCode == 202, response.accepted else {
                throw NotificationDrainError.relayDidNotAccept
            }
            try await acknowledge(item.cursor)
        }
    }
}

func truncatedDisplayMetadata(_ value: String, limit: Int = 200) -> String {
    String(value.unicodeScalars.prefix(limit))
}
