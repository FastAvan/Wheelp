import Foundation
import MapKit
import Supabase

/// Reporte de accesibilidad de un lugar guardado en Supabase (tabla `accessibility_reports`).
struct AccessibilityReport: Codable {
    var placeKey: String
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var disabilityType: String
    var features: [String: String]
    /// Origen del reporte: "community" (usuarios) u "once" (datos oficiales sembrados).
    var source: String?

    enum CodingKeys: String, CodingKey {
        case placeKey = "place_key"
        case placeName = "place_name"
        case latitude
        case longitude
        case disabilityType = "disability_type"
        case features
        case source
    }
}

/// Lectura y aportación de accesibilidad comunitaria en Supabase.
enum AccessibilityService {
    private static let table = "accessibility_reports"

    /// Identificador estable de un lugar: nombre normalizado + coordenadas redondeadas (~11 m).
    static func placeKey(for item: MKMapItem) -> String {
        let coordinate = item.placemark.coordinate
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lon = (coordinate.longitude * 10_000).rounded() / 10_000
        let name = (item.name ?? "")
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        return "\(name)|\(lat)|\(lon)"
    }

    /// Reportes existentes para un lugar y un tipo de discapacidad.
    static func fetchReports(placeKey: String, disabilityType: DisabilityType) async throws -> [AccessibilityReport] {
        try await supabase
            .from(table)
            .select("place_key, place_name, latitude, longitude, disability_type, features, source")
            .eq("place_key", value: placeKey)
            .eq("disability_type", value: disabilityType.rawValue)
            .execute()
            .value
    }

    /// Guarda una aportación del usuario actual (el `user_id` lo pone Supabase con auth.uid()).
    static func submit(
        item: MKMapItem,
        disabilityType: DisabilityType,
        features: [String: DestinationAccessibility.Feature.Status]
    ) async throws {
        let report = AccessibilityReport(
            placeKey: placeKey(for: item),
            placeName: item.name,
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            disabilityType: disabilityType.rawValue,
            features: features.mapValues(\.rawValue),
            source: "community"
        )
        try await supabase.from(table).insert(report).execute()
    }
}
