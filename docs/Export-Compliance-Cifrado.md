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

## Clasificación regulatoria (corregido por `wheelp-legal`, 2026-08-24)

- **ECCN 5D992.c** por autoclasificación mass-market, **§742.15(b)(1)**.
  No es License Exception ENC / 5D002 — eso era una suposición mía, errónea.
- Tipo de autorización a declarar en el report: **`MMKT`**.
- **No hace falta registro previo (ERN).** El ERN se eliminó del EAR en el rule
  de septiembre de 2016. Si lees "hay que registrarse antes de exportar" en
  cualquier sitio, está desactualizado.
- Única obligación recurrente: **Self Classification Report anual**, por email
  con CSV adjunto a `crypt-supp8@bis.doc.gov` y `enc@nsa.gov`.
  Primer plazo: **1 de febrero de 2027** (cubriendo exportaciones de 2026).
  → Lo prepara y presenta **`wheelp-legal`**, no ingeniería. Ingeniería solo
  aporta la tabla de algoritmos de arriba.

## Pendiente

| # | Qué | Quién | Cuándo |
|---|---|---|---|
| a | Localizar/generar el código de export compliance en App Store Connect | Álvaro | **bloquea el envío** |
| b | Meter ese código en `ITSEncryptionExportComplianceCode` (Info.plist) | ingeniería | en cuanto llegue de (a) |
| c | Self Classification Report a BIS + NSA (`MMKT`, 5D992.c) | `wheelp-legal` | 1 feb 2027, y cada año |

## Rechazo ITMS-90592 (build 78, 2026-08-24)

> The export compliance key value [] in the app's Info.plist doesn't match the
> key value of the app's export compliance documentation.

Causa: en App Store Connect **ya existe** documentación de export compliance
con un código asociado, y el Info.plist manda vacío (la key no está). Apple
compara los dos y rechaza. Dos salidas, en orden de preferencia:

1. **Si App Store Connect muestra un código** → copiarlo tal cual a
   `ITSEncryptionExportComplianceCode` en `Wheelp/Info.plist`. Una línea, fin.
2. **Si no hay ningún código porque en realidad no hay documentación subida**
   (que es lo esperable: con autoclasificación mass-market no hay CCATS) →
   borrar/reiniciar la documentación de export compliance en App Store Connect
   y responder el cuestionario por versión. Sin documentación, Apple no espera
   ningún código y el plist se queda como está.

El código no es secreto (Apple lo asocia públicamente a la app), así que se
puede comitear en el plist sin problema.

## Numeración de build (Xcode Cloud)

Xcode Cloud **ignora** `CURRENT_PROJECT_VERSION` del pbxproj y pone su propio
build number incremental (por eso el pbxproj dice 2 y Apple recibió el 78).
No hay que tocarlo a mano: subir ese número en el pbxproj no hace nada.

## Revisar esta nota si

Se añade cifrado nuevo, se quita el chat E2E, o se cambia el mercado objetivo
(Francia y algunos países exigen declaración propia además del EAR de EE.UU.).
