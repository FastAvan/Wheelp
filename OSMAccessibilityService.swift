import Foundation
import MapKit

/// Obtiene etiquetas de accesibilidad reales de OpenStreetMap usando la Overpass API.
/// No requiere clave. Busca el elemento más cercano al destino (preferiblemente con el
/// mismo nombre) y devuelve sus etiquetas (`wheelchair`, `tactile_paving`, etc.).
enum OSMAccessibilityService {
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    static func fetchTags(near coordinate: CLLocationCoordinate2D, name: String?) async -> [String: String] {
        // Busca nodos/vías/relaciones en ~60 m alrededor del destino.
        let query = """
        [out:json][timeout:20];
        nwr(around:60,\(coordinate.latitude),\(coordinate.longitude));
        out tags center 40;
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            .data(using: .utf8)
        request.timeoutInterval = 20

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
            return bestMatch(in: response.elements, name: name, coordinate: coordinate)?.tags ?? [:]
        } catch {
            return [:]
        }
    }

    /// Elige el elemento que mejor representa el destino: prioriza coincidencia de
    /// nombre y, en su defecto, el más cercano que tenga etiquetas de accesibilidad.
    private static func bestMatch(
        in elements: [OverpassResponse.Element],
        name: String?,
        coordinate: CLLocationCoordinate2D
    ) -> OverpassResponse.Element? {
        let normalizedName = name?
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        let accessibilityKeys = [
            "wheelchair", "tactile_paving", "toilets:wheelchair", "braille",
            "hearing_loop", "induction_loop", "elevator", "parking:wheelchair"
        ]

        func relevance(_ element: OverpassResponse.Element) -> Int {
            guard let tags = element.tags else { return 0 }
            var score = 0
            if let normalizedName,
               let elementName = tags["name"]?.folding(options: .diacriticInsensitive, locale: .current).lowercased(),
               elementName.contains(normalizedName) || normalizedName.contains(elementName) {
                score += 100
            }
            score += accessibilityKeys.filter { tags[$0] != nil }.count
            return score
        }

        return elements
            .filter { ($0.tags?.isEmpty == false) }
            .max { relevance($0) < relevance($1) }
            .flatMap { relevance($0) > 0 ? $0 : nil }
    }
}

/// Respuesta JSON mínima de la Overpass API.
private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
    }
}
