# Briefing de contexto de Wheelp

Fuente: CCO de Wheelp. Fecha de verificación: 2026-09-06.
Destinatario: "Agents Orchestrator", para inyectar contexto real en los 36 agentes genéricos de `.claude/agents/`.

**Cómo usar este documento.** Todo lo marcado como VERIFICADO se ha comprobado contra el código del repo `App Wheelp` o contra la base de datos de producción en Supabase (proyecto `olkvvidnnurjzwlgsuic`, región `eu-west-1`, Postgres 17.6) en la fecha de arriba. Lo marcado NO CONFIRMADO no debe usarse como hecho ni sustituirse por una cifra plausible. Ningún agente debe inventar métricas de negocio, de mercado o financieras.

**Regla transversal para todos los agentes:** antes de escribir cualquier texto de producto, legal o de marketing que describa lo que la app hace, verificar contra el código o el esquema real. Ya hemos publicado dos veces afirmaciones falsas por asumir en vez de comprobar (criterios de accesibilidad inexistentes, y discrepancias entre la política de privacidad y los datos realmente tratados).

---

## 1. Producto

- Wheelp es una app iOS de accesibilidad en **España**, para **personas adultas** con discapacidad **física, visual o auditiva**. **Sin menores.** No lanzada todavía.
- Mercado de dos lados: personas que necesitan ayuda + **"ayudantes"** (marketplace con comisión, profesionales cualificados, alcance de acompañamiento/guía). El emparejamiento solo funciona si oferta y demanda coinciden en la misma provincia.
- **Estado real en producción (VERIFICADO en Supabase, 2026-09-06):**
  - `profiles`: **1**
  - `helpers`: **1**
  - `helper_applications`: **0** (aprobadas: 0)
  - `help_requests`: **0** — la demanda real es cero
  - `accessibility_reports`: **4**
  - `website_waitlist`: **0**
  - `helper_ratings`: 1 · `help_messages`: 0 · `admins`: 1
  - Consecuencia estratégica: **primero se capta oferta (ayudantes), después demanda.** Captar usuarios antes que ayudantes produce peticiones sin respuesta, que es el peor primer contacto posible con un usuario vulnerable.
- **Funciones principales** (todas presentes en el código): rutas accesibles y mapa (`MapHomeView.swift`, `RouteObstaclesService.swift`), fichas de accesibilidad de sitios con datos de **Google Places** (`GooglePlacesAccessibilityService.swift`) y **OpenStreetMap** (`OSMAccessibilityService.swift`), aportaciones de la comunidad (`ContributeAccessibilityView.swift`), navegación en **transporte público** (`TransitRoutingService.swift`), petición de ayuda y chat **cifrado de extremo a extremo** con el ayudante (`HelpCrypto.swift`, `HelpChatView.swift`), SOS (`SOSView.swift`), anuncios por voz y reconocimiento de voz (`SpeechAnnouncer.swift`, `SpeechRecognizer.swift`).
- **Fuente oficial de datos de accesibilidad:** los informes con `source = "once"` se muestran como **Fundación ONCE** y tienen prioridad sobre la comunidad, que a su vez tiene prioridad sobre la fuente externa (Google/OSM). Orden implementado en `DestinationAccessibility.combined(...)`.

### 1.1 Criterios de accesibilidad REALES (VERIFICADO en `DestinationAccessibility.swift`, `criteria(for:)`)

Ningún agente debe nombrar criterios distintos a estos. Ya publicamos una vez "ancho de puerta", que **no existe**.

| Perfil | Criterios exactos (texto literal en la app) |
|---|---|
| Física (`.physical`) | Entrada sin escalones · Ascensor · Aseo adaptado · Aparcamiento accesible |
| Visual (`.visual`) | Señalización en braille · Pavimento podotáctil · Audioguía · Admite perro guía |
| Auditiva (`.hearing`) | Bucle magnético · Avisos visuales · Subtítulos / pantallas · Atención por texto |
| Sin perfil (`.none`) | Acceso general · Aseos · Aparcamiento |

Estados posibles por criterio: disponible / limitado / no disponible / desconocido. La puntuación del sitio es `disponibles / total * 100` sobre los criterios del perfil activo — no es una nota general, es relativa al perfil del usuario.

---

## 2. Ingeniería y stack

- **App:** SwiftUI + Swift, iOS 17+. Repo `FastAvan/Wheelp` en GitHub — **PÚBLICO**. Todo lo que se escriba en el repo es visible por cualquiera.
- **Backend:** Supabase — Postgres, **RLS como mecanismo de autorización principal**, y Edge Functions en Deno: `admin-actions`, `google-places`, `google-routes`, `notify-admin-on-application`, `send-push` (VERIFICADO en `supabase/functions/`).
- **Verificación de identidad de ayudantes:** SDK de **Didit** en el dispositivo. El DNI/NIE y la prueba de vida **van directos a Didit**; Wheelp solo guarda `helper_applications.kyc_session_id`. Ningún documento de identidad se almacena en servidores de Wheelp (art. 25 RGPD). VERIFICADO en `HelperApplicationView.swift` y `docs/Inventario-de-datos.md`.
- **Regla de secretos, no negociable:** NUNCA secretos, claves, certificados ni credenciales en código Swift, en `Info.plist` ni en el historial de git. Todo secreto vive en los secrets de Edge Functions de Supabase o en los secrets de GitHub Actions. Nada de `.p12`, certificados ni claves privadas en el repo, ni siquiera como secreto.
- **CI/CD** (VERIFICADO en `.github/workflows/ci.yml`), tres puertas:
  1. macOS: `xcodebuild build` + suite `WheelpTests` + validación del protocolo de cifrado (`swift scripts/validate.swift`), con Xcode 26.3.
  2. Ubuntu: suite de autorización contra **Postgres real** — `psql -v ON_ERROR_STOP=1 -f supabase/tests/rls.sql`, que verifica políticas RLS, triggers y funciones SECURITY DEFINER.
  3. Despliegue automático a **TestFlight** en cada push a `main` que pase **ambas** puertas (`needs:` no es decoración). Sin certificados guardados como secretos: la clave de API de App Store Connect tiene rol Admin y se usan los certificados gestionados por Apple; los certificados desechables de runs anteriores se revocan y la clave se borra al final del job.
- **Verificación de cambios:** por CI, **nunca por simulador local** — el simulador se cuelga en esta máquina. Para probar en dispositivo, TestFlight.
- **Web:** repo separado `FastAvan/wheelp-web`, GitHub Pages, dominio **wheelp.app**. (NO CONFIRMADO en esta pasada: no hay copia local del repo web en `~/Developer`, así que su contenido no se ha podido verificar hoy.)
- Documentación interna útil en `docs/`: `APP_ENGINEERING_PRINCIPLES.md`, `Inventario-de-datos.md`, `Export-Compliance-Cifrado.md`, `Supabase-Ayudantes.md`, `Supabase-Ayudantes-Cifrado.md`, `Supabase-Accesibilidad.md`, `Terminos-y-Condiciones-App-BORRADOR.md`, `security-audits/`.

### 2.1 Esquema real (VERIFICADO, schema `public`)

Tablas: `profiles`, `helpers`, `helper_applications`, `helper_ratings`, `help_requests`, `help_messages`, `accessibility_reports`, `admins`, `admin_audit_log`, `api_rate_limits`, `push_tokens`, `website_waitlist`.

Detalles que suelen malinterpretarse:
- `profiles` = id, username, first_name, last_name, email, created_at, onboarding_completed. **No hay `disability_type`** (eliminado, ver §3).
- `help_requests` sí tiene `disability_type` (por petición, no por perfil), `area_latitude`/`area_longitude` (zona aproximada), `place_name`, `requester_pubkey`/`helper_pubkey`, `requester_payload`/`helper_payload` (texto cifrado), `status`, `scheduled_at`, `search_radius_km`.
- `helpers` tiene `available` + `available_until` (turno), `latitude`/`longitude`/`location`/`location_updated_at`. **No existe una columna `verified`** — la verificación se refleja vía `helper_applications`/alta en `helpers`, no en un booleano de `helpers`.
- `website_waitlist` = email, audience, province, created_at.

Funciones (VERIFICADO en `pg_proc`). SECURITY DEFINER: `aceptar_peticion`, `admin_approve_helper`, `admin_reject_helper`, `check_rate_limit`, `delete_own_account`, `helper_rating_summary`, `is_admin`, `is_requester_of_helper`, `nearby_pending_requests`, `purgar_datos_caducados`, `rls_auto_enable`, `wheelp_send_push`. Triggers/normales: `limitar_turno_disponibilidad`, `nearby_helper_ids`, `peticion_inmutable`, `prevent_helper_id_hijack`, `prevent_stale_accept`, `touch_helper_location`, `touch_push_token`.

---

## 3. Seguridad y privacidad técnica — decisiones cerradas (no reabrir sin motivo nuevo)

Todo esto está implementado y probado. Un agente que proponga "buenas prácticas genéricas" contra estas decisiones está retrocediendo.

- **Identidad de admin:** tabla `admins` + función `is_admin()` SECURITY DEFINER. **Nunca** un email a fuego en el código — hubo un fallo así, ya corregido (migración `20260904000000_admins_y_registro_de_auditoria.sql`).
- **`admin_audit_log`:** tabla de solo inserción. Ni el propio admin puede borrar su rastro.
- **Aceptar una petición es un RPC SECURITY DEFINER (`aceptar_peticion`)**, no un `UPDATE` directo (migración `20260904100000_aceptar_peticion_por_rpc.sql`). Motivo: Postgres exige también política de SELECT para poder ejecutar `UPDATE ... WHERE`, y un ayudante no puede leer una petición que todavía no ha aceptado. Regresión real: durante un día entero **nadie pudo aceptar peticiones en producción, sin ningún error visible**.
- **Revocar `EXECUTE` de una función usada dentro de una expresión RLS ROMPE la política**, aunque la función sea SECURITY DEFINER. Verificado en producción. Contradice la recomendación genérica de "revocar EXECUTE a `authenticated` por defecto".
- **Precisión de ubicación diferenciada por uso** (VERIFICADO en `HelperService.swift`, `AppState.swift`, `HelpCrypto.swift`):
  - Navegación del usuario: exacta, **nunca sale del dispositivo**.
  - Punto de encuentro tras aceptar: exacto pero **cifrado E2E**.
  - Zona de la petición antes de aceptar: **~1 km**, publicada en rejilla aproximada.
  - Zona del ayudante mientras tiene turno: **~2 km** (proporcionalidad, art. 5.1.c RGPD).
- **Cifrado E2E:** par de claves efímeras Curve25519 por petición; al aceptar, ambos dispositivos derivan la clave con X25519 + HKDF, y cifran nombres, trayecto exacto y mensajes con AES-GCM. Las claves privadas viven en el Llavero del dispositivo y se borran al terminar. **El servidor solo ve claves públicas, zona aproximada, destino y texto cifrado.**
- **Turnos de ayudante:** el usuario elige 2/4/8 h; el **tope de 8 h se impone en el servidor** mediante el trigger `limitar_turno_disponibilidad` (una app modificada no puede saltárselo), y sin turno declarado no hay disponibilidad posible. Hay **corte nocturno** salvo declaración expresa de disponibilidad de noche. Diseñado así para evitar el patrón por el que se sancionó a Foodinho/Glovo en Italia (geolocalización de repartidores fuera de turno).
- **Purga automática** de peticiones abandonadas y de ubicaciones de ayudantes con turno caducado (`purgar_datos_caducados`, migración `20260904200000_purga_de_datos_caducados.sql`).
- **`profiles.disability_type` eliminado** (migración `20260902000000_borrar_disability_type_de_profiles.sql`) por ser dato de salud, categoría especial del art. 9 RGPD, y no usarse para nada real.
- Otras defensas ya presentes: inmutabilidad de la petición (`peticion_inmutable`), anti-secuestro de `helper_id` (`prevent_helper_id_hijack`), anti-aceptación obsoleta (`prevent_stale_accept`), rate limiting (`check_rate_limit`, `api_rate_limits`), borrado de cuenta por RPC (`delete_own_account`).

---

## 4. Legal y cumplimiento

- **La EIPD (evaluación de impacto, art. 35 RGPD) está pendiente y BLOQUEA la beta pública.** Estimación 2-4 semanas, dependiente de asesor externo. **No bloquea** comunicar el producto ni captar ayudantes por lista de espera.
- Hasta que se constituya la **SL**, el responsable del tratamiento declarado es **Álvaro como persona física**, no una empresa. Los **Términos y Condiciones** siguen en borrador (`docs/Terminos-y-Condiciones-App-BORRADOR.md`) y bloqueados hasta la constitución de la sociedad.
- **Base jurídica de la ubicación del ayudante: ejecución del contrato (art. 6.1.b), NO consentimiento.** El interruptor de disponibilidad es una medida de **minimización**, no la base legal. Un agente que escriba "consentimiento para la ubicación" está introduciendo un error de cumplimiento.
- Documentos de identidad: tratados por Didit en el dispositivo, no almacenados por Wheelp.
- Política de privacidad y textos de consentimiento reescritos recientemente para reflejar lo que realmente se trata. Ha habido más de una discrepancia histórica entre lo declarado y lo recogido, también en la web. **Cualquier agente que toque textos legales o descripciones de producto debe verificar contra el código y el esquema antes de escribir.**
- Pendiente de verificación (NO CONFIRMADO): transferencias fuera de la UE de Supabase, Google, Apple (APNs) y Didit — así consta en `docs/Inventario-de-datos.md`.
- La función de ayudantes es un producto de **confianza y seguridad**: verificación de identidad, seguros, responsabilidad civil y protocolos de incidente son parte del producto, no una feature secundaria.

---

## 5. Marketing y contenido

- **wheelp.app** tiene lista de espera con **tres audiencias**: usuario, ayudante ("Ser ayudante") y negocio, cada una con **selector de provincia obligatorio** (la app solo funciona si oferta y demanda coinciden en provincia). El esquema lo confirma: `website_waitlist(email, audience, province)`. **Altas actuales: 0 (VERIFICADO).**
- **Instagram:** cuenta a **0 seguidores**, sin publicaciones. Conector MCP de Instagram disponible localmente (`wheelp-instagram`).
- **Regla de formato obligatoria:** toda caption de Instagram empieza con una línea que contiene **solo `|`**.
- **Calendario de contenido**, ya corregido una vez: **Fase 0** (explicar qué es la app, sin CTA — la cuenta parte de cero y nadie sabe qué es Wheelp) **antes de Fase 1** (captar ayudantes). El error inicial fue pedir el rol de ayudante sin haber explicado el producto.
- **Tono:** nada de mensaje "salvador" ni de porno inspiracional. Público adulto con discapacidad, no niños, no gente a la que "salvar". **Sin prometer fechas de lanzamiento** (bloqueo de la EIPD). **Sin pedir descarga de la app** todavía.
- **Contenido generado por IA que represente discapacidad: riesgo reputacional alto** si se nota falso. Decisión para el primer reel: POV de manos sin mostrar cara, vídeo IA para las manos, pero **la interfaz de la app en pantalla debe ser una recreación FIEL del código real**, nunca inventada — incluidos los criterios de accesibilidad de §1.1.
- Prohibido publicar cifras de usuarios, tracción, mercado o ingresos: hoy no hay ninguna que resista un escrutinio (ver §1).

---

## 6. Negocio y finanzas

- Modelo: marketplace con **comisión** sobre servicios de ayudantes cualificados, España, alcance de acompañamiento/guía. Decisión cerrada.
- **NO CONFIRMADO — no inventar**: precio por servicio y % de comisión, runway, capital disponible, estado de fundraising, tamaño del equipo, valoración, tamaño de mercado (TAM/SAM/SOM), coste de adquisición, previsión de ingresos, fecha de constitución de la SL, fecha de lanzamiento. Si un agente necesita alguno de estos datos, debe pedirlo explícitamente a Álvaro o al CFO (`wheelp-cfo`), no estimarlo.

---

## 7. Estructura de agentes

- **Equipo especializado con contexto continuo de este proyecto (NO tocar, NO duplicar, NO sustituir):** `wheelp-cco` (síntesis y estrategia), `wheelp-cto`, `wheelp-legal`, `wheelp-cmo`, `wheelp-cfo`, `wheelp-content-planner`, `wheelp-content-creator`, `wheelp-creative-designer`.
- El trabajo de ingeniería de la app se enruta a través de `wheelp-cto`, no directamente.
- Los **37 agentes de `.claude/agents/`** son plantillas de catálogo sin contexto de Wheelp. Se han revisado tres a fondo (`security-architect`, `marketing-content-creator`, `product-manager`) y hablan en abstracto (OWASP, zero-trust) sin saber que usamos Supabase con RLS, incluyen métricas de relleno ("300% de aumento en leads"), desconocen la regla de caption de Instagram y el estado real del producto.
- **Encargo al Agents Orchestrator:** actualizar a los 36 restantes (todos menos él mismo, y **sin tocar el equipo `wheelp-*` existente**) para que sustituyan el boilerplate por los hechos de este documento, dentro de su dominio:
  - Agentes de seguridad → §2, §3 (RLS, SECURITY DEFINER, la trampa de `EXECUTE`, secretos, repo público).
  - Agentes de ingeniería/BD/móvil → §2, §2.1, §3, más la regla de verificar por CI y nunca por simulador local.
  - Agentes de privacidad y accesibilidad → §1.1, §3, §4.
  - Agentes de marketing/contenido/ASO/redes → §1, §5, y la prohibición de cifras inventadas de §6.
  - Agentes de producto/PM/proyecto → §1 (estado real: demanda 0, oferta primero), §4 (la EIPD bloquea la beta), §6 (lo que no está confirmado).
- **Regla común que debe quedar en todos:** no inventar cifras; verificar contra código y esquema antes de afirmar lo que la app hace; escalar decisiones de estrategia al equipo `wheelp-*`.
