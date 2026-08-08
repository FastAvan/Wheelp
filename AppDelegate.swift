import UIKit

/// AppDelegate mínimo: solo maneja el token APNs y los silent pushes en background.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// El sistema entrega el token APNs tras el registro exitoso.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await PushTokenService.save(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Wheelp] APNs: registro fallido — \(error.localizedDescription)")
    }

    /// Silent push recibido con la app en background o suspended.
    /// Devuelve .newData para que iOS no penalice el background budget.
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await ChatNotifier.shared.checkOnce()
        await AdminNotifier.shared.checkOnce()
        await HelpRequestNotifier.shared.checkOnce()
        return .newData
    }
}
