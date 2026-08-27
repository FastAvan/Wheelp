import SwiftUI
import MapKit

/// Información de accesibilidad de un destino, adaptada al perfil del usuario.
/// Se construye con datos reales de una fuente externa (Google Places, y como
/// respaldo OpenStreetMap) y, opcionalmente, con aportaciones de la comunidad.
struct DestinationAccessibility {
    struct Feature: Identifiable {
        enum Status: String, CaseIterable, Sendable {
            case available
            case limited
            case unavailable
            case unknown

            var icon: String {
                switch self {
                case .available: "checkmark.circle.fill"
                case .limited: "exclamationmark.circle.fill"
                case .unavailable: "xmark.circle.fill"
                case .unknown: "questionmark.circle"
                }
            }
            var color: Color {
                switch self {
                case .available: .wheelpGreen
                case .limited: .orange
                case .unavailable: .red
                case .unknown: .secondary
                }
            }
            var label: String {
                switch self {
                case .available: "Disponible"
                case .limited: "Limitado"
                case .unavailable: "No disponible"
                case .unknown: "Sin datos"
                }
            }
        }

        let id = UUID()
        let icon: String
        let title: String
        let status: Status
    }

    let features: [Feature]
    /// Puntuación 0–100 de accesibilidad para el perfil.
    let score: Int
    /// Número de aportaciones de la comunidad en las que se basa.
    let reportCount: Int
    /// Nombre de la fuente externa con datos (p. ej. "Google Places"), si la hay.
    let externalSource: String?
    /// Fuente oficial con datos (p. ej. "Fundación ONCE"), si la hay.
    let officialSource: String?

    var hasExternalData: Bool { externalSource != nil }
    var hasData: Bool { hasExternalData || reportCount > 0 }
    /// Si hay al menos un criterio con información (no todo "sin datos").
    var hasAnyKnownFeature: Bool { features.contains { $0.status != .unknown } }

    var scoreColor: Color { Self.scoreColor(score) }

    /// Color de una puntuación 0–100 (también para insignias en búsquedas).
    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 70...: .wheelpGreen
        case 40..<70: .orange
        default: .red
        }
    }

    /// Texto que explica el origen de los datos.
    var sourceNote: String {
        guard hasAnyKnownFeature else {
            return "Sin datos de accesibilidad para esta versión todavía. ¡Puedes aportarlos!"
        }
        var sources: [String] = []
        if let officialSource { sources.append("datos de \(officialSource)") }
        if let externalSource { sources.append("datos de \(externalSource)") }
        if reportCount > 0 {
            sources.append("\(reportCount) aportación\(reportCount == 1 ? "" : "es") de la comunidad")
        }
        guard !sources.isEmpty else {
            return "Aún no hay datos de accesibilidad. ¡Sé el primero en aportar!"
        }
        return "Basado en " + sources.joined(separator: " y ") + "."
    }

    // MARK: - Construcción

    /// Plantilla sin datos: todos los criterios del perfil en "sin datos".
    static func empty(for profile: AccessibilityProfile) -> DestinationAccessibility {
        let features = criteria(for: profile.type).map {
            Feature(icon: $0.icon, title: $0.title, status: .unknown)
        }
        return DestinationAccessibility(
            features: features, score: 0, reportCount: 0, externalSource: nil, officialSource: nil
        )
    }

    /// Combina datos oficiales (ONCE), de la fuente externa (Google/OSM) y de la
    /// comunidad. Prioridad por criterio: oficial → comunidad → fuente externa.
    static func combined(
        base: [String: Feature.Status],
        sourceName: String?,
        reports: [AccessibilityReport],
        profile: AccessibilityProfile
    ) -> DestinationAccessibility {
        let officialReports = reports.filter { ($0.source ?? "community") == "once" }
        let communityReports = reports.filter { ($0.source ?? "community") != "once" }

        func majorityStatus(_ list: [AccessibilityReport], _ title: String) -> Feature.Status? {
            majority(of: list.compactMap { Feature.Status(rawValue: $0.features[title] ?? "") })
        }

        let features = criteria(for: profile.type).map { spec -> Feature in
            let official = majorityStatus(officialReports, spec.title)
            let community = majorityStatus(communityReports, spec.title)
            let status: Feature.Status
            if let official, official != .unknown {
                status = official
            } else if let community, community != .unknown {
                status = community
            } else {
                status = base[spec.title] ?? .unknown
            }
            return Feature(icon: spec.icon, title: spec.title, status: status)
        }
        let available = features.filter { $0.status == .available }.count
        let score = features.isEmpty ? 0 : Int(Double(available) / Double(features.count) * 100)
        return DestinationAccessibility(
            features: features,
            score: score,
            reportCount: communityReports.count,
            externalSource: base.isEmpty ? nil : sourceName,
            officialSource: officialReports.isEmpty ? nil : "Fundación ONCE"
        )
    }

    private static func majority(of statuses: [Feature.Status]) -> Feature.Status? {
        guard !statuses.isEmpty else { return nil }
        let counts = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    /// Traduce las etiquetas OpenStreetMap a estados por criterio (respaldo gratuito).
    static func osmStatuses(for profile: AccessibilityProfile, tags: [String: String]) -> [String: Feature.Status] {
        var map: [String: Feature.Status] = [:]
        for spec in criteria(for: profile.type) {
            if let status = osmStatus(for: spec.title, tags: tags) {
                map[spec.title] = status
            }
        }
        return map
    }

    private static func osmStatus(for title: String, tags: [String: String]) -> Feature.Status? {
        func value(_ key: String) -> Feature.Status? {
            guard let raw = tags[key]?.lowercased() else { return nil }
            switch raw {
            case "yes", "designated", "official": return .available
            case "limited", "partial": return .limited
            case "no", "none": return .unavailable
            default: return nil
            }
        }
        switch title {
        case "Entrada sin escalones", "Acceso general": return value("wheelchair")
        case "Ascensor": return value("elevator")
        case "Aseo adaptado": return value("toilets:wheelchair")
        case "Aseos": return value("toilets:wheelchair") ?? value("toilets")
        case "Aparcamiento accesible": return value("parking:wheelchair")
        case "Aparcamiento": return value("parking")
        case "Señalización en braille": return value("braille")
        case "Pavimento podotáctil": return value("tactile_paving")
        case "Audioguía": return value("audio_description") ?? value("audio_loop")
        case "Admite perro guía":
            if let raw = tags["dog"]?.lowercased() { return raw == "no" ? .unavailable : .available }
            return value("service_dog")
        case "Bucle magnético": return value("hearing_loop") ?? value("induction_loop")
        default: return nil
        }
    }

    /// Criterios de accesibilidad relevantes para cada versión.
    static func criteria(for type: DisabilityType) -> [(icon: String, title: String)] {
        switch type {
        case .physical:
            [("figure.roll", "Entrada sin escalones"),
             ("arrow.up.arrow.down.square", "Ascensor"),
             ("toilet", "Aseo adaptado"),
             ("parkingsign", "Aparcamiento accesible")]
        case .visual:
            [("hand.point.up.braille.fill", "Señalización en braille"),
             ("shoeprints.fill", "Pavimento podotáctil"),
             ("speaker.wave.2.fill", "Audioguía"),
             ("pawprint.fill", "Admite perro guía")]
        case .hearing:
            [("ear.badge.checkmark", "Bucle magnético"),
             ("bell.badge.fill", "Avisos visuales"),
             ("captions.bubble.fill", "Subtítulos / pantallas"),
             ("text.bubble.fill", "Atención por texto")]
        case .none:
            [("checkmark.seal.fill", "Acceso general"),
             ("toilet", "Aseos"),
             ("parkingsign", "Aparcamiento")]
        }
    }
}
