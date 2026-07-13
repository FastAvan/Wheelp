import Foundation
import Supabase

/// Configuración del proyecto Supabase.
///
/// 👉 Sustituye estos dos valores por los de tu proyecto:
///    Supabase → Project Settings → API → "Project URL" y "anon public" key.
enum SupabaseConfig {
    static let url = URL(string: "https://olkvvidnnurjzwlgsuic.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9sa3Z2aWRubnVyanp3bGdzdWljIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0MzM1MTMsImV4cCI6MjA5ODAwOTUxM30.TsElQ5pL2Ld3CDj1rE-bZgsXJpQ6GPYW4lDf9sN3XP0"
}

/// Cliente compartido de Supabase para toda la app.
/// `emitLocalSessionAsInitialSession` adopta el comportamiento nuevo del SDK
/// (emitir la sesión local guardada al arrancar) y silencia su aviso en
/// ejecución; encaja con nuestro arranque instantáneo con `currentSession`.
let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey,
    options: SupabaseClientOptions(
        auth: SupabaseClientOptions.AuthOptions(
            emitLocalSessionAsInitialSession: true
        )
    )
)
