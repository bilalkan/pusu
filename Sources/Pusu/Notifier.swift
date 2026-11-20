import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    override init() {
        super.init()
        center.delegate = self
    }

    /// İzin ilk gerçek bildirim anında istenir; uygulama açılışında değil.
    func send(title: String, body: String) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliver(title: title, body: body)
            case .notDetermined:
                self.requestAuthorization { granted in
                    if granted { self.deliver(title: title, body: body) }
                }
            case .denied:
                NSLog("Pusu notification skipped: permission denied")
            @unknown default:
                break
            }
        }
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Pusu notification authorization: \(error.localizedDescription)")
            }
            completion(granted)
        }
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Pusu notification error: \(error.localizedDescription)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
