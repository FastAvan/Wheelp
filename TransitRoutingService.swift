import Foundation
import CoreLocation
import Supabase

struct TransitItinerary {
    struct Leg: Identifiable {
        let id = UUID()
        enum Mode { case walk, transit }
        let mode: Mode
        let durationSeconds: Int
        let distanceMeters: Int
        let instruction: String
        let vehicleEmoji: String
        let lineName: String?
        let lineShort: String?
        let departureStop: String?
        let arrivalStop: String?
        /// Coordenada de la parada de salida (nil para tramos a pie).
        let departureStopCoordinate: CLLocationCoordinate2D?
    }

    let legs: [Leg]
    let totalDurationSeconds: Int

    var formattedDuration: String {
        let minutes = max(1, (totalDurationSeconds + 59) / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

enum TransitRoutingService {

    private struct EdgeRequest: Encodable {
        let originLat: Double
        let originLng: Double
        let destLat: Double
        let destLng: Double
    }

    static func fetch(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TransitItinerary? {
        guard GooglePlacesConfig.isConfigured else { return nil }

        do {
            // OJO: no pedir `Data` a invoke(). `Data` conforma a Decodable, así que el
            // compilador elige la sobrecarga genérica e intenta decodificar el JSON
            // como un Data en base64 — lanza siempre. Hay que decodificar directamente
            // al tipo de respuesta, o usar la sobrecarga con `decode:`.
            let response: RoutesAPIResponse = try await supabase.functions.invoke(
                "google-routes",
                options: .init(body: EdgeRequest(
                    originLat: origin.latitude,
                    originLng: origin.longitude,
                    destLat: destination.latitude,
                    destLng: destination.longitude
                ))
            )
            return response.toItinerary()
        } catch {
            print("[Wheelp] google-routes falló: \(error)")
            return nil
        }
    }
}

// MARK: - Google Routes API response

private struct RoutesAPIResponse: Decodable {
    let routes: [Route]?

    struct Route: Decodable {
        let legs: [Leg]?
        let duration: String?
    }
    struct Leg: Decodable {
        let steps: [Step]?
    }
    struct Step: Decodable {
        let travelMode: String?
        let distanceMeters: Int?
        let staticDuration: String?
        let navigationInstruction: NavInstruction?
        let transitDetails: TransitDetails?
    }
    struct NavInstruction: Decodable {
        let instructions: String?
    }
    struct TransitDetails: Decodable {
        let stopDetails: StopDetails?
        let transitLine: TransitLine?
    }
    struct StopDetails: Decodable {
        let departureStop: Stop?
        let arrivalStop: Stop?
    }
    struct Stop: Decodable {
        let name: String?
        let location: StopLocation?
    }
    struct StopLocation: Decodable {
        let latLng: LatLng?
    }
    struct LatLng: Decodable {
        let latitude: Double
        let longitude: Double
    }
    struct TransitLine: Decodable {
        let name: String?
        let nameShort: String?
        let vehicle: Vehicle?
    }
    struct Vehicle: Decodable {
        let type: String?
    }

    func toItinerary() -> TransitItinerary? {
        guard let route = routes?.first,
              let steps = route.legs?.first?.steps, !steps.isEmpty else { return nil }

        let totalDuration = parseDuration(route.duration) ?? 0
        let legs: [TransitItinerary.Leg] = steps.compactMap { step in
            let isTransit = step.travelMode == "TRANSIT"
            let vehicleEmoji: String
            if isTransit {
                switch step.transitDetails?.transitLine?.vehicle?.type {
                case "SUBWAY", "METRO_RAIL": vehicleEmoji = "🚇"
                case "TRAM":                 vehicleEmoji = "🚊"
                case "RAIL", "HIGH_SPEED_TRAIN", "COMMUTER_TRAIN": vehicleEmoji = "🚆"
                default:                     vehicleEmoji = "🚌"
                }
            } else {
                vehicleEmoji = "🚶"
            }
            let instruction = step.navigationInstruction?.instructions
                ?? (isTransit ? "Toma el transporte" : "Camina")
            let depLatLng = step.transitDetails?.stopDetails?.departureStop?.location?.latLng
            let depCoord: CLLocationCoordinate2D? = depLatLng.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            return TransitItinerary.Leg(
                mode: isTransit ? .transit : .walk,
                durationSeconds: parseDuration(step.staticDuration) ?? 0,
                distanceMeters: step.distanceMeters ?? 0,
                instruction: instruction,
                vehicleEmoji: vehicleEmoji,
                lineName: step.transitDetails?.transitLine?.name,
                lineShort: step.transitDetails?.transitLine?.nameShort,
                departureStop: step.transitDetails?.stopDetails?.departureStop?.name,
                arrivalStop: step.transitDetails?.stopDetails?.arrivalStop?.name,
                departureStopCoordinate: depCoord
            )
        }
        guard !legs.isEmpty else { return nil }
        return TransitItinerary(legs: legs, totalDurationSeconds: totalDuration)
    }

    private func parseDuration(_ s: String?) -> Int? {
        guard let s, s.hasSuffix("s"), let v = Int(s.dropLast()) else { return nil }
        return v
    }
}
