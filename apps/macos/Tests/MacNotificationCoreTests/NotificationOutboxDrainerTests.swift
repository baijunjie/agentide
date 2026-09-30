import AgentIDEProtocol
@testable import MacNotificationCore
import XCTest

@MainActor
final class NotificationOutboxDrainerTests: XCTestCase {
    func testOnlyAccepted202AcknowledgesOutboxCursor() async throws {
        let page = makePage()

        for response in [
            NotificationDeliveryResponse(statusCode: 200, accepted: true),
            NotificationDeliveryResponse(statusCode: 202, accepted: false),
            NotificationDeliveryResponse(statusCode: 429, accepted: false),
            NotificationDeliveryResponse(statusCode: 503, accepted: false),
        ] {
            var acknowledgements: [Int] = []
            do {
                try await NotificationOutboxDrainer().drain(
                    page: page,
                    projectNames: ["project": "Project"],
                    submit: { _ in response },
                    acknowledge: { acknowledgements.append($0) }
                )
                XCTFail("Expected relay rejection for \(response)")
            } catch NotificationDrainError.relayDidNotAccept {
                XCTAssertTrue(acknowledgements.isEmpty)
            }
        }

        var acknowledgements: [Int] = []
        try await NotificationOutboxDrainer().drain(
            page: page,
            projectNames: ["project": "Project"],
            submit: { _ in NotificationDeliveryResponse(statusCode: 202, accepted: true) },
            acknowledge: { acknowledgements.append($0) }
        )
        XCTAssertEqual(acknowledgements, [7])
    }

    func testAcknowledgementFailureLeavesItemForNextDrain() async throws {
        let page = makePage()
        var submittedSequences: [Int] = []
        var acknowledgementAttempts = 0
        let drainer = NotificationOutboxDrainer()

        do {
            try await drainer.drain(
                page: page,
                projectNames: [:],
                submit: { intent in
                    submittedSequences.append(intent.sequence)
                    return NotificationDeliveryResponse(statusCode: 202, accepted: true)
                },
                acknowledge: { _ in
                    acknowledgementAttempts += 1
                    throw URLError(.networkConnectionLost)
                }
            )
            XCTFail("Expected acknowledgement failure")
        } catch {
            XCTAssertEqual(acknowledgementAttempts, 1)
        }

        var acknowledged: [Int] = []
        try await drainer.drain(
            page: page,
            projectNames: [:],
            submit: { intent in
                submittedSequences.append(intent.sequence)
                return NotificationDeliveryResponse(statusCode: 202, accepted: true)
            },
            acknowledge: { acknowledged.append($0) }
        )

        XCTAssertEqual(submittedSequences, [12, 12])
        XCTAssertEqual(acknowledged, [7])
    }

    func testUnicodeScalarTruncationKeepsTheOutboxDrainable() async throws {
        let oversized = String(repeating: "😀", count: 201)
        let page = NotificationOutboxPage(
            items: [
                NotificationOutboxItem(cursor: 7, projectId: "project", sessionId: "first", sequence: 12, category: .approvalWaiting, sessionTitle: oversized, createdAt: "2026-09-28T00:00:00.000Z"),
                NotificationOutboxItem(cursor: 8, projectId: "project", sessionId: "second", sequence: 13, category: .taskCompleted, sessionTitle: "Done", createdAt: "2026-09-28T00:00:01.000Z"),
            ], overflowed: false
        )
        var delivered: [NotificationIntent] = []
        var acknowledged: [Int] = []

        try await NotificationOutboxDrainer().drain(
            page: page,
            projectNames: ["project": oversized],
            submit: { intent in
                delivered.append(intent)
                return NotificationDeliveryResponse(statusCode: 202, accepted: true)
            },
            acknowledge: { acknowledged.append($0) }
        )

        XCTAssertEqual(delivered.map(\.sessionId), ["first", "second"])
        XCTAssertEqual(delivered.first?.projectName.unicodeScalars.count, 200)
        XCTAssertEqual(delivered.first?.sessionTitle.unicodeScalars.count, 200)
        XCTAssertEqual(acknowledged, [7, 8])
    }

    func testOverflowDiagnosticSurvivesDeliveryFailure() {
        var diagnostics = NotificationOutboxDiagnostics()
        diagnostics.record(page: .init(items: [], overflowed: true, droppedThroughCursor: 12))
        diagnostics.record(deliveryError: URLError(.cannotConnectToHost))

        XCTAssertEqual(diagnostics.overflow, "Notification outbox exceeded its retention limit and dropped items through cursor 12")
        XCTAssertEqual(diagnostics.deliveryError, URLError(.cannotConnectToHost).localizedDescription)
    }

    func testSuccessfulDrainOnlyClearsDeliveryError() {
        var diagnostics = NotificationOutboxDiagnostics()
        diagnostics.record(page: .init(items: [], overflowed: true, droppedThroughCursor: 12))
        diagnostics.record(deliveryError: URLError(.cannotConnectToHost))

        diagnostics.recordSuccessfulDrain()

        XCTAssertEqual(diagnostics.overflow, "Notification outbox exceeded its retention limit and dropped items through cursor 12")
        XCTAssertNil(diagnostics.deliveryError)
    }

    private func makePage() -> NotificationOutboxPage {
        NotificationOutboxPage(
            items: [
                NotificationOutboxItem(
                    cursor: 7,
                    projectId: "project",
                    sessionId: "session",
                    sequence: 12,
                    category: .approvalWaiting,
                    sessionTitle: "Review",
                    createdAt: "2026-09-28T00:00:00.000Z"
                ),
            ],
            overflowed: false
        )
    }
}
