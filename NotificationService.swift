import UserNotifications

/// Notificaciones locales: avisos inmediatos y citas programadas.
/// Sin cuenta de pago de Apple no hay push remoto (APNs), así que solo
/// se disparan mientras la app está en ejecución (inmediatas) o en background
/// si el sistema las mantiene programadas (UNCalendarNotificationTrigger).
enum NotificationService {

    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    private static let delegate = ForegroundDelegate()

    static func setUp() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Notificación inmediata (trigger nil = se muestra al instante).
    static func notify(title: String, body: String) {
        post(title: title, body: body, trigger: nil, id: UUID().uuidString)
    }

    /// Notificación programada para una fecha futura. `id` permite cancelarla.
    static func schedule(at date: Date, title: String, body: String, id: String) {
        guard date > Date() else { return }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        post(title: title, body: body, trigger: trigger, id: id)
    }

    /// Cancela notificaciones pendientes con ese identificador.
    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func post(title: String, body: String, trigger: UNNotificationTrigger?, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        )
    }
}
