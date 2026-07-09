import Foundation
import MapKit

/// Lugar guardado por el usuario. `kind` distingue favoritos (con alias opcional:
/// "casa", "trabajo"…) de recientes.
struct SavedPlace: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var alias: String?
    var latitude: Double
    var longitude: Double
    var kind: Kind
    var visitedAt: Date

    enum Kind: String, Codable {
        case favorite
        case recent
    }

    /// Título que se muestra/lee: el alias si existe, si no el nombre del lugar.
    var displayTitle: String { alias?.isEmpty == false ? alias! : name }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Reconstruye un MKMapItem para reutilizar el flujo normal de ficha + ruta.
    var mapItem: MKMapItem {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }
}

/// Favoritos e historial del usuario, almacenados EXCLUSIVAMENTE en el
/// dispositivo (archivo JSON en Application Support). Los lugares del usuario
/// (casa, trabajo…) son datos sensibles y nunca deben salir del móvil.
enum SavedPlacesService {
    private static let maxRecents = 5

    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("saved-places.json")
    }

    // MARK: - Persistencia local

    private static func loadAll() -> [SavedPlace] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedPlace].self, from: data)) ?? []
    }

    private static func saveAll(_ places: [SavedPlace]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(places) {
            // Protección de datos del sistema: cifrado en reposo hasta el
            // primer desbloqueo del dispositivo.
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: - API (misma superficie que antes; async para no tocar las vistas)

    /// Favoritos del usuario (alfabético por alias/nombre).
    static func fetchFavorites() async -> [SavedPlace] {
        loadAll()
            .filter { $0.kind == .favorite }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    /// Últimos destinos visitados (máx. `limit`, más recientes primero).
    static func fetchRecents(limit: Int = maxRecents) async -> [SavedPlace] {
        Array(
            loadAll()
                .filter { $0.kind == .recent }
                .sorted { $0.visitedAt > $1.visitedAt }
                .prefix(limit)
        )
    }

    /// Guarda un favorito con alias opcional ("casa", "trabajo"…).
    static func addFavorite(item: MKMapItem, alias: String?) async {
        var places = loadAll()
        places.append(SavedPlace(
            id: UUID(),
            name: item.name ?? "Lugar",
            alias: alias?.trimmingCharacters(in: .whitespaces),
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            kind: .favorite,
            visitedAt: .now
        ))
        saveAll(places)
    }

    static func removeFavorite(_ place: SavedPlace) async {
        saveAll(loadAll().filter { $0.id != place.id })
    }

    /// Registra una visita en el historial al iniciar una ruta.
    /// Si el lugar ya estaba en recientes, actualiza su fecha en vez de duplicarlo.
    static func recordVisit(item: MKMapItem) async {
        let coordinate = item.placemark.coordinate
        let name = item.name ?? "Lugar"
        var places = loadAll()

        if let index = places.firstIndex(where: {
            $0.kind == .recent && $0.name == name
                && abs($0.latitude - coordinate.latitude) < 0.0005
                && abs($0.longitude - coordinate.longitude) < 0.0005
        }) {
            places[index].visitedAt = .now
        } else {
            places.append(SavedPlace(
                id: UUID(),
                name: name,
                alias: nil,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                kind: .recent,
                visitedAt: .now
            ))
        }

        // Mantén solo los recientes más nuevos para que el archivo no crezca.
        let recents = places.filter { $0.kind == .recent }.sorted { $0.visitedAt > $1.visitedAt }
        let toDrop = Set(recents.dropFirst(maxRecents * 2).map(\.id))
        saveAll(places.filter { !toDrop.contains($0.id) })
    }

    /// Busca un favorito que coincida con lo dicho por el usuario ("casa",
    /// "llévame al trabajo"…). Coincide por alias o nombre, sin acentos.
    static func match(_ spokenText: String, in favorites: [SavedPlace]) -> SavedPlace? {
        let normalized = normalize(spokenText)
        guard !normalized.isEmpty else { return nil }
        return favorites.first { place in
            let alias = normalize(place.alias ?? "")
            let name = normalize(place.name)
            if !alias.isEmpty, normalized.contains(alias) || alias.contains(normalized) {
                return true
            }
            return normalized.contains(name) || name.contains(normalized)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }
}
