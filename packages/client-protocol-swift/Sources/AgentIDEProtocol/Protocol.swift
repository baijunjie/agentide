import Foundation

public enum ProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
}

public struct MessageType: Codable, Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard isMessageType(rawValue) else { throw ProtocolDecodingError.invalidMessageType(rawValue) }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AgentType: String, Codable, Sendable {
    case claude
    case codex
}

public enum SessionStatus: String, Codable, Sendable {
    case starting
    case running
    case idle
    case waitingUser = "waiting_user"
    case completed
    case failed
    case cancelled
}

public struct Project: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootPath: String
    public let createdAt: String
    public let enabledAgents: [AgentType]

    public init(id: String, name: String, rootPath: String, createdAt: String, enabledAgents: [AgentType]) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.enabledAgents = enabledAgents
    }
}

public struct Session: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let agentType: AgentType
    public let nativeSessionId: String?
    public let title: String
    public let status: SessionStatus
    public let createdAt: String
    public let updatedAt: String
}

public struct FileEntry: Codable, Equatable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case file
        case directory
    }

    public let name: String
    public let relativePath: String
    public let type: EntryType
    public let size: Int?
    public let `extension`: String?
    public let isText: Bool?
    public let isImage: Bool?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, relativePath, type, size, `extension`, isText, isImage
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        type = try container.decode(EntryType.self, forKey: .type)
        size = try decodeOptionalNonNegativeInt(container, forKey: .size)
        `extension` = try decodeOptionalNonNull(container, forKey: .extension)
        isText = try decodeOptionalNonNull(container, forKey: .isText)
        isImage = try decodeOptionalNonNull(container, forKey: .isImage)
    }
}

public struct ProjectSearchFilesRequest: Codable, Equatable, Sendable {
    public let searchId: String
    public let query: String
    public let limit: Int

    private enum CodingKeys: String, CodingKey, CaseIterable { case searchId, query, limit }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchId = try container.decode(String.self, forKey: .searchId)
        query = try container.decode(String.self, forKey: .query)
        limit = try container.decode(Int.self, forKey: .limit)
        guard validSearchId(searchId), validSearchQuery(query), (1...100).contains(limit) else {
            throw ProtocolDecodingError.invalidSearchRequest
        }
    }
}

public struct ProjectCancelSearchRequest: Codable, Equatable, Sendable {
    public let searchId: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case searchId }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchId = try container.decode(String.self, forKey: .searchId)
        guard validSearchId(searchId) else { throw ProtocolDecodingError.invalidSearchRequest }
    }
}

public struct ProjectSearchFilesResponse: Codable, Equatable, Sendable {
    public let searchId: String
    public let query: String
    public let results: [FileEntry]
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable { case searchId, query, results, hasMore }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchId = try container.decode(String.self, forKey: .searchId)
        query = try container.decode(String.self, forKey: .query)
        results = try container.decode([FileEntry].self, forKey: .results)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        guard validSearchId(searchId), validSearchQuery(query), results.count <= 100 else {
            throw ProtocolDecodingError.invalidSearchRequest
        }
    }
}

private func validSearchQuery(_ query: String) -> Bool {
    let scalars = query.unicodeScalars
    return (2...256).contains(scalars.count)
        && scalars.first.map({ !isUnicodeWhiteSpace($0) }) == true
        && scalars.last.map({ !isUnicodeWhiteSpace($0) }) == true
}

private func isUnicodeWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        true
    default:
        false
    }
}

private func validSearchId(_ searchId: String) -> Bool {
    (1...128).contains(searchId.unicodeScalars.count)
}

public enum GitChangeKind: String, Codable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
}

public enum GitChangeArea: String, Codable, Sendable {
    case staged
    case unstaged
}

public struct GitChange: Codable, Equatable, Sendable {
    public let relativePath: String
    public let previousRelativePath: String?
    public let kind: GitChangeKind
    public let area: GitChangeArea
    public let isBinary: Bool
    public let oldSize: Int?
    public let newSize: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case relativePath, previousRelativePath, kind, area, isBinary, oldSize, newSize
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        previousRelativePath = try decodeOptionalString(container, forKey: .previousRelativePath)
        kind = try container.decode(GitChangeKind.self, forKey: .kind)
        area = try container.decode(GitChangeArea.self, forKey: .area)
        isBinary = try container.decode(Bool.self, forKey: .isBinary)
        oldSize = try decodeOptionalNonNegativeInt(container, forKey: .oldSize)
        newSize = try decodeOptionalNonNegativeInt(container, forKey: .newSize)

        if kind == .renamed {
            guard previousRelativePath != nil else {
                throw ProtocolDecodingError.missingRenamedPath
            }
        } else if previousRelativePath != nil {
            throw ProtocolDecodingError.unexpectedPreviousPath
        }
    }
}

public struct ProjectChangesResponse: Codable, Equatable, Sendable {
    public let isGitRepository: Bool
    public let changes: [GitChange]

    private enum CodingKeys: String, CodingKey, CaseIterable { case isGitRepository, changes }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isGitRepository = try container.decode(Bool.self, forKey: .isGitRepository)
        changes = try container.decode([GitChange].self, forKey: .changes)
        if !isGitRepository && !changes.isEmpty {
            throw ProtocolDecodingError.nonGitRepositoryChanges
        }
    }
}

public struct ProjectDiffRequest: Codable, Equatable, Sendable {
    public let relativePath: String
    public let area: GitChangeArea

    private enum CodingKeys: String, CodingKey, CaseIterable { case relativePath, area }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        area = try container.decode(GitChangeArea.self, forKey: .area)
    }
}

public struct ProjectDiffResponse: Codable, Equatable, Sendable {
    public let change: GitChange
    public let diff: String?

    private enum CodingKeys: String, CodingKey, CaseIterable { case change, diff }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        change = try container.decode(GitChange.self, forKey: .change)
        diff = try decodeOptionalString(container, forKey: .diff)
        if change.isBinary && diff != nil {
            throw ProtocolDecodingError.binaryDiff
        }
    }
}

public struct EncryptedPayload: Codable, Equatable, Sendable {
    public enum Version: Int, Codable, Sendable { case v1 = 1 }

    public let encryptionVersion: Version
    public let ciphertext: String

    public init(encryptionVersion: Version = .v1, ciphertext: String) {
        self.encryptionVersion = encryptionVersion
        self.ciphertext = ciphertext
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case encryptionVersion, ciphertext }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encryptionVersion = try container.decode(Version.self, forKey: .encryptionVersion)
        ciphertext = try container.decode(String.self, forKey: .ciphertext)
    }
}

public enum WirePayload<Payload: Codable & Sendable>: Codable, Sendable {
    case clear(Payload)
    case encrypted(EncryptedPayload)

    public init(from decoder: Decoder) throws {
        let keys = (try? decoder.container(keyedBy: DynamicCodingKey.self).allKeys.map(\.stringValue)) ?? []
        if keys.contains("encryptionVersion") || keys.contains("ciphertext") {
            self = .encrypted(try EncryptedPayload(from: decoder))
        } else {
            self = .clear(try Payload(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .clear(payload): try payload.encode(to: encoder)
        case let .encrypted(payload): try payload.encode(to: encoder)
        }
    }
}

public struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: ProtocolVersion
    public let id: String
    public let type: MessageType
    public let sourceDeviceId: String
    public let targetDeviceId: String?
    public let projectId: String?
    public let sessionId: String?
    public let timestamp: String
    public let payload: WirePayload<Payload>

    public init(
        version: ProtocolVersion = .v1,
        id: String,
        type: MessageType,
        sourceDeviceId: String,
        targetDeviceId: String? = nil,
        projectId: String? = nil,
        sessionId: String? = nil,
        timestamp: String,
        payload: WirePayload<Payload>
    ) throws {
        guard isTimestamp(timestamp) else { throw ProtocolDecodingError.invalidTimestamp(timestamp) }
        try requireNonEmpty(id, field: "id")
        try requireNonEmpty(sourceDeviceId, field: "sourceDeviceId")
        try requireOptionalNonEmpty(targetDeviceId, field: "targetDeviceId")
        try requireOptionalNonEmpty(projectId, field: "projectId")
        try requireOptionalNonEmpty(sessionId, field: "sessionId")
        self.version = version
        self.id = id
        self.type = type
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.projectId = projectId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, type, sourceDeviceId, targetDeviceId, projectId, sessionId, timestamp, payload
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(ProtocolVersion.self, forKey: .version)
        id = try decodeNonEmptyString(container, forKey: .id)
        type = try container.decode(MessageType.self, forKey: .type)
        sourceDeviceId = try decodeNonEmptyString(container, forKey: .sourceDeviceId)
        targetDeviceId = try decodeOptionalNonEmptyString(container, forKey: .targetDeviceId)
        projectId = try decodeOptionalNonEmptyString(container, forKey: .projectId)
        sessionId = try decodeOptionalNonEmptyString(container, forKey: .sessionId)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        guard isTimestamp(timestamp) else { throw ProtocolDecodingError.invalidTimestamp(timestamp) }
        payload = try container.decode(WirePayload<Payload>.self, forKey: .payload)
    }
}

public struct EmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct ProtocolError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue?

    private enum CodingKeys: String, CodingKey, CaseIterable { case code, message, details }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try decodeNonEmptyString(container, forKey: .code)
        message = try decodeNonEmptyString(container, forKey: .message)
        details = try decodeOptionalJSONValue(container, forKey: .details)
    }
}

public struct ResponseEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let version: ProtocolVersion
    public let id: String
    public let type: MessageType
    public let sourceDeviceId: String
    public let targetDeviceId: String?
    public let projectId: String?
    public let sessionId: String?
    public let timestamp: String
    public let payload: WirePayload<Payload>?
    public let replyTo: String
    public let ok: Bool
    public let error: ProtocolError?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, type, sourceDeviceId, targetDeviceId, projectId, sessionId, timestamp
        case payload, replyTo, ok, error
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(ProtocolVersion.self, forKey: .version)
        id = try decodeNonEmptyString(container, forKey: .id)
        type = try container.decode(MessageType.self, forKey: .type)
        sourceDeviceId = try decodeNonEmptyString(container, forKey: .sourceDeviceId)
        targetDeviceId = try decodeOptionalNonEmptyString(container, forKey: .targetDeviceId)
        projectId = try decodeOptionalNonEmptyString(container, forKey: .projectId)
        sessionId = try decodeOptionalNonEmptyString(container, forKey: .sessionId)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        guard isTimestamp(timestamp) else { throw ProtocolDecodingError.invalidTimestamp(timestamp) }
        payload = container.contains(.payload)
            ? try container.decode(WirePayload<Payload>.self, forKey: .payload)
            : nil
        replyTo = try decodeNonEmptyString(container, forKey: .replyTo)
        ok = try container.decode(Bool.self, forKey: .ok)
        if container.contains(.error) {
            guard try !container.decodeNil(forKey: .error) else {
                throw ProtocolDecodingError.explicitNull("error")
            }
            error = try container.decode(ProtocolError.self, forKey: .error)
        } else {
            error = nil
        }
    }
}

public struct SessionStartedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let nativeSessionId: String?
}

public struct TextDeltaEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let content: String
}

public struct MessageEvent: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case agent, user, system }
    public enum Format: String, Codable, Sendable { case plain, markdown }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let role: Role
    public let content: String
    public let format: Format
}

public struct ToolStartedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let toolName: String
    public let title: String?
    public let input: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, sequence, timestamp, type, toolName, title, input
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        sequence = try container.decode(Int.self, forKey: .sequence)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        type = try container.decode(String.self, forKey: .type)
        toolName = try container.decode(String.self, forKey: .toolName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        input = try decodeOptionalJSONValue(container, forKey: .input)
    }
}

public struct ToolFinishedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let toolName: String
    public let output: JSONValue?
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, sequence, timestamp, type, toolName, output, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        sequence = try container.decode(Int.self, forKey: .sequence)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        type = try container.decode(String.self, forKey: .type)
        toolName = try container.decode(String.self, forKey: .toolName)
        output = try decodeOptionalJSONValue(container, forKey: .output)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct CommandEvent: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case started, completed, failed }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let command: String
    public let status: Status
    public let exitCode: Int?
}

public struct FileChangedEvent: Codable, Equatable, Sendable {
    public enum Change: String, Codable, Sendable { case created, modified, deleted }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let relativePath: String
    public let change: Change
}

public enum ApprovalAction: String, Codable, Sendable {
    case approveOnce = "approve_once"
    case approveSession = "approve_session"
    case reject
}

public struct ApprovalRequestedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let interactionId: String
    public let title: String
    public let description: String?
    public let command: String?
    public let actions: [ApprovalAction]
}

public struct QuestionOption: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, label, description }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        description = try decodeOptionalString(container, forKey: .description)
    }
}

public struct QuestionRequestedEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let interactionId: String
    public let question: String
    public let options: [QuestionOption]?
    public let allowFreeText: Bool
}

public struct StatusEvent: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, idle, waitingUser = "waiting_user" }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let status: Status
    public let message: String?
}

public struct ErrorEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let code: String
    public let message: String
    public let recoverable: Bool
}

public struct SessionCompletedEvent: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let outcome: Outcome
}

public struct TurnCompletedEvent: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let outcome: Outcome
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case sessionStarted(SessionStartedEvent)
    case textDelta(TextDeltaEvent)
    case message(MessageEvent)
    case toolStarted(ToolStartedEvent)
    case toolFinished(ToolFinishedEvent)
    case command(CommandEvent)
    case fileChanged(FileChangedEvent)
    case approvalRequested(ApprovalRequestedEvent)
    case questionRequested(QuestionRequestedEvent)
    case status(StatusEvent)
    case error(ErrorEvent)
    case turnCompleted(TurnCompletedEvent)
    case sessionCompleted(SessionCompletedEvent)

    private enum CodingKeys: String, CodingKey { case id, sessionId, sequence, timestamp, type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeNonEmptyString(container, forKey: .id)
        _ = try decodeNonEmptyString(container, forKey: .sessionId)
        let sequence = try container.decode(Int.self, forKey: .sequence)
        guard sequence >= 0 else { throw ProtocolDecodingError.invalidSequence(sequence) }
        let timestamp = try container.decode(String.self, forKey: .timestamp)
        guard isTimestamp(timestamp) else { throw ProtocolDecodingError.invalidTimestamp(timestamp) }
        switch try container.decode(String.self, forKey: .type) {
        case "session.started":
            try rejectExplicitNull(decoder, fields: ["nativeSessionId"])
            self = .sessionStarted(try SessionStartedEvent(from: decoder))
        case "text.delta": self = .textDelta(try TextDeltaEvent(from: decoder))
        case "message": self = .message(try MessageEvent(from: decoder))
        case "tool.started":
            try rejectExplicitNull(decoder, fields: ["title"])
            self = .toolStarted(try ToolStartedEvent(from: decoder))
        case "tool.finished":
            try rejectExplicitNull(decoder, fields: ["error"])
            self = .toolFinished(try ToolFinishedEvent(from: decoder))
        case "command":
            try rejectExplicitNull(decoder, fields: ["exitCode"])
            self = .command(try CommandEvent(from: decoder))
        case "file.changed": self = .fileChanged(try FileChangedEvent(from: decoder))
        case "approval.requested":
            try rejectExplicitNull(decoder, fields: ["description", "command"])
            let event = try ApprovalRequestedEvent(from: decoder)
            guard !event.actions.isEmpty else { throw ProtocolDecodingError.emptyActions }
            self = .approvalRequested(event)
        case "question.requested":
            try rejectExplicitNull(decoder, fields: ["options"])
            self = .questionRequested(try QuestionRequestedEvent(from: decoder))
        case "status":
            try rejectExplicitNull(decoder, fields: ["message"])
            self = .status(try StatusEvent(from: decoder))
        case "error": self = .error(try ErrorEvent(from: decoder))
        case "turn.completed": self = .turnCompleted(try TurnCompletedEvent(from: decoder))
        case "session.completed": self = .sessionCompleted(try SessionCompletedEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported AgentEvent type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .sessionStarted(event): try event.encode(to: encoder)
        case let .textDelta(event): try event.encode(to: encoder)
        case let .message(event): try event.encode(to: encoder)
        case let .toolStarted(event): try event.encode(to: encoder)
        case let .toolFinished(event): try event.encode(to: encoder)
        case let .command(event): try event.encode(to: encoder)
        case let .fileChanged(event): try event.encode(to: encoder)
        case let .approvalRequested(event): try event.encode(to: encoder)
        case let .questionRequested(event): try event.encode(to: encoder)
        case let .status(event): try event.encode(to: encoder)
        case let .error(event): try event.encode(to: encoder)
        case let .turnCompleted(event): try event.encode(to: encoder)
        case let .sessionCompleted(event): try event.encode(to: encoder)
        }
    }
}

public enum PendingInteraction: Codable, Equatable, Sendable {
    case approvalRequested(ApprovalRequestedEvent)
    case questionRequested(QuestionRequestedEvent)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "approval.requested":
            try rejectExplicitNull(decoder, fields: ["description", "command"])
            let event = try ApprovalRequestedEvent(from: decoder)
            guard !event.actions.isEmpty else { throw ProtocolDecodingError.emptyActions }
            self = .approvalRequested(event)
        case "question.requested":
            try rejectExplicitNull(decoder, fields: ["options"])
            self = .questionRequested(try QuestionRequestedEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Pending interaction must be an approval or question request"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .approvalRequested(event): try event.encode(to: encoder)
        case let .questionRequested(event): try event.encode(to: encoder)
        }
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let session: Session
    public let recentEvents: [AgentEvent]
    public let pendingInteractions: [PendingInteraction]
    public let latestSequence: Int
    public let currentStatus: SessionStatus

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case session, recentEvents, pendingInteractions, latestSequence, currentStatus
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(Session.self, forKey: .session)
        recentEvents = try container.decode([AgentEvent].self, forKey: .recentEvents)
        pendingInteractions = try container.decode([PendingInteraction].self, forKey: .pendingInteractions)
        latestSequence = try container.decode(Int.self, forKey: .latestSequence)
        guard latestSequence >= -1 else { throw ProtocolDecodingError.invalidSequence(latestSequence) }
        currentStatus = try container.decode(SessionStatus.self, forKey: .currentStatus)
    }
}

private enum ProtocolDecodingError: Error {
    case invalidSearchRequest
    case binaryDiff
    case emptyActions
    case emptyString(String)
    case explicitNull(String)
    case invalidMessageType(String)
    case negativeSize(Int)
    case invalidSequence(Int)
    case invalidTimestamp(String)
    case missingRenamedPath
    case nonGitRepositoryChanges
    case unknownFields([String])
    case unexpectedPreviousPath
}

private func requireNonEmpty(_ value: String, field: String) throws {
    if value.isEmpty { throw ProtocolDecodingError.emptyString(field) }
}

private func requireOptionalNonEmpty(_ value: String?, field: String) throws {
    if let value { try requireNonEmpty(value, field: field) }
}

private func decodeNonEmptyString<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> String {
    let value = try container.decode(String.self, forKey: key)
    try requireNonEmpty(value, field: key.stringValue)
    return value
}

private func decodeOptionalNonEmptyString<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> String? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw ProtocolDecodingError.explicitNull(key.stringValue)
    }
    return try decodeNonEmptyString(container, forKey: key)
}

private func decodeOptionalString<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> String? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw ProtocolDecodingError.explicitNull(key.stringValue)
    }
    return try container.decode(String.self, forKey: key)
}

private func decodeOptionalNonNull<Value: Decodable, Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> Value? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw ProtocolDecodingError.explicitNull(key.stringValue)
    }
    return try container.decode(Value.self, forKey: key)
}

private func decodeOptionalNonNegativeInt<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> Int? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw ProtocolDecodingError.explicitNull(key.stringValue)
    }
    let value = try container.decode(Int.self, forKey: key)
    guard value >= 0 else { throw ProtocolDecodingError.negativeSize(value) }
    return value
}

private func decodeOptionalJSONValue<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> JSONValue? {
    guard container.contains(key) else { return nil }
    return try container.decode(JSONValue.self, forKey: key)
}

private func rejectExplicitNull(_ decoder: Decoder, fields: [String]) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    for field in fields {
        guard let key = DynamicCodingKey(stringValue: field), container.contains(key) else { continue }
        if try container.decodeNil(forKey: key) { throw ProtocolDecodingError.explicitNull(field) }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Keys.Type
) throws where Keys.AllCases: Collection {
    let allowedNames = Set(Keys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowedNames.contains($0) }
    if !unknown.isEmpty { throw ProtocolDecodingError.unknownFields(unknown) }
}

private func isMessageType(_ value: String) -> Bool {
    value.range(
        of: #"^(system|pairing|project|file|session|agent|interaction)\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$"#,
        options: .regularExpression
    ) != nil
}

private func isTimestamp(_ value: String) -> Bool {
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
    let values = [
        Int(value.prefix(4)),
        Int(value.dropFirst(5).prefix(2)),
        Int(value.dropFirst(8).prefix(2)),
        Int(value.dropFirst(11).prefix(2)),
        Int(value.dropFirst(14).prefix(2)),
        Int(value.dropFirst(17).prefix(2)),
    ]
    guard values.allSatisfy({ $0 != nil }) else { return false }
    let year = values[0]!
    let month = values[1]!
    let day = values[2]!
    let hour = values[3]!
    let minute = values[4]!
    let second = values[5]!
    let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...12).contains(month)
        && (1...days[month - 1]).contains(day)
        && (0...23).contains(hour)
        && (0...59).contains(minute)
        && (0...59).contains(second)
}
