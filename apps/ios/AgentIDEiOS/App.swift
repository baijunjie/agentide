import SwiftUI

@main
struct AgentIDEiOSApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate
    @StateObject private var connection = MobileConnection()
    @StateObject private var notifications = PushNotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileHomeView()
                .environmentObject(connection)
                .environmentObject(notifications)
                .task {
                    notifications.configure()
                    consumeNotifications()
                }
                .onChange(of: notifications.deviceToken) { registerPushToken() }
                .onChange(of: notifications.preferences) { registerPushToken() }
                .onChange(of: connection.paired) { if connection.paired { registerPushToken() } }
                .onChange(of: notifications.deliveryRevision) { consumeNotifications() }
        }
            .onChange(of: scenePhase) {
                connection.handleScenePhase(scenePhase)
                if scenePhase == .active {
                    notifications.refreshAuthorizationStatus()
                    registerPushToken()
                }
            }
    }

    private func registerPushToken() {
        guard let token = notifications.deviceToken else { return }
        connection.registerPushToken(token, preferences: notifications.preferences)
    }

    private func consumeNotifications() {
        while let delivery = notifications.consumeDelivery() {
            connection.receiveNotification(delivery)
        }
    }
}
