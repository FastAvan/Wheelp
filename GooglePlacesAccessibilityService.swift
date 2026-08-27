import Foundation
import MapKit
import Supabase

/// Acceso a Google Places vía Edge Function de Supabase.
/// La API key vive como secret en el servidor (GOOGLE_PLACES_API_KEY) y
/// nunca llega al dispositivo ni al binario de la app.
enum GooglePlacesConfig {
    static let isConfigured = true
}

/// Obtiene accesibilidad real de Google Places (campo `accessibilityOptions`).
enum GooglePlacesAccessibilityService {
    struct Result: Sendable {
        let statuses: [String: DestinationAccessibility.Feature.Status]
        let found: Bool
    }

    private struct EdgeRequest: Encodable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    /// Caché en memoria por lugar. Una búsqueda ordena 5 resultados por accesibilidad
    /// (5 llamadas) y la ficha del destino repetía una sexta para el mismo sitio: con el
    /// cap de 10/min del servidor, dos búsquedas agotaban la cuota y todo caía al
    /// fallback lento de OpenStreetMap.
    private actor Cache {
        private var entries: [String: (result: Result, at: Date)] = [:]
        func value(for key: String) -> Result? {
            guard let e = entries[key], Date().timeIntervalSince(e.at) < 600 else { return nil }
            return e.result
        }
        func store(_ result: Result, for key: String) { entries[key] = (result, Date()) }
    }
    private static let cache = Cache()

    static func fetch(near coordinate: CLLocationCoordinate2D, name: String?) async -> Result {
        guard let name, !name.isEmpty else {
            return Result(statuses: [:], found: false)
        }

        // ~11 m de resolución: suficiente para identificar el mismo sitio.
        let key = String(format: "%@|%.4f|%.4f", name, coordinate.latitude, coordinate.longitude)
        if let cached = await cache.value(for: key) { return cached }

        do {
            let data: Data = try await supabase.functions.invoke(
                "google-places",
                options: .init(body: EdgeRequest(
                    name: name,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ))
            )
            let response = try JSONDecoder().decode(PlacesResponse.self, from: data)
            // `places == nil` es un error del servidor (429, 502…), no un "sin datos":
            // no se cachea para que el siguiente intento vuelva a preguntar.
            guard let places = response.places else { return Result(statuses: [:], found: false) }
            let result = places.first?.accessibilityOptions.map { Result(statuses: map($0), found: true) }
                ?? Result(statuses: [:], found: false)
            await cache.store(result, for: key)
            return result
        } catch {
            return Result(statuses: [:], found: false)
        }
    }

    /// Traduce los campos de Google a los criterios de Wheelp.
    private static func map(_ options: AccessibilityOptions) -> [String: DestinationAccessibility.Feature.Status] {
        func status(_ value: Bool?) -> DestinationAccessibility.Feature.Status? {
            guard let value else { return nil }
            return value ? .available : .unavailable
        }

        var result: [String: DestinationAccessibility.Feature.Status] = [:]
        if let entrance = status(options.wheelchairAccessibleEntrance) {
            result["Entrada sin escalones"] = entrance
            result["Acceso general"] = entrance
        }
        if let restroom = status(options.wheelchairAccessibleRestroom) {
            result["Aseo adaptado"] = restroom
            result["Aseos"] = restroom
        }
        if let parking = status(options.wheelchairAccessibleParking) {
            result["Aparcamiento accesible"] = parking
            result["Aparcamiento"] = parking
        }
        return result
    }

    // MARK: - Respuesta JSON

    private struct PlacesResponse: Decodable {
        let places: [Place]?
    }

    private struct Place: Decodable {
        let accessibilityOptions: AccessibilityOptions?
    }

    struct AccessibilityOptions: Decodable {
        let wheelchairAccessibleEntrance: Bool?
        let wheelchairAccessibleParking: Bool?
        let wheelchairAccessibleRestroom: Bool?
        let wheelchairAccessibleSeating: Bool?
    }
}
