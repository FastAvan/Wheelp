import Foundation
import CoreLocation
import Supabase

/// Petición de ayuda guardada en Supabase (tabla `help_requests`).
struct HelpRequest: Codable, Identifiable, Hashable {
    var id: UUID
    var requesterId: UUID?
    var requesterName: String?
    var placeName: String
    var latitude: Double
    var longitude: Double
    var disabilityType: String
    var status: Status
    var helperId: UUID?
    var helperName: String?
    var createdAt: Date?
    /// Origen del trayecto del usuario (su posición al pedir ayuda).
    var originLatitude: Double?
    var originLongitude: Double?
    /// Dónde quiere encontrarse con el ayudante: origin | destination | route.
    var meetingPoint: String?
    var meetingName: String?
    var meetingLatitude: Double?
    var meetingLongitude: Double?

    enum Status: String, Codable {
        case pending, accepted, completed, cancelled
    }

    /// Punto de encuentro elegido por el usuario.
    enum MeetingPoint: String, Codable {
        case origin, destination, route
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case requesterName = "requester_name"
        case placeName = "place_name"
        case latitude
        case longitude
        case disabilityType = "disability_type"
        case status
        case helperId = "helper_id"
        case helperName = "helper_name"
        case createdAt = "created_at"
        case originLatitude = "origin_latitude"
        case originLongitude = "origin_longitude"
        case meetingPoint = "meeting_point"
        case meetingName = "meeting_name"
        case meetingLatitude = "meeting_latitude"
        case meetingLongitude = "meeting_longitude"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Coordenada del punto de encuentro (peticiones antiguas: el destino).
    var meetingCoordinate: CLLocationCoordinate2D {
        guard let meetingLatitude, let meetingLongitude else { return coordinate }
        return CLLocationCoordinate2D(latitude: meetingLatitude, longitude: meetingLongitude)
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

/// Mensaje del chat de una petición de ayuda (tabla `help_messages`).
struct HelpMessage: Codable, Identifiable, Hashable {
    var id: UUID
    var requestId: UUID
    var senderId: UUID?
    var senderName: String?
    var text: String
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requestId = "request_id"
        case senderId = "sender_id"
        case senderName = "sender_name"
        case text
        case createdAt = "created_at"
    }
}

/// Peticiones de ayuda: crear, ver cercanas, aceptar, chatear y finalizar.
/// Versión de prueba: los ayudantes se designan desde Supabase (tabla `helpers`)
/// y las listas se refrescan por sondeo.
enum HelperService {
    private static let table = "help_requests"
    private static let messagesTable = "help_messages"

    /// ¿El usuario actual está dado de alta como ayudante (tabla `helpers`)?
    /// El alta se gestiona fuera de la app (panel de Supabase).
    static func isRegisteredHelper() async -> Bool {
        struct Row: Codable { let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        guard let userId = try? await supabase.auth.session.user.id else { return false }
        let rows: [Row]? = try? await supabase
            .from("helpers")
            .select("user_id")
            .eq("user_id", value: userId)
            .execute()
            .value
        return !(rows ?? []).isEmpty
    }

    /// Identificador del usuario actual (para distinguir mensajes propios).
    static func currentUserId() async -> UUID? {
        try? await supabase.auth.session.user.id
    }

    // MARK: - Chat

    static func fetchMessages(requestId: UUID) async -> [HelpMessage] {
        let messages: [HelpMessage]? = try? await supabase
            .from(messagesTable)
            .select()
            .eq("request_id", value: requestId)
            .order("created_at", ascending: true)
            .limit(100)
            .execute()
            .value
        return messages ?? []
    }

    /// Últimos mensajes de los chats del usuario actual (las políticas de
    /// Supabase ya limitan la consulta a las peticiones en las que participa).
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

    static func sendMessage(requestId: UUID, text: String, senderName: String?) async {
        let message = HelpMessage(
            id: UUID(),
            requestId: requestId,
            senderId: nil, // lo rellena Supabase con auth.uid()
            senderName: senderName,
            text: text,
            createdAt: nil
        )
        _ = try? await supabase.from(messagesTable).insert(message).execute()
    }

    /// Crea una petición de ayuda con el trayecto completo del usuario
    /// (origen → destino) y el punto de encuentro elegido.
    static func create(
        placeName: String,
        coordinate: CLLocationCoordinate2D,
        disabilityType: DisabilityType,
        requesterName: String?,
        origin: CLLocationCoordinate2D?,
        meeting: HelpRequest.MeetingPoint,
        meetingName: String?,
        meetingCoordinate: CLLocationCoordinate2D
    ) async -> HelpRequest? {
        let request = HelpRequest(
            id: UUID(),
            requesterId: nil, // lo rellena Supabase con auth.uid()
            requesterName: requesterName,
            placeName: placeName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            disabilityType: disabilityType.rawValue,
            status: .pending,
            helperId: nil,
            helperName: nil,
            createdAt: nil,
            originLatitude: origin?.latitude,
            originLongitude: origin?.longitude,
            meetingPoint: meeting.rawValue,
            meetingName: meetingName,
            meetingLatitude: meetingCoordinate.latitude,
            meetingLongitude: meetingCoordinate.longitude
        )
        do {
            try await supabase.from(table).insert(request).execute()
            return request
        } catch {
            return nil
        }
    }

    /// Estado actual de una petición (para el que la creó).
    static func fetch(id: UUID) async -> HelpRequest? {
        try? await supabase
            .from(table)
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    /// Peticiones pendientes cercanas (para ayudantes), ordenadas por distancia.
    static func fetchPending(near center: CLLocationCoordinate2D?, radiusKm: Double = 20) async -> [HelpRequest] {
        let requests: [HelpRequest]? = try? await supabase
            .from(table)
            .select()
            .eq("status", value: HelpRequest.Status.pending.rawValue)
            .order("created_at", ascending: false)
            .limit(25)
            .execute()
            .value
        guard let requests else { return [] }
        guard let center else { return requests }

        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return requests
            .filter { distance(from: here, to: $0) <= radiusKm * 1000 }
            .sorted { distance(from: here, to: $0) < distance(from: here, to: $1) }
    }

    /// Peticiones que este ayudante tiene aceptadas y sin finalizar.
    static func fetchAccepted() async -> [HelpRequest] {
        guard let userId = try? await supabase.auth.session.user.id else { return [] }
        let requests: [HelpRequest]? = try? await supabase
            .from(table)
            .select()
            .eq("status", value: HelpRequest.Status.accepted.rawValue)
            .eq("helper_id", value: userId)
            .execute()
            .value
        return requests ?? []
    }

    /// Acepta una petición (solo si sigue pendiente).
    static func accept(_ request: HelpRequest, helperName: String?) async -> Bool {
        guard let userId = try? await supabase.auth.session.user.id else { return false }
        do {
            try await supabase
                .from(table)
                .update([
                    "status": HelpRequest.Status.accepted.rawValue,
                    "helper_id": userId.uuidString,
                    "helper_name": helperName ?? "Un ayudante"
                ])
                .eq("id", value: request.id)
                .eq("status", value: HelpRequest.Status.pending.rawValue)
                .execute()
            return true
        } catch {
            return false
        }
    }

    static func updateStatus(_ id: UUID, to status: HelpRequest.Status) async {
        _ = try? await supabase
            .from(table)
            .update(["status": status.rawValue])
            .eq("id", value: id)
            .execute()
    }

    /// Distancia del ayudante al punto de encuentro de la petición.
    static func distance(from location: CLLocation, to request: HelpRequest) -> CLLocationDistance {
        let meeting = request.meetingCoordinate
        return location.distance(from: CLLocation(latitude: meeting.latitude, longitude: meeting.longitude))
    }
}
