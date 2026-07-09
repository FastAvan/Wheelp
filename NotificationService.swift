import UserNotifications

/// Notificaciones locales: avisan cuando aceptan tu petición o llega un mensaje.
/// Nota: sin cuenta de pago de Apple no hay push remoto (APNs), así que estas
/// notificaciones solo pueden dispararse mientras la app está en ejecución.
enum NotificationService {
    /// Delegado que permite mostrar el banner aunque la app esté en primer plano.
    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    private static let delegate = ForegroundDelegate()

    /// Configura el centro de notificaciones (llamar al arrancar la app).
    static func setUp() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Pide permiso la primera vez que hace falta.
    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Muestra una notificación inmediata.
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // inmediata
        )
        UNUserNotificationCenter.current().add(request)
    }
}
