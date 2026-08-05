import Foundation
import CoreLocation

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

    static func fetch(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> TransitItinerary? {
        guard GooglePlacesConfig.isConfigured else { return nil }

        let body: [String: Any] = [
            "origin": [
                "location": ["latLng": [
                    "latitude": origin.latitude,
                    "longitude": origin.longitude
                ]]
            ],
            "destination": [
                "location": ["latLng": [
                    "latitude": destination.latitude,
                    "longitude": destination.longitude
                ]]
            ],
            "travelMode": "TRANSIT",
            "languageCode": "es"
        ]

        guard let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GooglePlacesConfig.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "routes.legs.steps.transitDetails,routes.legs.steps.navigationInstruction," +
            "routes.legs.steps.travelMode,routes.legs.steps.distanceMeters," +
            "routes.legs.steps.staticDuration,routes.duration",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(RoutesAPIResponse.self, from: data)
            return response.toItinerary()
        } catch {
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
            return TransitItinerary.Leg(
                mode: isTransit ? .transit : .walk,
                durationSeconds: parseDuration(step.staticDuration) ?? 0,
                distanceMeters: step.distanceMeters ?? 0,
                instruction: instruction,
                vehicleEmoji: vehicleEmoji,
                lineName: step.transitDetails?.transitLine?.name,
                lineShort: step.transitDetails?.transitLine?.nameShort,
                departureStop: step.transitDetails?.stopDetails?.departureStop?.name,
                arrivalStop: step.transitDetails?.stopDetails?.arrivalStop?.name
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
