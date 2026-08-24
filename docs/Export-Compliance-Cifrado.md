# Export compliance / cifrado — qué contestar al subir un build

Apple pregunta esto en **cada** subida a TestFlight/App Store ("App Encryption
Documentation"). Esta nota fija la respuesta para no re-analizarlo cada vez.

## Qué cifrado usa Wheelp (verificado en código, 2026-08-24)

| Dónde | Algoritmo | Para qué |
|---|---|---|
| `HelpCrypto.swift` | Curve25519 / X25519 (RFC 7748) | acuerdo de claves efímero por petición |
| `HelpCrypto.swift` | HKDF-SHA256 (RFC 5869) | derivar la clave simétrica compartida |
| `HelpCrypto.swift` | AES-GCM (NIST SP 800-38D) | cifrar nombres, trayecto exacto y **mensajes del chat** |
| `HelpCrypto.swift` | HMAC-SHA256 (RFC 2104) | código de encuentro de 6 dígitos |
| `LoginView.swift:449` | SHA-256 | hash del nonce de Sign in with Apple (solo autenticación) |
| Supabase / Didit SDK | TLS del sistema | transporte; no es cifrado propio |

Todos son estándares internacionales publicados. **Nada propietario.** Claves
privadas en el Llavero (`kSecClassGenericPassword`, service `wheelp.help-key`);
`pendingDetails` se guarda en `UserDefaults` **en claro** (local, borrado en
`forget(requestId:)`) — no cuenta como cifrado a efectos de esta pregunta.

## Respuesta en el diálogo de Xcode

**Opción 2** — "Standard encryption algorithms instead of, or in addition to,
using or accessing the encryption within Apple's operating system".

Por qué no las otras:
- Opción 1 (propietario/no estándar): falso. Viene marcada por defecto; hay que cambiarla.
- Opción 3: incluiría la 1, falso.
- Opción 4: solo valdría si el único cifrado fuera el del SO (TLS). `HelpCrypto`
  es cifrado E2E implementado en la app, sobre datos reales de usuario.

## Decisión tomada (2026-08-24)

- Diálogo de Xcode: **opción 2**.
- Exención de la Nota 4 (Cat. 5 Parte 2 EAR): **NO**. Wheelp **no está exenta**.

Motivo: la Nota 4 exige que la función primaria del producto no sea seguridad
de la información *ni* "enviar, recibir o almacenar información". Wheelp tiene
**chat E2E entre solicitante y ayudante** (`HelpChatView` / `HelperService`),
que es justo el caso que BIS excluye de la Nota 4.

`Wheelp/Info.plist` ya lleva `ITSAppUsesNonExemptEncryption = YES`, así que
Xcode deja de preguntar en cada subida.

## Pendiente

| # | Qué | Quién | Cuándo |
|---|---|---|---|
| a | Subir la documentación de export compliance en App Store Connect | Álvaro | antes de distribuir el build |
| b | Meter el código que devuelva Apple en `ITSEncryptionExportComplianceCode` (Info.plist) | ingeniería | en cuanto llegue de (a) |
| c | **Self Classification Report ante BIS y NSA** | `wheelp-legal` | antes del **1 de febrero**, y **cada año** mientras la app tenga chat E2E |

(b) no está en el plist todavía — sin él Apple vuelve a pedir la documentación
en cada envío nuevo, aunque el build sí se acepta.

### Sobre (c) — esto es un trámite legal, no documentación técnica

Sin exención, la vía es la clasificación mass-market **740.17(b)(1)**: registro
ERN + informe anual de autoclasificación ante BIS y NSA. Es un filing
regulatorio con obligaciones recurrentes y consecuencias por incumplimiento.

→ **Lo lleva o lo supervisa `wheelp-legal`.** Ingeniería aporta el material
técnico (esta tabla de algoritmos, la descripción funcional de la app, este
documento); el filing y su seguimiento anual no los hace ingeniería sola.

## Revisar esta nota si

Se añade cifrado nuevo, se quita el chat E2E, o se cambia el mercado objetivo
(Francia y algunos países exigen declaración propia además del EAR de EE.UU.).
