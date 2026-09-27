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
    #expect(events.count == 19)

    for name in ["agent-event-invalid-sequence", "agent-event-invalid-approval"] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AgentEvent.self, from: fixture(named: name))
        }
    }
    for name in ["agent-report-events-invalid", "agent-report-events-runtime-invalid"] {
        let invalidReports = try JSONDecoder().decode(
            [[String: JSONValue]].self,
            from: fixture(named: name)
        )
        for invalidReport in invalidReports {
            let data = try JSONEncoder().encode(invalidReport)
            #expect(throws: (any Error).self) {
                _ = try decoder.decode(AgentEvent.self, from: data)
            }
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

@Test func unknownAndFutureReportsRoundTrip() throws {
    let events = try JSONDecoder().decode([AgentEvent].self, from: fixture(named: "agent-events"))
    for event in events.suffix(2) {
        guard case let .report(report) = event, case .unknown = report.payload else {
            Issue.record("Expected generic payload for unknown or future report")
            return
        }
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: encoded)
        #expect(decoded == event)
    }
}

@Test func reportIntegersAcceptTheJSONSafeUpperBound() throws {
    let reports = [
        #"{"id":"max-count","sessionId":"s1","sequence":1,"timestamp":"2026-09-22T00:00:00.000Z","type":"report","reportVersion":1,"reportId":"r1","kind":"test_report","title":"Tests","summary":"Max count","payload":{"total":9007199254740991,"passed":9007199254740991,"failed":0,"skipped":0,"failures":[]}}"#,
        #"{"id":"max-version","sessionId":"s1","sequence":2,"timestamp":"2026-09-22T00:00:00.000Z","type":"report","reportVersion":9007199254740991,"reportId":"r2","kind":"future","title":"Future","summary":"Max version","payload":{}}"#,
        #"{"id":"max-location","sessionId":"s1","sequence":3,"timestamp":"2026-09-22T00:00:00.000Z","type":"report","reportVersion":1,"reportId":"r3","kind":"diagnostics","title":"Diagnostics","summary":"Max location","payload":{"items":[{"severity":"error","message":"Bad","line":9007199254740991,"column":9007199254740991}]}}"#,
    ]

    for report in reports {
        _ = try JSONDecoder().decode(AgentEvent.self, from: Data(report.utf8))
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

@Test func gitChangesFixturesEnforceDTOBoundaries() throws {
    struct Fixtures: Decodable {
        let projectChangesResponse: ProjectChangesResponse
        let nonGitProjectChangesResponse: ProjectChangesResponse
        let projectDiffRequest: ProjectDiffRequest
        let projectDiffResponse: ProjectDiffResponse
        let binaryProjectDiffResponse: ProjectDiffResponse
    }

    let fixtures = try JSONDecoder().decode(Fixtures.self, from: fixture(named: "git-changes"))
    #expect(fixtures.projectChangesResponse.changes.map(\.kind) == [
        .added, .modified, .deleted, .renamed, .untracked,
    ])
    #expect(fixtures.projectChangesResponse.changes[3].previousRelativePath == "src/old-name.ts")
    #expect(fixtures.nonGitProjectChangesResponse.changes.isEmpty)
    #expect(fixtures.projectDiffRequest.area == .unstaged)
    #expect(fixtures.projectDiffResponse.diff != nil)
    #expect(fixtures.binaryProjectDiffResponse.diff == nil)

    let decoder = JSONDecoder()
    for name in [
        "git-changes-invalid-renamed-missing-previous-path",
        "git-changes-invalid-previous-path-on-modified",
        "git-changes-invalid-extra-field",
    ] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(GitChange.self, from: fixture(named: name))
        }
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(ProjectDiffResponse.self, from: fixture(named: "git-changes-invalid-binary-diff"))
    }
}

@Test func projectSearchFixturesEnforceDTOBoundaries() throws {
    struct Fixtures: Decodable {
        let projectSearchFilesRequest: ProjectSearchFilesRequest
        let projectCancelSearchRequest: ProjectCancelSearchRequest
        let projectSearchFilesResponse: ProjectSearchFilesResponse
    }

    let fixtures = try JSONDecoder().decode(Fixtures.self, from: fixture(named: "project-search"))
    #expect(fixtures.projectSearchFilesRequest.limit == 50)
    #expect(fixtures.projectCancelSearchRequest.searchId == "search-1")
    #expect(fixtures.projectSearchFilesResponse.results.first?.relativePath == "docs/README.md")

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(
            ProjectSearchFilesRequest.self,
            from: fixture(named: "project-search-invalid-limit")
        )
    }
    for name in ["project-search-invalid-query", "project-search-invalid-unicode-whitespace", "project-search-invalid-extra-field"] {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectSearchFilesRequest.self, from: fixture(named: name))
        }
    }
    for name in ["project-search-valid-feff", "project-search-valid-zero-width-space"] {
        _ = try JSONDecoder().decode(ProjectSearchFilesRequest.self, from: fixture(named: name))
    }
    for name in ["project-search-invalid-result-extra-field", "project-search-invalid-result-size", "project-search-invalid-result-null"] {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ProjectSearchFilesResponse.self, from: fixture(named: name))
        }
    }

    let oversizedResponse: [String: Any] = [
        "searchId": "search-1",
        "query": "readme",
        "results": Array(repeating: [
            "name": "README.md", "relativePath": "README.md", "type": "file"
        ], count: 101),
        "hasMore": true,
    ]
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(
            ProjectSearchFilesResponse.self,
            from: JSONSerialization.data(withJSONObject: oversizedResponse)
        )
    }
}

@Test func sessionSnapshotFixturePreservesAllPendingInteractions() throws {
    let decoder = JSONDecoder()
    let snapshot = try decoder.decode(SessionSnapshot.self, from: fixture(named: "session-snapshot"))

    #expect(snapshot.session.id == "session-1")
    #expect(snapshot.recentEvents.count == 3)
    #expect(snapshot.pendingInteractions.count == 2)
    #expect(snapshot.latestSequence == 9)
    #expect(snapshot.currentStatus == .waitingUser)

    guard case .approvalRequested = snapshot.pendingInteractions[0] else {
        Issue.record("Expected approval interaction")
        return
    }
    guard case .questionRequested = snapshot.pendingInteractions[1] else {
        Issue.record("Expected question interaction")
        return
    }

    for name in ["session-snapshot-invalid-pending", "session-snapshot-invalid-sequence"] {
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(SessionSnapshot.self, from: fixture(named: name))
        }
    }
}
