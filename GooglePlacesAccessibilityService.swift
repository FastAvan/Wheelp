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
    struct Result {
        let statuses: [String: DestinationAccessibility.Feature.Status]
        let found: Bool
    }

    private struct EdgeRequest: Encodable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    static func fetch(near coordinate: CLLocationCoordinate2D, name: String?) async -> Result {
        guard let name, !name.isEmpty else {
            return Result(statuses: [:], found: false)
        }

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
            guard let options = response.places?.first?.accessibilityOptions else {
                return Result(statuses: [:], found: false)
            }
            return Result(statuses: map(options), found: true)
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
