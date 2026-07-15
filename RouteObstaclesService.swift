import Foundation
import MapKit

/// Obstáculo del camino, obtenido de OpenStreetMap, relevante según la discapacidad.
struct RouteObstacle: Identifiable {
    enum Kind {
        case trafficSignals   // semáforo
        case crossing         // paso de peatones
        case steps            // escaleras
        case kerb             // bordillo alto
        case rail             // paso a nivel
    }

    let id: Int
    let kind: Kind
    let coordinate: CLLocationCoordinate2D

    var title: String {
        switch kind {
        case .trafficSignals: "Semáforo"
        case .crossing: "Paso de peatones"
        case .steps: "Escaleras"
        case .kerb: "Bordillo alto"
        case .rail: "Paso a nivel"
        }
    }

    var icon: String {
        switch kind {
        case .trafficSignals: "light.beacon.max.fill"
        case .crossing: "figure.walk.motion"
        case .steps: "stairs"
        case .kerb: "exclamationmark.triangle.fill"
        case .rail: "tram.fill"
        }
    }

    /// ¿Este obstáculo debe avisarse para esta versión de la app?
    func matters(for type: DisabilityType) -> Bool {
        switch type {
        case .visual: kind == .trafficSignals || kind == .crossing || kind == .steps || kind == .rail
        case .physical: kind == .steps || kind == .kerb || kind == .rail
        case .hearing: kind == .trafficSignals || kind == .crossing || kind == .rail
        case .none: false
        }
    }
}

/// Busca en OpenStreetMap (Overpass API) los obstáculos a lo largo de una ruta:
/// semáforos, pasos de peatones, escaleras, bordillos altos y pasos a nivel.
/// Se consulta una sola vez por ruta; el filtrado por discapacidad se hace después.
enum RouteObstaclesService {
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    static func fetch(along route: MKRoute) async -> [RouteObstacle] {
        let coordinates = sampledCoordinates(of: route.polyline, everyMeters: 80)
        guard coordinates.count >= 2 else { return [] }
        // "around" con una lista de coordenadas busca a ≤25 m de la línea de la ruta.
        let path = coordinates
            .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .joined(separator: ",")
        // Timeout corto: esta consulta ahora participa en la elección de ruta
        // y no debe retrasar el "Ir" más de unos segundos.
        let query = """
        [out:json][timeout:10];
        (
          node(around:25,\(path))[highway~"^(traffic_signals|crossing|steps)$"];
          node(around:25,\(path))[barrier=kerb][kerb=raised];
          node(around:25,\(path))[railway=level_crossing];
          way(around:25,\(path))[highway=steps];
        );
        out center 80;
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            .data(using: .utf8)
        request.timeoutInterval = 12

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(OverpassObstacles.self, from: data)
            return response.elements.compactMap(obstacle(from:))
        } catch {
            return []
        }
    }

    private static func obstacle(from element: OverpassObstacles.Element) -> RouteObstacle? {
        guard let latitude = element.lat ?? element.center?.lat,
              let longitude = element.lon ?? element.center?.lon else { return nil }
        let tags = element.tags ?? [:]

        let kind: RouteObstacle.Kind
        if tags["railway"] == "level_crossing" {
            kind = .rail
        } else if tags["barrier"] == "kerb" {
            kind = .kerb
        } else {
            switch tags["highway"] {
            case "traffic_signals": kind = .trafficSignals
            case "crossing":
                // Un cruce con semáforo cuenta como semáforo.
                kind = tags["crossing"]?.contains("signals") == true ? .trafficSignals : .crossing
            case "steps": kind = .steps
            default: return nil
            }
        }
        return RouteObstacle(
            id: element.id,
            kind: kind,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    /// Puntos de la polilínea espaciados como mínimo `everyMeters` (limitados a
    /// ~120 para que la consulta no crezca demasiado en rutas largas).
    private static func sampledCoordinates(
        of polyline: MKPolyline,
        everyMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        let points = polyline.points()
        let count = polyline.pointCount
        guard count > 0 else { return [] }

        var result: [CLLocationCoordinate2D] = [points[0].coordinate]
        var lastKept = CLLocation(latitude: points[0].coordinate.latitude, longitude: points[0].coordinate.longitude)
        for index in 1..<count {
            let coordinate = points[index].coordinate
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if location.distance(from: lastKept) >= everyMeters {
                result.append(coordinate)
                lastKept = location
                if result.count >= 120 { break }
            }
        }
        // El final de la ruta siempre entra.
        result.append(points[count - 1].coordinate)
        return result
    }
}

/// Respuesta JSON mínima de la Overpass API para nodos y vías con centro.
private struct OverpassObstacles: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let id: Int
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?

        struct Center: Decodable {
            let lat: Double
            let lon: Double
        }
    }
}
