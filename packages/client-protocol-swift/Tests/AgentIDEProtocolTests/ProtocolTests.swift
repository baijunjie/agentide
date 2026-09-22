import Foundation
import Testing
@testable import AgentIDEProtocol

@Test func envelopeRoundTrip() throws {
    let envelope = try Envelope(
        id: "request-1",
        type: MessageType("project.list"),
        sourceDeviceId: "iphone-1",
        timestamp: "2026-09-22T00:00:00.000Z",
        payload: .clear(EmptyPayload())
    )

    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(Envelope<EmptyPayload>.self, from: data)

    #expect(decoded.version == .v1)
    #expect(decoded.type.rawValue == "project.list")
}

@Test func sharedEnvelopeFixturesEnforceTheSwiftBoundary() throws {
    let decoder = JSONDecoder()
    let validRequest = try fixture(named: "valid-request")
    let validResponse = try fixture(named: "valid-response-no-payload")

    _ = try decoder.decode(Envelope<EmptyPayload>.self, from: validRequest)
    let response = try decoder.decode(ResponseEnvelope<EmptyPayload>.self, from: validResponse)
    #expect(response.payload == nil)
    #expect(response.replyTo == "request-1")

    for name in [
        "invalid-empty-id",
        "invalid-extra-field",
        "invalid-offset-timestamp",
        "invalid-version",
        "invalid-type",
        "invalid-timestamp",
    ] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(Envelope<EmptyPayload>.self, from: fixture(named: name))
        }
    }

    #expect(throws: (any Error).self) {
        _ = try decoder.decode(
            Envelope<EmptyPayload>.self,
            from: fixture(named: "invalid-encrypted-payload")
        )
    }

    for name in [
        "invalid-response-empty-error",
        "invalid-response-error-extra",
        "invalid-response-null-error",
        "invalid-response-null-target",
    ] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ResponseEnvelope<EmptyPayload>.self, from: fixture(named: name))
        }
    }
}

private func fixture(named name: String) throws -> Data {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = testDirectory
        .appending(path: "../../../protocol/fixtures")
        .appending(path: "\(name).json")
        .standardizedFileURL
    return try Data(contentsOf: url)
}

@Test func agentEventUsesUnifiedDiscriminator() throws {
    let data = Data(
        #"{"id":"event-1","sessionId":"session-1","sequence":3,"timestamp":"2026-09-22T00:00:00.000Z","type":"message","role":"agent","content":"Done","format":"markdown"}"#.utf8
    )

    let event = try JSONDecoder().decode(AgentEvent.self, from: data)
    guard case let .message(message) = event else {
        Issue.record("Expected a message event")
        return
    }

    #expect(message.sequence == 3)
    #expect(message.format == .markdown)
}

@Test func sharedAgentEventFixturesCoverEveryDiscriminator() throws {
    let decoder = JSONDecoder()
    let events = try decoder.decode([AgentEvent].self, from: fixture(named: "agent-events"))
    #expect(events.count == 12)

    for name in ["agent-event-invalid-sequence", "agent-event-invalid-approval"] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AgentEvent.self, from: fixture(named: name))
        }
    }

    for name in ["agent-event-invalid-enum-types", "agent-event-invalid-option-extra"] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AgentEvent.self, from: fixture(named: name))
        }
    }
    let nullEvents = try JSONSerialization.jsonObject(
        with: fixture(named: "agent-events-invalid-null")
    ) as! [[String: Any]]
    for event in nullEvents {
        let data = try JSONSerialization.data(withJSONObject: event)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AgentEvent.self, from: data)
        }
    }
}

@Test func responsePreservesExplicitNullPayload() throws {
    let decoder = JSONDecoder()
    let response = try decoder.decode(
        ResponseEnvelope<JSONValue>.self,
        from: fixture(named: "valid-response-null-payload")
    )
    guard case .clear(.null) = response.payload else {
        Issue.record("Expected an explicit clear null payload")
        return
    }

    let encoded = try JSONEncoder().encode(response)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    #expect(object["payload"] is NSNull)
}

@Test func unknownPayloadFieldsPreserveExplicitNull() throws {
    let decoder = JSONDecoder()
    let events = try decoder.decode(
        [AgentEvent].self,
        from: fixture(named: "agent-events-null-unknown")
    )
    for event in events {
        let encoded = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(object["input"] is NSNull || object["output"] is NSNull)
    }

    let response = try decoder.decode(
        ResponseEnvelope<JSONValue>.self,
        from: fixture(named: "valid-response-null-error-details")
    )
    let encoded = try JSONEncoder().encode(response)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let error = object["error"] as! [String: Any]
    #expect(error["details"] is NSNull)
}

@Test func sharedModelFixtureDecodesStableDTOs() throws {
    struct Models: Decodable {
        let project: Project
        let session: Session
        let fileEntry: FileEntry
    }

    let models = try JSONDecoder().decode(Models.self, from: fixture(named: "shared-types"))
    #expect(models.project.enabledAgents == [.codex, .claude])
    #expect(models.session.status == .waitingUser)
    #expect(models.fileEntry.type == .file)
}
