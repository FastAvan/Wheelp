import Foundation
import os
import Supabase

/// Guarda y borra el token APNs del dispositivo en Supabase.
/// La tabla push_tokens tiene una fila por usuario (upsert por user_id).
enum PushTokenService {

    private static let log = Logger(subsystem: "fastavan.wheelp", category: "PushToken")

    static func save(_ token: String) async {
        guard let userId = try? await supabase.auth.session.user.id else {
            log.error("save: no hay sesión activa, token no guardado")
            return
        }
        struct Row: Encodable {
            let userId: UUID
            let token: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case token
            }
        }
        do {
            try await supabase
                .from("push_tokens")
                .upsert(Row(userId: userId, token: token), onConflict: "user_id")
                .execute()
        } catch {
            // Un fallo aquí significa que el usuario dejará de recibir notificaciones push.
            log.error("save fallido: \(error, privacy: .public)")
        }
    }

    /// Llámalo antes de cerrar sesión o eliminar la cuenta.
    static func delete() async {
        guard let userId = try? await supabase.auth.session.user.id else { return }
        do {
            try await supabase
                .from("push_tokens")
                .delete()
                .eq("user_id", value: userId)
                .execute()
        } catch {
            log.warning("delete fallido: \(error, privacy: .public)")
        }
    }
}
