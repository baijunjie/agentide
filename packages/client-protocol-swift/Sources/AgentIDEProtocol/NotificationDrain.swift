public struct NotificationOutboxItem: Codable, Equatable {
    public let cursor: Int
    public let projectId: String
    public let sessionId: String
    public let sequence: Int
    public let category: NotificationCategory
    public let sessionTitle: String
    public let createdAt: String

    public init(
        cursor: Int,
        projectId: String,
        sessionId: String,
        sequence: Int,
        category: NotificationCategory,
        sessionTitle: String,
        createdAt: String
    ) {
        self.cursor = cursor
        self.projectId = projectId
        self.sessionId = sessionId
        self.sequence = sequence
        self.category = category
        self.sessionTitle = sessionTitle
        self.createdAt = createdAt
    }
}

public struct NotificationOutboxPage: Codable, Equatable {
    public let items: [NotificationOutboxItem]
    public let overflowed: Bool
    public let droppedThroughCursor: Int?

    public init(items: [NotificationOutboxItem], overflowed: Bool, droppedThroughCursor: Int? = nil) {
        self.items = items
        self.overflowed = overflowed
        self.droppedThroughCursor = droppedThroughCursor
    }
}
