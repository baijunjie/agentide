import AgentIDEProtocol
import SwiftUI
import UIKit
import UserNotifications

struct NotificationDelivery: Equatable {
    let intent: NotificationIntent
    let opensSession: Bool
}

struct NotificationDeliveryQueue: Equatable {
    private(set) var values: [NotificationDelivery] = []

    mutating func append(_ delivery: NotificationDelivery) {
        values.append(delivery)
    }

    mutating func consume() -> NotificationDelivery? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

enum NotificationAuthorizationDecision {
    static func shouldRegister(for status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func registerIfAllowed(for status: UNAuthorizationStatus, using register: () -> Void) {
        guard shouldRegister(for: status) else { return }
        register()
    }
}

struct NotificationPreferencesStore {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "notificationPreferences") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> NotificationPreferences {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) }
            ?? NotificationPreferences()
    }

    func save(_ preferences: NotificationPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class PushRegistrationCoordinator {
    typealias Submit = (String, NotificationPreferences) async throws -> Void

    private let submit: Submit
    private var latest: (token: String, preferences: NotificationPreferences)?
    private var submissionTask: Task<Void, Never>?
    private var generation = 0
    private let failed: (Error) -> Void
    private let succeeded: () -> Void

    init(submit: @escaping Submit, failed: @escaping (Error) -> Void, succeeded: @escaping () -> Void = {}) {
        self.submit = submit
        self.failed = failed
        self.succeeded = succeeded
    }

    func update(token: String, preferences: NotificationPreferences) {
        latest = (token, preferences)
        startIfNeeded()
    }

    func retry() {
        startIfNeeded()
    }

    func reset() {
        generation += 1
        latest = nil
        submissionTask?.cancel()
        submissionTask = nil
    }

    private func startIfNeeded() {
        guard submissionTask == nil, latest != nil else { return }
        let taskGeneration = generation
        submissionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == taskGeneration { self.submissionTask = nil }
            }
            while self.generation == taskGeneration, let intended = self.latest, !Task.isCancelled {
                do {
                    try await self.submit(intended.token, intended.preferences)
                    guard self.generation == taskGeneration, !Task.isCancelled else { return }
                    if self.latest?.token == intended.token, self.latest?.preferences == intended.preferences {
                        self.latest = nil
                        self.succeeded()
                    }
                } catch {
                    guard self.generation == taskGeneration, !Task.isCancelled else { return }
                    self.failed(error)
                    return
                }
            }
        }
    }
}

@MainActor
final class PushNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var apnsRegistrationError: String?
    @Published private(set) var delivery: NotificationDelivery?
    @Published private(set) var deliveryRevision = 0
    @Published var preferences: NotificationPreferences {
        didSet {
            preferencesStore.save(preferences)
        }
    }
    private var injectedLaunchScenario = false
    private var deliveries = NotificationDeliveryQueue()
    private let preferencesStore: NotificationPreferencesStore

    init(preferencesStore: NotificationPreferencesStore = .init()) {
        self.preferencesStore = preferencesStore
        preferences = preferencesStore.load()
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
        injectLaunchScenarioIfPresent()
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let rawValue = settings.authorizationStatus.rawValue
            Task { @MainActor in
                let status = UNAuthorizationStatus(rawValue: rawValue) ?? .notDetermined
                self.authorizationStatus = status
                if NotificationAuthorizationDecision.shouldRegister(for: status) {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            refreshAuthorizationStatus()
            if NotificationAuthorizationDecision.shouldRegister(for: authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            refreshAuthorizationStatus()
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsRegistrationError = nil
    }

    func didFailRegistration(_ error: Error? = nil) {
        deviceToken = nil
        apnsRegistrationError = error?.localizedDescription ?? "Remote notification registration failed"
    }

    func retryRemoteRegistration(using register: () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        NotificationAuthorizationDecision.registerIfAllowed(for: authorizationStatus, using: register)
    }

    func consumeDelivery() -> NotificationDelivery? {
        let consumed = deliveries.consume()
        delivery = deliveries.values.first
        if consumed != nil { deliveryRevision += 1 }
        return consumed
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let delivery = Self.foregroundDelivery(from: notification.request.content.userInfo)
        Task { @MainActor in
            self.enqueue(delivery)
        }
        completionHandler(Self.foregroundPresentationOptions(for: notification.request.content.userInfo))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let intent = Self.intent(from: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let intent { self.enqueue(NotificationDelivery(intent: intent, opensSession: true)) }
        }
        completionHandler()
    }

    private func injectLaunchScenarioIfPresent() {
        #if DEBUG
        guard !injectedLaunchScenario else { return }
        guard let delivery = Self.launchScenario(from: ProcessInfo.processInfo.arguments) else { return }
        injectedLaunchScenario = true
        enqueue(delivery)
        #endif
    }

    private func enqueue(_ value: NotificationDelivery?) {
        guard let value else { return }
        deliveries.append(value)
        delivery = deliveries.values.first
        deliveryRevision += 1
    }

    nonisolated static func foregroundDelivery(from userInfo: [AnyHashable: Any]) -> NotificationDelivery? {
        intent(from: userInfo).map { NotificationDelivery(intent: $0, opensSession: false) }
    }

    // Foreground alerts would duplicate the in-app notice and interrupt the active task.
    nonisolated static func foregroundPresentationOptions(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        []
    }

    nonisolated static func launchScenario(from arguments: [String]) -> NotificationDelivery? {
        guard let argument = arguments.first(where: { $0.hasPrefix("--notification-scenario=") }),
              let category = NotificationCategory(rawValue: String(argument.dropFirst("--notification-scenario=".count))) else { return nil }
        return NotificationDelivery(intent: NotificationIntent(
            projectId: "project-demo",
            sessionId: "session-demo",
            sequence: 10,
            category: category,
            projectName: "Scenario Workspace",
            sessionTitle: "Scenario session",
            createdAt: "2026-09-28T00:00:00.000Z"
        ), opensSession: true)
    }

    private nonisolated static func intent(from userInfo: [AnyHashable: Any]) -> NotificationIntent? {
        guard let value = userInfo["agentide"] as? [String: Any],
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(NotificationIntent.self, from: data)
    }
}

@MainActor
final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The system can deliver a tapped notification before SwiftUI creates its scene.
        UNUserNotificationCenter.current().delegate = PushNotificationManager.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotificationManager.shared.didFailRegistration(error)
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var manager: PushNotificationManager
    @EnvironmentObject private var connection: MobileConnection
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("System Permission") {
                Text(statusText)
                if manager.authorizationStatus == .notDetermined {
                    Button("Allow Notifications") { Task { await manager.requestAuthorization() } }
                } else if manager.authorizationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            Section("Alerts") {
                Toggle("Notifications", isOn: enabled)
                Toggle("Waiting for me", isOn: waiting).disabled(!manager.preferences.enabled)
                Toggle("Task completion", isOn: completion).disabled(!manager.preferences.enabled)
            }
            if manager.apnsRegistrationError != nil || connection.notificationRegistrationError != nil {
                Section("Registration") {
                    if let error = manager.apnsRegistrationError {
                        Text("Apple Push Notification service: \(error)").foregroundStyle(.red)
                        Button("Retry Apple Registration") { manager.retryRemoteRegistration() }
                    }
                    if let error = connection.notificationRegistrationError {
                        Text("Relay: \(error)").foregroundStyle(.red)
                        Button("Retry Relay Registration") { connection.retryPushRegistration() }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
    }

    private var enabled: Binding<Bool> { preferenceBinding(\.enabled) }
    private var waiting: Binding<Bool> { preferenceBinding(\.waitingEnabled) }
    private var completion: Binding<Bool> { preferenceBinding(\.completionEnabled) }

    private func preferenceBinding(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { manager.preferences[keyPath: keyPath] },
            set: { value in
                var preferences = manager.preferences
                preferences[keyPath: keyPath] = value
                manager.preferences = preferences
            }
        )
    }

    private var statusText: String {
        switch manager.authorizationStatus {
        case .authorized: "Allowed"
        case .denied: "Disabled in Settings"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}
