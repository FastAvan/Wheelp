import Foundation
import CoreLocation
import SwiftUI
import Supabase

extension Color {
    /// Color a partir de un hex de 6 dígitos como los que publica Google para
    /// las líneas de transporte ("#0178bc"). nil si la cadena no es válida, para
    /// poder caer en un color por defecto en vez de pintar algo aleatorio.
    init?(hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

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
        /// Coordenada de la parada de llegada (nil para tramos a pie).
        let arrivalStopCoordinate: CLLocationCoordinate2D?
        /// Sentido rotulado en el vehículo ("Sol/sevilla"). Es lo que hay que
        /// mirar en la marquesina para no coger la línea en dirección contraria.
        let headsign: String?
        /// Cuántas paradas hay que aguantar hasta bajarse.
        let stopCount: Int?
        /// Horas ya formateadas en la zona del viaje ("12:54").
        let departureTimeText: String?
        let arrivalTimeText: String?
        /// Tipo de vehículo en palabras ("Autobús", "Metro").
        let vehicleName: String?
        /// Color oficial de la línea, para el distintivo.
        let lineColorHex: String?
        let lineTextColorHex: String?
        /// Operador ("Empresa Municipal de Transportes de Madrid").
        let agencyName: String?
        /// Geometría del tramo, decodificada de la polilínea de Google. Permite
        /// seguir el avance por GPS también en los tramos a pie, donde no hay
        /// paradas a las que agarrarse.
        let path: [CLLocationCoordinate2D]

        /// Punto donde termina este tramo: la parada de llegada si es transporte,
        /// o el final de la geometría si se va a pie.
        var endCoordinate: CLLocationCoordinate2D? {
            arrivalStopCoordinate ?? path.last
        }

        /// Distintivo de la línea: el número corto si lo hay ("9", "L4").
        var lineBadge: String? { lineShort ?? lineName }

        /// Color oficial de la línea; verde Wheelp si el operador no publica uno.
        var lineColor: Color { Color(hex: lineColorHex) ?? .wheelpGreen }
        var lineTextColor: Color { Color(hex: lineTextColorHex) ?? .white }

        /// "Autobús 9 hacia Sol/sevilla" — la frase que resuelve qué coger.
        var boardingSummary: String {
            var parts: [String] = []
            if let vehicleName { parts.append(vehicleName) }
            if let badge = lineBadge { parts.append(badge) }
            var text = parts.joined(separator: " ")
            if let headsign, !headsign.isEmpty {
                text += text.isEmpty ? "Dirección \(headsign)" : " dirección \(headsign)"
            }
            return text.isEmpty ? instruction : text
        }

        /// "5 paradas" / "1 parada".
        var stopCountText: String? {
            guard let stopCount, stopCount > 0 else { return nil }
            return stopCount == 1 ? "1 parada" : "\(stopCount) paradas"
        }
    }

    let legs: [Leg]
    let totalDurationSeconds: Int

    var formattedDuration: String {
        let minutes = max(1, (totalDurationSeconds + 59) / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Decodifica el formato de polilínea codificada de Google (mismo algoritmo que
/// usan Directions y Routes). Devuelve [] si la cadena está corrupta.
enum GooglePolyline {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lng = 0

        while index < encoded.endIndex {
            // Cada valor va codificado en grupos de 5 bits con acarreo en el bit 6,
            // en zig-zag y como delta respecto al punto anterior.
            func nextValue() -> Int? {
                var shift = 0, result = 0
                while index < encoded.endIndex {
                    guard let ascii = encoded[index].asciiValue else { return nil }
                    let byte = Int(ascii) - 63
                    guard byte >= 0 else { return nil }
                    index = encoded.index(after: index)
                    result |= (byte & 0x1F) << shift
                    shift += 5
                    if byte < 0x20 {
                        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                    }
                    if shift > 30 { return nil }
                }
                return nil
            }
            guard let dLat = nextValue(), let dLng = nextValue() else { break }
            lat += dLat
            lng += dLng
            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            ))
        }
        return coordinates
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
        let polyline: Polyline?
    }
    struct Polyline: Decodable {
        let encodedPolyline: String?
    }
    struct NavInstruction: Decodable {
        let instructions: String?
    }
    struct TransitDetails: Decodable {
        let stopDetails: StopDetails?
        let transitLine: TransitLine?
        let headsign: String?
        let stopCount: Int?
        let localizedValues: LocalizedValues?
    }
    struct LocalizedValues: Decodable {
        let departureTime: LocalizedTime?
        let arrivalTime: LocalizedTime?
    }
    struct LocalizedTime: Decodable {
        let time: LocalizedText?
    }
    struct LocalizedText: Decodable {
        let text: String?
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
        let color: String?
        let textColor: String?
        let agencies: [Agency]?
    }
    struct Agency: Decodable {
        let name: String?
    }
    struct Vehicle: Decodable {
        let type: String?
        let name: LocalizedText?
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
            func coordinate(_ stop: Stop?) -> CLLocationCoordinate2D? {
                stop?.location?.latLng.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
            }
            let details = step.transitDetails
            let stops = details?.stopDetails
            let line = details?.transitLine
            return TransitItinerary.Leg(
                mode: isTransit ? .transit : .walk,
                durationSeconds: parseDuration(step.staticDuration) ?? 0,
                distanceMeters: step.distanceMeters ?? 0,
                instruction: instruction,
                vehicleEmoji: vehicleEmoji,
                lineName: line?.name,
                lineShort: line?.nameShort,
                departureStop: stops?.departureStop?.name,
                arrivalStop: stops?.arrivalStop?.name,
                departureStopCoordinate: coordinate(stops?.departureStop),
                arrivalStopCoordinate: coordinate(stops?.arrivalStop),
                headsign: details?.headsign,
                stopCount: details?.stopCount,
                departureTimeText: details?.localizedValues?.departureTime?.time?.text,
                arrivalTimeText: details?.localizedValues?.arrivalTime?.time?.text,
                vehicleName: line?.vehicle?.name?.text,
                lineColorHex: line?.color,
                lineTextColorHex: line?.textColor,
                agencyName: line?.agencies?.first?.name,
                path: step.polyline?.encodedPolyline.map(GooglePolyline.decode) ?? []
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
