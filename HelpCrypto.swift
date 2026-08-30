import Foundation
import CryptoKit
import Security

/// Contenido cifrado que envía quien pide ayuda (solo tras la aceptación):
/// su nombre y el trayecto exacto.
struct RequesterDetails: Codable {
    var name: String?
    var originLatitude: Double?
    var originLongitude: Double?
    var destinationLatitude: Double
    var destinationLongitude: Double
    var meetingPoint: String
    var meetingName: String?
    var meetingLatitude: Double
    var meetingLongitude: Double
}

/// Contenido cifrado que envía el ayudante al aceptar (su nombre).
struct HelperDetails: Codable {
    var name: String?
}

/// Cifrado de extremo a extremo de la red de ayuda.
///
/// El servidor solo ve claves públicas, una zona aproximada (~1 km), el lugar
/// de destino y texto cifrado. Cada petición usa un par de claves efímeras
/// (Curve25519); al aceptar, ambos dispositivos derivan la misma clave secreta
/// (X25519 + HKDF) sin que el servidor pueda conocerla, y con ella se cifran
/// nombres, trayecto exacto y mensajes (AES-GCM). Las claves privadas viven en
/// el Llavero del dispositivo y se borran al terminar.
enum HelpCrypto {

    // MARK: - Claves privadas por petición (Llavero del dispositivo)

    private static func keychainQuery(for requestId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "wheelp.help-key",
            kSecAttrAccount as String: requestId.uuidString
        ]
    }

    static func savePrivateKey(_ key: Curve25519.KeyAgreement.PrivateKey, for requestId: UUID) {
        var query = keychainQuery(for: requestId)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = key.rawRepresentation
        SecItemAdd(query as CFDictionary, nil)
    }

    static func privateKey(for requestId: UUID) -> Curve25519.KeyAgreement.PrivateKey? {
        var query = keychainQuery(for: requestId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Borra la clave y el detalle pendiente de una petición terminada.
    static func forget(requestId: UUID) {
        SecItemDelete(keychainQuery(for: requestId) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: pendingKey(requestId))
    }

    /// Borra todas las claves privadas del llavero (para eliminación de cuenta).
    static func clearAllKeys() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "wheelp.help-key"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Clave simétrica compartida (X25519 + HKDF)

    static func symmetricKey(
        requestId: UUID,
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        otherPublicKeyBase64: String
    ) -> SymmetricKey? {
        guard let pubData = Data(base64Encoded: otherPublicKeyBase64),
              let otherKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData),
              let shared = try? myPrivateKey.sharedSecretFromKeyAgreement(with: otherKey) else {
            return nil
        }
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(requestId.uuidString.utf8),
            sharedInfo: Data("wheelp-help".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Cifrar / descifrar

    static func seal(_ data: Data, with key: SymmetricKey) -> String? {
        (try? AES.GCM.seal(data, using: key))?.combined?.base64EncodedString()
    }

    static func open(_ base64: String, with key: SymmetricKey) -> Data? {
        guard let data = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func sealJSON<T: Encodable>(_ value: T, with key: SymmetricKey) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return seal(data, with: key)
    }

    static func openJSON<T: Decodable>(_ type: T.Type, from base64: String?, with key: SymmetricKey) -> T? {
        guard let base64, let data = open(base64, with: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Detalle del solicitante, guardado localmente hasta que acepten

    private static func pendingKey(_ id: UUID) -> String { "wheelp.help-pending.\(id.uuidString)" }

    static func savePendingDetails(_ details: RequesterDetails, for requestId: UUID) {
        if let data = try? JSONEncoder().encode(details) {
            UserDefaults.standard.set(data, forKey: pendingKey(requestId))
        }
    }

    static func pendingDetails(for requestId: UUID) -> RequesterDetails? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey(requestId)) else { return nil }
        return try? JSONDecoder().decode(RequesterDetails.self, from: data)
    }

    // MARK: - Zona aproximada para el descubrimiento

    /// Redondea una coordenada a ~1 km para publicarla sin revelar el punto exacto.
    static func approximate(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Rejilla más gruesa (~2 km) para la zona del ayudante mientras tiene turno.
    ///
    /// Es más basta que `approximate` a propósito: la del solicitante se publica
    /// una vez y por su propia petición, mientras que la del ayudante se
    /// actualiza sola durante horas, y ahí el riesgo de inferir su domicilio o
    /// sus rutinas es mucho mayor. 0,02° son ~2,2 km en latitud y ~1,7 km en
    /// longitud a la altura de Madrid.
    ///
    /// La pérdida de precisión se compensa sumando `gridPaddingKm` al radio de
    /// búsqueda: mejor avisar a alguno de más que perder a quien sí podía ayudar.
    static func coarse(_ value: Double) -> Double {
        (value * 50).rounded() / 50
    }

    // MARK: - Código de verificación del encuentro

    /// Código de 6 dígitos derivado de la clave simétrica compartida mediante HMAC.
    /// Ambos dispositivos (solicitante y ayudante) calculan el mismo resultado
    /// de forma independiente: confirmar que coincide prueba que se están comunicando
    /// con la persona correcta, sin necesidad de ningún servidor.
    static func meetingCode(from key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("wheelp.meeting.code.v1".utf8),
            using: key
        )
        let value = Data(mac).prefix(4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        return String(format: "%06d", value % 1_000_000)
    }
}
