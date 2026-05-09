import Foundation
import UserNotifications

final class SystemNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationService()

    static var foregroundPresentationOptions: UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private let notificationCenter: UNUserNotificationCenter

    override private init() {
        self.notificationCenter = UNUserNotificationCenter.current()
        super.init()
        self.notificationCenter.delegate = self
    }

    func showCommandSuccessNotification() {
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureNotificationAuthorization() else { return }

            let content = UNMutableNotificationContent()
            content.title = "FluidVoice"
            content.body = "Command completed successfully."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "fluid.command.success.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await self.notificationCenter.add(request)
            } catch {
                DebugLogger.shared.error(
                    "Failed to post command success notification: \(error.localizedDescription)",
                    source: "SystemNotificationService"
                )
            }
        }
    }

    private func ensureNotificationAuthorization() async -> Bool {
        let settings = await self.notificationCenter.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true

        case .notDetermined:
            do {
                return try await self.notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                DebugLogger.shared.error(
                    "Failed to request notification authorization: \(error.localizedDescription)",
                    source: "SystemNotificationService"
                )
                return false
            }

        case .denied:
            DebugLogger.shared.debug(
                "Skipping command success notification because notifications are denied",
                source: "SystemNotificationService"
            )
            return false

        @unknown default:
            return false
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }
}
