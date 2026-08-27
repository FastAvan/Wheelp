# Wheelp iOS App — Contexto para el programador

> Pega este documento al inicio de una nueva conversación para retomar el trabajo sin perder contexto.

---

## Rol

Eres el programador principal de la app iOS de Wheelp. Haces los cambios en el código, commiteas y haces push a `git@github.com:FastAvan/Wheelp.git` (rama `main`). No uses Xcode como herramienta de desarrollo — todo desde Claude Code.

---

## El proyecto

**Ruta local:** `/Users/alvaroelguer/Desktop/App Wheelp/`

App iOS en SwiftUI + `@Observable`. Plataforma de accesibilidad para personas con discapacidad física, visual o auditiva (adultos, sin menores). Conecta usuarios con "ayudantes" cualificados en España.

**Stack:**
- SwiftUI + `@Observable`
- Supabase Swift SDK
- Supabase project: `olkvvidnnurjzwlgsuic` (EU west-1, Postgres 17)
- Edge Functions en Deno/TypeScript
- APNs push via Edge Function `send-push`
- Google Places API (New) + Google Routes API v2 — accedidas exclusivamente desde servidor

---

## Regla de seguridad — NO NEGOCIABLE

**Nunca** poner API keys, secrets ni credenciales en el código Swift, Info.plist ni en el historial de git. Todo secret vive exclusivamente en los secrets de Supabase Edge Functions. La clave de Google está en `GOOGLE_PLACES_API_KEY` (secret de Supabase).

> Antecedente: en julio 2026 la clave de Google estaba hardcodeada en el repo público. Se rotó, se purgó el historial con `git-filter-repo` y se migró a Edge Function secrets.

---

## Supabase

| Dato | Valor |
|---|---|
| Project ID | `olkvvidnnurjzwlgsuic` |
| URL | `https://olkvvidnnurjzwlgsuic.supabase.co` |
| Anon key | en `SupabaseManager.swift` (pública por diseño) |
| Admin email | `aelguer@icloud.com` |

### Edge Functions desplegadas

| Función | Qué hace |
|---|---|
| `google-places` | Proxy a Google Places API (New). Exige JWT de usuario real (no solo anon key). Valida input, timeout 8s. |
| `google-routes` | Proxy a Google Routes API v2 (tránsito). Mismo patrón que google-places. |
| `send-push` | Envía push via APNs. Switch sandbox/producción por secret `APNS_ENVIRONMENT`. |
| `notify-admin-on-application` | Notifica al admin cuando llega una solicitud de ayudante. |

### Storage

Bucket `helper-avatars` (public read, auth-scoped write):
- `public_read_avatars` — SELECT, público
- `update_own_avatar` — UPDATE, auth
- `upload_own_avatar` — INSERT, auth

Los avatares se suben como JPEG al path `{userId}/avatar.jpg` (upsert habilitado). Solo se guarda la URL pública HTTPS en `helpers.avatar_url`. No se usan data URIs.

### RLS — estado actual tras el audit

| Tabla | Políticas activas |
|---|---|
| `help_requests` | `select_own_or_helper`, `update_own_or_helper`, `insert_own` |
| `profiles` | SELECT `auth.uid()::text = id`, INSERT `auth.uid()::text = id` |
| `helper_applications` | `actualizar_solicitud` (solo status=pending→pending), lectura y creación propias |
| `helpers` | lectura/escritura propias + `update_own_avatar` para Storage |

**Importante sobre RLS PERMISSIVE:** cuando hay varias políticas PERMISSIVE para el mismo comando, Postgres las hace OR — una política abierta invalida a las restrictivas. Antes del audit había políticas `qual=true` que abrían tablas enteras.

### Funciones SECURITY DEFINER

`admin_approve_helper` y `admin_reject_helper` verifican `auth.email() = 'aelguer@icloud.com'` en servidor. El chequeo en `AppState.swift` es solo de UI (mostrar/ocultar sección de admin), no la autorización real.

---

## Archivos clave

| Archivo | Qué contiene |
|---|---|
| `SupabaseManager.swift` | URL y anon key de Supabase |
| `HelperService.swift` | CRUD de helpers, incluyendo `uploadAvatar()` (Storage) |
| `HelperAvatarView.swift` | Muestra avatar; soporta data URIs Y URLs HTTP vía `AsyncImage` |
| `AppState.swift:145,167,202` | Chequeo de admin (solo UI) |
| `SettingsView.swift:265` | Vista de admin |
| `supabase/functions/google-places/index.ts` | Edge Function Google Places |
| `supabase/functions/google-routes/index.ts` | Edge Function Google Routes |
| `docs/security-audits/` | Documentos de audit por fecha (`AA_MM_DD.md`) |
| `docs/APP_ENGINEERING_PRINCIPLES.md` | Principios de ingeniería del proyecto |

### `uploadAvatar()` — implementación actual

```swift
static func uploadAvatar(_ imageData: Data) async -> String? {
    guard let userId = try? await supabase.auth.session.user.id else { return nil }
    let storagePath = "\(userId)/avatar.jpg"
    do {
        try await supabase.storage
            .from("helper-avatars")
            .upload(storagePath, data: imageData, options: FileOptions(contentType: "image/jpeg", upsert: true))
        let publicURL = try supabase.storage
            .from("helper-avatars")
            .getPublicURL(path: storagePath)
        let urlString = publicURL.absoluteString
        struct Row: Decodable {
            let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        let updated: [Row] = try await supabase
            .from("helpers")
            .update(["avatar_url": urlString])
            .eq("user_id", value: userId)
            .select("user_id")
            .execute()
            .value
        guard !updated.isEmpty else { return nil }
        return urlString
    } catch { return nil }
}
```

SDK path (solo referencia): `/Users/alvaroelguer/Library/Developer/Xcode/DerivedData/Wheelp-*/SourcePackages/checkouts/supabase-swift/Sources/Storage/StorageFileApi.swift`

---

## Rutina de seguridad semanal

- **RemoteTrigger:** `trig_01PQrp1qLWTYFsbVxJwBbWoP`, cron lunes 7:00 UTC
- La rutina solo genera un informe (modo READ-ONLY — su GitHub App solo tiene lectura)
- El informe llega por Apple Mail o directamente en `docs/security-audits/`
- Yo (el programador) aplico los cambios confirmados, guardo el doc como `docs/security-audits/AA_MM_DD.md`, commiteo y hago push

### Audits completados

| Fecha | Doc | Hallazgos |
|---|---|---|
| 2026-08-22 | `docs/security-audits/2026-08-22.md` | 1 (Edge Function auth), 2 (falso positivo) |
| 2026-08-23 | `docs/security-audits/26_08_23.md` | 3–6 (RLS fixes), 7–8 (anotados), 9 (avatares Storage) |

Próximo audit: **lunes 2026-08-31 a las 7:00 UTC**.

---

## Git

```
remote: git@github.com:FastAvan/Wheelp.git
rama: main
último commit aplicado: 02d1121 — "security: migrar avatares de base64 a Supabase Storage (Hallazgo 9)"
```

Antes de cualquier commit: revisar que no haya secrets en los archivos staged.

---

## Pendiente (sin fecha)

- Hallazgo 7: suite de tests / CI
- Hallazgo 8: directorio `supabase/migrations/` para versionar cambios de esquema/RLS

### Simulador local roto en el Mac de Álvaro (2026-08-27)

**Síntoma:** `xcrun simctl list` (cualquier subcomando) se cuelga indefinidamente.
No lo arregla `killall -9 com.apple.CoreSimulator.CoreSimulatorService` — se
recupera el servicio pero se vuelve a colgar.

**Causa:** el runtime de iOS 27 está montado pero NO registrado.
`~/Library/Logs/CoreSimulator/CoreSimulator.log` repite:

```
Unable to discover any Simulator runtimes.
Developer Directory is /Applications/Xcode-beta.app/Contents/Developer
```

- Único Xcode instalado: `/Applications/Xcode-beta.app` (27.0).
- `/Library/Developer/CoreSimulator/Profiles/Runtimes/` vacío.
- Pero `/dev/disk7s1` sí montado en
  `/Library/Developer/CoreSimulator/Volumes/iOS_24A5370g`.

Probablemente se corrompió el registro cuando se llenó el disco esa mañana.

**Arreglo (NO hacerlo con el disco justo):** reinstalar el runtime desde
Xcode > Settings > Components. Son 7–10 GB de descarga, así que hace falta
**más de 10 GB libres** antes de empezar. Desmontar la imagen actual sin
espacio para redescargarla deja el Mac peor que ahora.

**Mientras tanto:** los tests se corren en el CI de GitHub Actions
(`.github/workflows/ci.yml`, runner `macos-26`), que sí tiene simulador.
Ojo: el CI solo se dispara en push a `main` o PR contra `main` — empujar
una rama suelta no lo lanza.
