# Inventario de datos tratados por Wheelp

Estado del sistema a **31 de agosto de 2026**, extraído del esquema real de
producción (proyecto Supabase `olkvvidnnurjzwlgsuic`), no de documentación.

**Para qué sirve este documento.** Es el insumo técnico del Registro de
Actividades de Tratamiento (art. 30 RGPD), de la EIPD (art. 35) y de la política
de privacidad. Describe qué se trata y quién puede leerlo. **No** contiene
calificaciones jurídicas: la base legal, la proporcionalidad y los plazos de
conservación los fija asesoría legal.

---

## Resumen para quien tenga prisa

| | |
|---|---|
| Datos de categoría especial (art. 9) | **Sí** — tipo de discapacidad, solo por petición y mientras dura |
| Datos biométricos / documento de identidad | **Sí** — verificación de ayudantes, vía Didit |
| Geolocalización | **Sí** — aproximada; la del ayudante también en segundo plano |
| Menores | No — la app es para adultos |
| Perfilado automatizado | No hoy. La asignación es por proximidad, sin puntuación |
| Histórico de ubicación | **No se guarda** — solo la posición actual, que se sobrescribe |
| Transferencias fuera de la UE | A verificar: región de Supabase, Google, Apple (APNs), Didit |

---

## Categoría especial: tipo de discapacidad

Se almacena en **dos sitios distintos**, con sensibilidad muy diferente:

### `profiles` — ya no guarda el tipo de discapacidad

Columnas: `id, username, first_name, last_name, email, onboarding_completed,
created_at`

> Hasta el 31/08/2026 existía `profiles.disability_type`: un registro
> **permanente** que unía el tipo de discapacidad a una persona identificada por
> nombre, apellidos y correo. Verificado en producción antes de borrarla: 0
> filas con valor, ningún trigger que la rellenase, ninguna lectura desde la
> app —el tipo vive en `UserDefaults` y nunca sale del dispositivo—. Era el
> tratamiento más sensible del sistema sin ninguna finalidad, así que se
> eliminó la columna en vez de declararla (migración
> `20260902000000_borrar_disability_type_de_profiles.sql`).

### `help_requests.disability_type` — por petición

Vive mientras dura la petición y se borra con ella. Quién lo lee: la persona que
pide, el ayudante asignado, y —antes de que nadie acepte— los ayudantes dentro
del radio de búsqueda, vía `nearby_pending_requests`.

> Hasta el 30/08/2026 lo leía **cualquier ayudante del país**: el filtro por
> distancia se aplicaba en el cliente y el servidor enviaba todas las peticiones
> pendientes. Corregido (PR #12): el filtro pasó al servidor y la política RLS
> dejó de permitir la lectura directa de la tabla.

### `accessibility_reports.disability_type`

Aquí el tipo describe **el criterio de accesibilidad valorado del sitio**, no la
condición de quien aporta el dato. Un ayudante sin discapacidad puede informar
sobre accesibilidad visual. No es, por tanto, dato de salud del contribuyente.

---

## Geolocalización

| Dónde | Qué se guarda | Precisión | Cuándo |
|---|---|---|---|
| `helpers.latitude/longitude/location` | Zona del ayudante | **~2,2 km** (`HelpCrypto.coarse`) | Solo con turno activo |
| `help_requests.area_latitude/longitude` | Zona donde se necesita ayuda | **~1,1 km** (`HelpCrypto.approximate`) | Mientras dure la petición |
| Punto de encuentro exacto | Dentro de `requester_payload` | **Exacta** | **Cifrado E2E**: el servidor no puede leerlo |
| Navegación paso a paso | — | Exacta | **Nunca sale del dispositivo** |

Detalles con consecuencia:

- **Sin histórico.** `helpers.location` se sobrescribe. No hay rastro de
  movimientos, solo la última posición conocida.
- **Segundo plano solo durante el turno.** Servicio de cambios significativos
  (~500 m), atado a `available_until`. El servidor deja de considerar disponible
  a quien tiene el turno caducado, aunque su app no haya podido apagarlo.
- **Tope de 8 h**, impuesto por el trigger `limitar_turno_disponibilidad`, y
  corte nocturno a las 23:00 salvo disponibilidad nocturna declarada.
- El redondeo está **cubierto por tests** (`PrecisionBoundaryTests`): que las
  zonas pierden precisión de verdad, el tamaño de celda medido en metros, y que
  el punto de encuentro cifrado **no** se redondea.

---

## Resto de tablas

| Tabla | Contenido | Quién lo lee |
|---|---|---|
| `helpers` | Nombre, foto, zona, disponibilidad | Propio ayudante; el solicitante ve el perfil del asignado |
| `helper_applications` | Nombre, ciudad, teléfono, motivación, `kyc_session_id` | Propio solicitante y admin |
| `help_messages` | **Solo texto cifrado** — el servidor no puede leer los mensajes | Las dos partes |
| `helper_ratings` | Valoración numérica | Solo quien la emitió; la media, vía función agregada |
| `push_tokens` | Token APNs del dispositivo | Solo el propio usuario |
| `api_rate_limits` | Contadores por usuario y endpoint | Nadie: solo `service_role`. Se purga a los 5 min |
| `website_waitlist` | Correo y audiencia | Inserción anónima desde la web |

---

## Encargados y terceros

| Quién | Qué recibe | Notas |
|---|---|---|
| **Supabase** | Todo lo anterior | Falta contrato de encargado (art. 28) y verificar región |
| **Google Places / Routes** | Nombre y coordenadas del destino | Vía Edge Function: la clave nunca sale del servidor |
| **OpenStreetMap (Overpass)** | Coordenadas del destino | Respaldo cuando Google no tiene datos |
| **Apple (APNs)** | Token del dispositivo y texto del aviso | El aviso **no** incluye tipo de discapacidad |
| **Didit** | DNI y prueba de vida del ayudante | Se hace **en el dispositivo**; el documento no pasa por Wheelp |
| **AgentMail** | Informes de auditoría al admin | No trata datos de usuarios |

---

## Lo que la app declara hoy, y lo que no

Textos actuales: consentimiento del registro (`LoginView`) y sección "Privacidad
y datos" de Ajustes (`SettingsView`).

**No mencionan:**

1. El **tipo de discapacidad** almacenado en el servidor — la omisión más grave,
   por ser categoría especial.
2. La **zona del ayudante compartida en segundo plano** durante el turno.
3. El **token de notificaciones**.
4. La **verificación de identidad** con Didit.
5. La **foto de perfil** del ayudante.

**Y hay una frase que induce a error:** *"la ubicación exacta nunca se almacena
en el servidor"*. Es literalmente cierta —se guarda aproximada— pero se lee como
"no se guarda ubicación", justo cuando la del ayudante se guarda durante horas.

---

## Pendiente (no es trabajo de ingeniería)

- **EIPD** (art. 35). Bloquea la beta pública, según revisión legal previa.
- **Registro de Actividades de Tratamiento** (art. 30). Obligatorio ya: la
  exención por tamaño no aplica al tratar categorías especiales.
- **Contratos de encargado** (art. 28) y análisis de transferencias.
- **Reescritura de los textos de privacidad** a partir de este inventario.
- **Base jurídica del tratamiento del ayudante**: art. 6.1.b) (ejecución del
  contrato), **no** consentimiento. El toggle de disponibilidad es medida de
  minimización, no base jurídica.
