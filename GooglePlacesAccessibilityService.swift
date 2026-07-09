import Foundation
import MapKit

/// Clave de la API de Google Places (New).
///
/// 👉 Pega aquí tu clave: Google Cloud Console → APIs y servicios → Credenciales.
///    Necesitas habilitar "Places API (New)" y tener facturación activada.
enum GooglePlacesConfig {
    static let apiKey = "AIzaSyDm6WjEJaGzbjnUNSQIDTqTh1N1zzRXgCQ"

    static var isConfigured: Bool {
        !apiKey.isEmpty && apiKey != "TU_API_KEY_DE_GOOGLE"
    }
}

/// Obtiene accesibilidad real de Google Places (campo `accessibilityOptions`).
enum GooglePlacesAccessibilityService {
    struct Result {
        let statuses: [String: DestinationAccessibility.Feature.Status]
        let found: Bool
    }

    private static let endpoint = URL(string: "https://places.googleapis.com/v1/places:searchText")!

    static func fetch(near coordinate: CLLocationCoordinate2D, name: String?) async -> Result {
        guard GooglePlacesConfig.isConfigured, let name, !name.isEmpty else {
            return Result(statuses: [:], found: false)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GooglePlacesConfig.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.displayName,places.accessibilityOptions",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        let body: [String: Any] = [
            "textQuery": name,
            "languageCode": "es",
            "maxResultCount": 1,
            "locationBias": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": 500.0
                ]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
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
