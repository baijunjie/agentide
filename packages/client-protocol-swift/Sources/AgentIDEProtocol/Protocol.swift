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

private enum ProtocolDecodingError: Error {
    case emptyActions
    case emptyString(String)
    case explicitNull(String)
    case invalidMessageType(String)
    case invalidSequence(Int)
    case invalidTimestamp(String)
    case unknownFields([String])
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
