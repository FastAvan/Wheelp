import Foundation
import CoreLocation
import CryptoKit
import Supabase

/// Petición de ayuda tal y como se guarda en Supabase (tabla `help_requests`).
///
/// En el servidor solo es legible lo imprescindible para emparejar: una zona
/// aproximada de recogida (~1 km), el lugar de destino, el tipo de discapacidad
/// y las claves públicas. Nombres y trayecto exacto viajan cifrados de extremo
/// a extremo y solo se rellenan (campos "descifrados") en los dos dispositivos.
struct HelpRequest: Codable, Identifiable, Hashable {
    var id: UUID
    var requesterId: UUID?
    var helperId: UUID?
    var status: Status
    var disabilityType: String
    /// Zona aproximada de recogida (~1 km), única ubicación legible.
    var areaLatitude: Double
    var areaLongitude: Double
    /// Lugar de destino (el usuario consiente compartirlo para la preaceptación).
    var placeName: String
    var requesterPubkey: String
    var helperPubkey: String?
    var requesterPayload: String?
    var helperPayload: String?
    var createdAt: Date?
    /// Fecha y hora de la cita (nil = petición inmediata).
    var scheduledAt: Date?

    // Campos descifrados localmente (nunca viajan en claro).
    var requesterName: String?
    var helperName: String?
    var originLatitude: Double?
    var originLongitude: Double?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var meetingPoint: String?
    var meetingName: String?
    var meetingLatitude: Double?
    var meetingLongitude: Double?

    enum Status: String, Codable {
        case pending, accepted
        case inProgress = "in_progress"
        case completed, cancelled
    }

    /// Punto de encuentro elegido por el usuario.
    enum MeetingPoint: String, Codable {
        case origin, destination, route
    }

    /// Solo los campos que existen en el servidor.
    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case helperId = "helper_id"
        case status
        case disabilityType = "disability_type"
        case areaLatitude = "area_latitude"
        case areaLongitude = "area_longitude"
        case placeName = "place_name"
        case requesterPubkey = "requester_pubkey"
        case helperPubkey = "helper_pubkey"
        case requesterPayload = "requester_payload"
        case helperPayload = "helper_payload"
        case createdAt = "created_at"
        case scheduledAt = "scheduled_at"
    }

    /// ¿Ya se han descifrado el trayecto y el punto de encuentro exactos?
    var hasExactDetails: Bool { meetingLatitude != nil }

    var isScheduled: Bool { scheduledAt != nil }

    /// Texto formateado de la fecha de la cita para mostrar en la UI.
    var scheduledForText: String? {
        guard let date = scheduledAt else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Coordenada del destino (exacta si está descifrada; si no, la zona).
    var coordinate: CLLocationCoordinate2D {
        if let destinationLatitude, let destinationLongitude {
            return CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
        }
        return CLLocationCoordinate2D(latitude: areaLatitude, longitude: areaLongitude)
    }

    /// Punto de encuentro (exacto si está descifrado; si no, la zona aproximada).
    var meetingCoordinate: CLLocationCoordinate2D {
        if let meetingLatitude, let meetingLongitude {
            return CLLocationCoordinate2D(latitude: meetingLatitude, longitude: meetingLongitude)
        }
        return CLLocationCoordinate2D(latitude: areaLatitude, longitude: areaLongitude)
    }

    var originCoordinate: CLLocationCoordinate2D? {
        guard let originLatitude, let originLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude)
    }

    /// Texto del tipo de punto de encuentro, para mostrárselo al ayudante.
    var meetingPointLabel: String {
        switch MeetingPoint(rawValue: meetingPoint ?? "") {
        case .origin: "en su punto de partida"
        case .route: "en un punto del camino"
        default: "en el destino"
        }
    }
}

/// Mensaje del chat de una petición (tabla `help_messages`).
/// En el servidor solo hay texto cifrado; `text` se rellena al descifrar.
struct HelpMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var requestId: UUID
    var senderId: UUID?
    var ciphertext: String
    var createdAt: Date?

    /// Texto descifrado localmente.
    var text: String?

    enum CodingKeys: String, CodingKey {
        case id
        case requestId = "request_id"
        case senderId = "sender_id"
        case ciphertext
        case createdAt = "created_at"
    }
}

/// Solicitud de un usuario para darse de alta como ayudante (tabla `helper_applications`).
struct HelperApplication: Codable, Identifiable {
    let id: UUID
    let displayName: String
    let city: String
    let phone: String?
    let motivation: String?
    let status: ApplicationStatus
    let createdAt: Date?

    enum ApplicationStatus: String, Codable {
        case pending, approved, rejected
    }

    enum CodingKeys: String, CodingKey {
        case id, city, phone, motivation, status
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

/// Peticiones de ayuda cifradas de extremo a extremo: Supabase actúa solo de
/// "buzón" reemplazable. Crear, descubrir por zona, aceptar (intercambio de
/// claves), chatear cifrado y borrar todo al terminar.
enum HelperService {
    private static let table = "help_requests"
    private static let messagesTable = "help_messages"

    // MARK: - Ubicación del ayudante

    private static var lastLocationUpdate: Date = .distantPast
    private static var lastLocationCoord: CLLocationCoordinate2D?

    /// Actualiza lat/lng del ayudante en `helpers`. Throttling: solo escribe si han pasado
    /// más de 5 minutos O el ayudante se ha movido más de 200 m desde la última vez.
    ///
    /// `force` salta el throttling. Se usa al abrir la app desde un push: es el
    /// único momento en que se sabe con certeza dónde está el ayudante, y esa
    /// posición es la que decidirá si le llegan los siguientes avisos.
    static func updateHelperLocation(_ location: CLLocation, force: Bool = false) async {
        let now = Date()
        if !force, let last = lastLocationCoord {
            let elapsed = now.timeIntervalSince(lastLocationUpdate)
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard elapsed > 300 || moved > 200 else { return }
        }
        guard let userId = try? await supabase.auth.session.user.id else { return }
        // Zona de ~2 km — proporcionalidad RGPD art. 5.1.c. Filtrar ayudantes en
        // radios de 5-20 km no requiere más precisión, y esta posición se
        // refresca sola durante horas de turno: cuanto más basta, menos permite
        // inferir domicilio o rutinas.
        struct Update: Encodable {
            let latitude: Double
            let longitude: Double
        }
        do {
            try await supabase
                .from("helpers")
                .update(Update(
                    latitude: HelpCrypto.coarse(location.coordinate.latitude),
                    longitude: HelpCrypto.coarse(location.coordinate.longitude)
                ))
                .eq("user_id", value: userId)
                .execute()
            lastLocationUpdate = now
            lastLocationCoord = location.coordinate
        } catch {}
    }

    // MARK: - Disponibilidad del ayudante

    /// Actualiza el campo `available` en `helpers` para el ayudante actual.
    /// Activa o desactiva el turno del ayudante.
    ///
    /// `until` es la hora declarada de fin. El servidor recorta a 8 h y apaga la
    /// disponibilidad si llega sin turno, así que una app modificada no puede
    /// declararse disponible indefinidamente.
    static func updateAvailability(_ available: Bool, until: Date? = nil) async {
        guard let userId = try? await supabase.auth.session.user.id else { return }
        struct Update: Encodable {
            let available: Bool
            let available_until: String?
        }
        _ = try? await supabase
            .from("helpers")
            .update(Update(
                available: available,
                available_until: available ? until?.ISO8601Format() : nil
            ))
            .eq("user_id", value: userId)
            .execute()
    }

    /// Hasta cuándo declaró el ayudante estar disponible (nil si no lo está).
    static func availableUntil() async -> Date? {
        guard let userId = try? await supabase.auth.session.user.id else { return nil }
        struct Row: Decodable {
            let available: Bool
            let availableUntil: Date?
            enum CodingKeys: String, CodingKey {
                case available
                case availableUntil = "available_until"
            }
        }
        let row: Row? = try? await supabase
            .from("helpers")
            .select("available,available_until")
            .eq("user_id", value: userId)
            .single()
            .execute()
            .value
        guard let row, row.available, let until = row.availableUntil, until > Date() else { return nil }
        return until
    }

    /// Disponibilidad guardada en Supabase. `nil` = no se pudo saber (401, red
    /// caída, 500…); igual que en `isRegisteredHelper`, quien llame debe conservar
    /// el último valor conocido en vez de inventarse uno. Si la fila responde con
    /// `available` a null (columna aún sin valor) se asume `true`.
    static func fetchAvailability() async -> Bool? {
        struct Row: Decodable { let available: Bool? }
        guard let userId = try? await supabase.auth.session.user.id else { return nil }
        do {
            let row: Row = try await supabase
                .from("helpers")
                .select("available")
                .eq("user_id", value: userId)
                .single()
                .execute()
                .value
            return row.available ?? true
        } catch {
            return nil
        }
    }

    /// ¿El usuario actual está dado de alta como ayudante (tabla `helpers`)?
    /// `true`/`false` solo cuando el servidor responde. `nil` = no se pudo saber
    /// (401 por token caducado, red caída, 500…). Quien llame NO debe tratar el
    /// `nil` como "no es ayudante": eso degradaba a un ayudante real a usuario
    /// normal ante cualquier fallo transitorio.
    /// ¿La persona que ha iniciado sesión es admin? Lo decide el servidor, no el
    /// cliente: aquí solo se usa para enseñar o esconder la pantalla de
    /// solicitudes. La autorización de verdad la imponen RLS y is_admin().
    /// `nil` = no se pudo consultar; el llamante conserva lo que ya tenía.
    static func isAdmin() async -> Bool? {
        do { return try await supabase.rpc("is_admin").execute().value }
        catch { return nil }
    }

    static func isRegisteredHelper() async -> Bool? {
        struct Row: Codable { let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        guard let userId = try? await supabase.auth.session.user.id else { return nil }
        do {
            let rows: [Row] = try await supabase
                .from("helpers")
                .select("user_id")
                .eq("user_id", value: userId)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            return nil
        }
    }

    /// Identificador del usuario actual (para distinguir roles y mensajes).
    static func currentUserId() async -> UUID? {
        try? await supabase.auth.session.user.id
    }

    // MARK: - Descifrado local de una petición

    /// Clave simétrica de la petición para el usuario actual, si participa.
    static func symmetricKey(for request: HelpRequest) async -> SymmetricKey? {
        guard let myId = await currentUserId(),
              let priv = HelpCrypto.privateKey(for: request.id) else { return nil }
        let otherPub = (myId == request.requesterId) ? request.helperPubkey : request.requesterPubkey
        guard let otherPub else { return nil }
        return HelpCrypto.symmetricKey(requestId: request.id, myPrivateKey: priv, otherPublicKeyBase64: otherPub)
    }

    /// Rellena los campos descifrados que el usuario actual pueda leer.
    static func decorate(_ request: HelpRequest) async -> HelpRequest {
        var request = request
        let myId = await currentUserId()

        // El solicitante siempre conoce sus propios datos (guardados en local).
        if myId == request.requesterId, let mine = HelpCrypto.pendingDetails(for: request.id) {
            apply(mine, to: &request)
        }

        guard let key = await symmetricKey(for: request) else { return request }
        if let details = HelpCrypto.openJSON(HelperDetails.self, from: request.helperPayload, with: key) {
            request.helperName = details.name
        }
        if let details = HelpCrypto.openJSON(RequesterDetails.self, from: request.requesterPayload, with: key) {
            apply(details, to: &request)
        }
        return request
    }

    private static func apply(_ details: RequesterDetails, to request: inout HelpRequest) {
        request.requesterName = details.name
        request.originLatitude = details.originLatitude
        request.originLongitude = details.originLongitude
        request.destinationLatitude = details.destinationLatitude
        request.destinationLongitude = details.destinationLongitude
        request.meetingPoint = details.meetingPoint
        request.meetingName = details.meetingName
        request.meetingLatitude = details.meetingLatitude
        request.meetingLongitude = details.meetingLongitude
    }

    // MARK: - Crear (solicitante)

    /// Publica una petición anónima: zona aproximada + destino + clave pública.
    /// El trayecto exacto y el nombre quedan en el dispositivo, cifrándose para
    /// el ayudante solo cuando alguien acepta.
    static func create(
        placeName: String,
        coordinate: CLLocationCoordinate2D,
        disabilityType: DisabilityType,
        requesterName: String?,
        origin: CLLocationCoordinate2D?,
        meeting: HelpRequest.MeetingPoint,
        meetingName: String?,
        meetingCoordinate: CLLocationCoordinate2D,
        scheduledAt: Date? = nil
    ) async -> HelpRequest? {
        let id = UUID()
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        HelpCrypto.savePrivateKey(privateKey, for: id)

        let details = RequesterDetails(
            name: requesterName,
            originLatitude: origin?.latitude,
            originLongitude: origin?.longitude,
            destinationLatitude: coordinate.latitude,
            destinationLongitude: coordinate.longitude,
            meetingPoint: meeting.rawValue,
            meetingName: meetingName,
            meetingLatitude: meetingCoordinate.latitude,
            meetingLongitude: meetingCoordinate.longitude
        )
        HelpCrypto.savePendingDetails(details, for: id)

        let request = HelpRequest(
            id: id,
            requesterId: nil, // lo rellena Supabase con auth.uid()
            helperId: nil,
            status: .pending,
            disabilityType: disabilityType.rawValue,
            areaLatitude: HelpCrypto.approximate(meetingCoordinate.latitude),
            areaLongitude: HelpCrypto.approximate(meetingCoordinate.longitude),
            placeName: placeName,
            requesterPubkey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            helperPubkey: nil,
            requesterPayload: nil,
            helperPayload: nil,
            createdAt: nil,
            scheduledAt: scheduledAt
        )
        do {
            try await supabase.from(table).insert(request).execute()
            return await decorate(request)
        } catch {
            HelpCrypto.forget(requestId: id)
            return nil
        }
    }

    /// Estado actual de una petición (para el que la creó). Si acaban de
    /// aceptarla, sube el trayecto cifrado para el ayudante.
    static func fetch(id: UUID) async -> HelpRequest? {
        let request: HelpRequest? = try? await supabase
            .from(table)
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value
        guard var request else { return nil }
        request = await decorate(request)
        await uploadRequesterPayloadIfNeeded(request)
        return request
    }

    /// Segunda fase del intercambio: con el ayudante aceptado, el solicitante
    /// cifra su nombre y trayecto exacto para él.
    private static func uploadRequesterPayloadIfNeeded(_ request: HelpRequest) async {
        guard request.status == .accepted,
              request.requesterPayload == nil,
              request.helperPubkey != nil,
              let myId = await currentUserId(), myId == request.requesterId,
              let details = HelpCrypto.pendingDetails(for: request.id),
              let key = await symmetricKey(for: request),
              let payload = HelpCrypto.sealJSON(details, with: key) else { return }
        _ = try? await supabase
            .from(table)
            .update(["requester_payload": payload])
            .eq("id", value: request.id)
            .execute()
    }

    // MARK: - Descubrir y aceptar (ayudante)

    /// Ventana de validez de una petición inmediata. Pasado ese tiempo se asume
    /// que quien la pidió ya se ha marchado: aceptarla mandaría a un ayudante a
    /// un encuentro que ya no existe. El servidor la rechaza igualmente
    /// (trigger prevent_stale_accept), esto solo evita mostrarla.
    static let requestValidity: TimeInterval = 30 * 60

    /// Peticiones inmediatas (sin fecha) pendientes cercanas, por distancia.
    /// Margen que se suma al radio para compensar el redondeo de la zona.
    /// Las coordenadas se publican en una rejilla aproximada, así que alguien
    /// justo dentro del radio puede aparecer ligeramente fuera. Es preferible
    /// incluir a alguno de más que perder a quien sí podía ayudar.
    static let gridPaddingKm: Double = 1

    /// Peticiones inmediatas pendientes cercanas.
    ///
    /// El filtro por distancia lo hace el servidor (`nearby_pending_requests`).
    /// Antes se pedían todas y se filtraba aquí, lo que significaba enviar a
    /// cualquier ayudante el tipo de discapacidad —dato de salud— de personas de
    /// toda España a las que nunca iba a atender.
    static func fetchPending(near center: CLLocationCoordinate2D?, radiusKm: Double = 20) async -> [HelpRequest] {
        guard let center else { return [] }
        struct Params: Encodable {
            let p_lat: Double
            let p_lng: Double
            let p_radius_km: Double
        }
        let requests: [HelpRequest]? = try? await supabase
            .rpc("nearby_pending_requests", params: Params(
                p_lat: center.latitude,
                p_lng: center.longitude,
                p_radius_km: radiusKm + gridPaddingKm
            ))
            .execute()
            .value
        guard let requests else { return [] }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return requests
            .filter { $0.scheduledAt == nil }
            .sorted { distance(from: here, to: $0) < distance(from: here, to: $1) }
    }

    /// Citas programadas pendientes (futuras o hasta 30 min pasadas) cercanas,
    /// ordenadas por fecha de la cita.
    /// Citas programadas pendientes cercanas. Mismo filtrado en servidor que las
    /// inmediatas, por el mismo motivo: no repartir datos de salud de peticiones
    /// que este ayudante no puede atender.
    static func fetchScheduled(near center: CLLocationCoordinate2D?, radiusKm: Double = 20) async -> [HelpRequest] {
        guard let center else { return [] }
        struct Params: Encodable {
            let p_lat: Double
            let p_lng: Double
            let p_radius_km: Double
        }
        let requests: [HelpRequest]? = try? await supabase
            .rpc("nearby_pending_requests", params: Params(
                p_lat: center.latitude,
                p_lng: center.longitude,
                p_radius_km: radiusKm + gridPaddingKm
            ))
            .execute()
            .value
        guard let requests else { return [] }
        return requests
            .filter { $0.scheduledAt != nil }
            .sorted {
                guard let a = $0.scheduledAt, let b = $1.scheduledAt else { return false }
                return a < b
            }
    }

    /// Confirma que ayudante y usuario se han encontrado: estado → in_progress.
    static func markInProgress(_ id: UUID) async -> Bool {
        do {
            try await supabase
                .from(table)
                .update(["status": HelpRequest.Status.inProgress.rawValue])
                .eq("id", value: id)
                .eq("status", value: HelpRequest.Status.accepted.rawValue)
                .execute()
            return true
        } catch { return false }
    }

    /// Devuelve al grupo una petición ya aceptada, para que otro ayudante pueda
    /// cogerla. Sin esto, quien acepta y luego no puede ir solo tiene dos
    /// salidas: desaparecer —y dejar a alguien esperando sin saberlo— o marcarla
    /// "Completada" sin haber ido.
    ///
    /// El servidor avisa a los demás ayudantes y al solicitante (send-push
    /// reacciona a accepted/in_progress → pending). La clave local se borra: se
    /// deriva una nueva si vuelve a aceptarse.
    static func release(_ id: UUID) async -> Bool {
        struct Released: Decodable { let id: UUID }
        struct Update: Encodable {
            let status: String
            let helper_id: String?
            let helper_pubkey: String?
            let helper_payload: String?
        }
        do {
            let rows: [Released] = try await supabase
                .from(table)
                .update(Update(
                    status: HelpRequest.Status.pending.rawValue,
                    helper_id: nil, helper_pubkey: nil, helper_payload: nil
                ))
                .eq("id", value: id)
                .select("id")
                .execute()
                .value
            guard !rows.isEmpty else { return false }
            HelpCrypto.forget(requestId: id)
            return true
        } catch { return false }
    }

    /// Amplía el radio de búsqueda de una petición que sigue sin ayudante.
    /// El UPDATE dispara el push a los ayudantes que entran con el radio nuevo.
    static func widenSearch(_ id: UUID, toKm radius: Int) async -> Bool {
        struct Widened: Decodable { let id: UUID }
        do {
            let rows: [Widened] = try await supabase
                .from(table)
                .update(["search_radius_km": radius])
                .eq("id", value: id)
                .eq("status", value: HelpRequest.Status.pending.rawValue)
                .select("id")
                .execute()
                .value
            return !rows.isEmpty
        } catch { return false }
    }

    /// Peticiones que este ayudante tiene aceptadas o en curso, ya descifradas.
    static func fetchAccepted() async -> [HelpRequest] {
        guard let userId = try? await supabase.auth.session.user.id else { return [] }
        let requests: [HelpRequest]? = try? await supabase
            .from(table)
            .select()
            .in("status", value: [HelpRequest.Status.accepted.rawValue, HelpRequest.Status.inProgress.rawValue])
            .eq("helper_id", value: userId)
            .execute()
            .value
        var decorated: [HelpRequest] = []
        for request in requests ?? [] {
            decorated.append(await decorate(request))
        }
        return decorated
    }

    /// Acepta una petición: genera claves, cifra el nombre del ayudante y
    /// publica la clave pública para que el solicitante responda cifrado.
    static func accept(_ request: HelpRequest, helperName: String?) async -> Bool {
        // Quién acepta lo decide el servidor con auth.uid(); aquí solo se
        // comprueba que hay sesión antes de gastar una clave nueva.
        guard (try? await supabase.auth.session.user.id) != nil else { return false }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let key = HelpCrypto.symmetricKey(
            requestId: request.id,
            myPrivateKey: privateKey,
            otherPublicKeyBase64: request.requesterPubkey
        ), let payload = HelpCrypto.sealJSON(HelperDetails(name: helperName), with: key) else {
            return false
        }
        do {
            // Aceptar va por RPC, no por UPDATE directo, y no es un capricho:
            // Postgres exige política de SELECT también para un `UPDATE ... WHERE`,
            // porque la orden tiene que leer la fila para localizarla. Como el
            // ayudante NO puede leer una petición que todavía no ha aceptado —se
            // cerró a propósito, dentro va el tipo de discapacidad—, el UPDATE
            // afectaba a cero filas y PostgREST devolvía 200 sin error: aceptar
            // fallaba en silencio. La función resuelve además la carrera entre dos
            // ayudantes en el servidor, y devuelve false a quien llegó tarde.
            struct Aceptar: Encodable {
                let p_id: UUID
                let p_helper_pubkey: String
                let p_helper_payload: String
            }
            let gane: Bool = try await supabase
                .rpc("aceptar_peticion", params: Aceptar(
                    p_id: request.id,
                    p_helper_pubkey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                    p_helper_payload: payload
                ))
                .execute()
                .value
            guard gane else { return false }
            // Save key only after the update is confirmed, to avoid leaving a
            // dangling key if the update fails or races with another accept.
            HelpCrypto.savePrivateKey(privateKey, for: request.id)
            return true
        } catch {
            return false
        }
    }

    /// Termina una petición (completada o cancelada): borra la fila, sus
    /// mensajes (en cascada) y la clave local. Para la otra persona, la
    /// desaparición de la fila equivale al fin de la ayuda.
    static func close(_ id: UUID) async {
        // Only wipe the local key if the server delete is confirmed; a network
        // failure otherwise leaves the row in the DB and a helper could still
        // accept it while the key is already gone.
        if (try? await supabase.from(table).delete().eq("id", value: id).execute()) != nil {
            HelpCrypto.forget(requestId: id)
        }
    }

    /// Distancia del ayudante al punto de encuentro (o a su zona aproximada).
    static func distance(from location: CLLocation, to request: HelpRequest) -> CLLocationDistance {
        let meeting = request.meetingCoordinate
        return location.distance(from: CLLocation(latitude: meeting.latitude, longitude: meeting.longitude))
    }

    // MARK: - Chat cifrado

    /// Mensajes de una petición, descifrados para los participantes.
    static func fetchMessages(request: HelpRequest) async -> [HelpMessage] {
        let messages: [HelpMessage]? = try? await supabase
            .from(messagesTable)
            .select()
            .eq("request_id", value: request.id)
            .order("created_at", ascending: false)
            .limit(100)
            .execute()
            .value
        guard var messages else { return [] }
        messages.reverse() // newest-first from DB → oldest-first for display
        if let key = await symmetricKey(for: request) {
            for index in messages.indices {
                if let data = HelpCrypto.open(messages[index].ciphertext, with: key) {
                    messages[index].text = String(data: data, encoding: .utf8)
                }
            }
        }
        return messages
    }

    /// Últimos mensajes de los chats del usuario (para notificar; sin descifrar).
    static func fetchRecentMessages(limit: Int = 25) async -> [HelpMessage] {
        let messages: [HelpMessage]? = try? await supabase
            .from(messagesTable)
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return messages ?? []
    }

    static func sendMessage(request: HelpRequest, text: String) async {
        guard let key = await symmetricKey(for: request),
              let ciphertext = HelpCrypto.seal(Data(text.utf8), with: key) else { return }
        let message = HelpMessage(
            id: UUID(),
            requestId: request.id,
            senderId: nil, // lo rellena Supabase con auth.uid()
            ciphertext: ciphertext,
            createdAt: nil
        )
        _ = try? await supabase.from(messagesTable).insert(message).execute()
    }

    // MARK: - Valoraciones de ayudantes

    /// Guarda la valoración (1–5 estrellas). Si el usuario ya valoró a este
    /// ayudante, la nota anterior se sustituye (upsert por rater_id+helper_id).
    static func submitRating(helperId: UUID, rating: Int) async {
        struct Row: Encodable {
            let id: UUID
            let helperId: UUID
            let rating: Int
            enum CodingKeys: String, CodingKey {
                case id
                case helperId = "helper_id"
                case rating
            }
        }
        let row = Row(id: UUID(), helperId: helperId, rating: max(1, min(5, rating)))
        _ = try? await supabase
            .from("helper_ratings")
            .upsert(row, onConflict: "rater_id,helper_id")
            .execute()
    }

    /// Nota media del ayudante (nil si todavía no tiene valoraciones).
    /// Usa la función agregada `helper_rating_summary` en lugar de leer la tabla
    /// directamente: la tabla ya no es legible fila a fila (expondría qué usuario
    /// puso cada nota).
    static func averageRating(for helperId: UUID) async -> Double? {
        struct Row: Decodable {
            let avg: Double?
            enum CodingKeys: String, CodingKey { case avg }
        }
        struct Params: Encodable { let p_helper_id: UUID }
        let rows: [Row]? = try? await supabase
            .rpc("helper_rating_summary", params: Params(p_helper_id: helperId))
            .execute()
            .value
        return rows?.first?.avg
    }

    // MARK: - Código de verificación del encuentro

    /// Código de 6 dígitos derivado de la clave compartida. Es el mismo en los dos
    /// dispositivos: el ayudante lo muestra al usuario (o lo confirma visualmente)
    /// para verificar la identidad antes de iniciar la sesión.
    static func meetingCode(for request: HelpRequest) async -> String? {
        guard let key = await symmetricKey(for: request) else { return nil }
        return HelpCrypto.meetingCode(from: key)
    }

    // MARK: - Foto de perfil del ayudante

    /// Sube la foto al bucket `helper-avatars` de Supabase Storage y guarda la URL pública
    /// en `helpers.avatar_url`. Sustituye cualquier avatar anterior (upsert: true).
    static func uploadAvatar(_ imageData: Data) async -> String? {
        guard let userId = try? await supabase.auth.session.user.id else {
            print("[Wheelp] uploadAvatar: sin sesión activa")
            return nil
        }
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
            guard !updated.isEmpty else {
                print("[Wheelp] uploadAvatar: 0 filas actualizadas — falta política RLS UPDATE en helpers")
                return nil
            }
            print("[Wheelp] uploadAvatar: foto subida a Storage (\(imageData.count / 1024) KB)")
            return urlString
        } catch {
            print("[Wheelp] uploadAvatar: fallo — \(error)")
            return nil
        }
    }

    /// URL pública de la foto del propio ayudante (nil si no la ha subido).
    static func currentAvatarURL() async -> String? {
        guard let userId = try? await supabase.auth.session.user.id else { return nil }
        return await helperAvatarURL(for: userId)
    }

    /// URL pública de la foto de un ayudante concreto (para mostrar al solicitante).
    static func helperAvatarURL(for helperId: UUID) async -> String? {
        struct Row: Decodable {
            let avatarUrl: String?
            enum CodingKeys: String, CodingKey { case avatarUrl = "avatar_url" }
        }
        let row: Row? = try? await supabase
            .from("helpers")
            .select("avatar_url")
            .eq("user_id", value: helperId)
            .single()
            .execute()
            .value
        return row?.avatarUrl
    }

    // MARK: - Solicitudes de alta como ayudante

    /// Envía (o actualiza) una solicitud para ser ayudante.
    /// kycSessionId proviene de Didit; el documento nunca toca los servidores de Wheelp.
    /// Usa upsert por user_id: permite volver a solicitar tras un rechazo.
    static func submitApplication(
        name: String,
        city: String,
        phone: String,
        motivation: String?,
        kycSessionId: String
    ) async throws {
        struct Insert: Encodable {
            let displayName: String
            let city: String
            let phone: String
            let motivation: String?
            let status: String
            let kycSessionId: String
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case city, phone, motivation, status
                case kycSessionId = "kyc_session_id"
            }
        }
        try await supabase
            .from("helper_applications")
            .upsert(
                Insert(displayName: name, city: city, phone: phone,
                       motivation: motivation, status: "pending", kycSessionId: kycSessionId),
                onConflict: "user_id"
            )
            .execute()
    }

    /// Estado de la solicitud del usuario actual (excluye documentos para no transferir datos grandes).
    static func myApplication() async -> HelperApplication? {
        guard (try? await supabase.auth.session.user.id) != nil else { return nil }
        let rows: [HelperApplication]? = try? await supabase
            .from("helper_applications")
            .select("id,display_name,city,phone,status,motivation,created_at")
            .limit(1)
            .execute()
            .value
        return rows?.first
    }

    // MARK: - Administración de solicitudes (solo admin)

    /// Solicitudes pendientes de revisión. Requiere política RLS SELECT para el admin en Supabase.
    static func fetchPendingApplications() async -> [HelperApplication] {
        let rows: [HelperApplication]? = try? await supabase
            .from("helper_applications")
            .select("id,display_name,city,phone,status,motivation,created_at")
            .eq("status", value: "pending")
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows ?? []
    }

    static func approveApplication(id: UUID) async -> Bool {
        struct Body: Encodable { let action: String; let application_id: String }
        do {
            try await supabase.functions.invoke(
                "admin-actions",
                options: .init(body: Body(action: "approve", application_id: id.uuidString))
            )
            return true
        } catch { return false }
    }

    static func rejectApplication(id: UUID) async -> Bool {
        struct Body: Encodable { let action: String; let application_id: String }
        do {
            try await supabase.functions.invoke(
                "admin-actions",
                options: .init(body: Body(action: "reject", application_id: id.uuidString))
            )
            return true
        } catch { return false }
    }

}

// MARK: - Valoración pendiente tras terminar una ruta con ayudante

struct HelperRatingTarget: Identifiable {
    let id: UUID
    let name: String
}
