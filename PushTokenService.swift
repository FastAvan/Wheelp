import Foundation
import Supabase

/// Guarda y borra el token APNs del dispositivo en Supabase.
/// La tabla push_tokens tiene una fila por usuario (upsert por user_id).
enum PushTokenService {

    static func save(_ token: String) async {
        guard let userId = try? await supabase.auth.session.user.id else { return }
        struct Row: Encodable {
            let userId: UUID
            let token: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case token
            }
        }
        _ = try? await supabase
            .from("push_tokens")
            .upsert(Row(userId: userId, token: token), onConflict: "user_id")
            .execute()
    }

    /// Llámalo antes de cerrar sesión o eliminar la cuenta.
    static func delete() async {
        guard let userId = try? await supabase.auth.session.user.id else { return }
        _ = try? await supabase
            .from("push_tokens")
            .delete()
            .eq("user_id", value: userId)
            .execute()
    }
}
