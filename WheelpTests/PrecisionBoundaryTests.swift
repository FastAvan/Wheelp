import XCTest
import CoreLocation
import CryptoKit
@testable import Wheelp

/// Wheelp usa precisión distinta según el caso, y la frontera se aplica al
/// publicar, no al leer el sensor:
///
///   · Navegación paso a paso → exacta, nunca sale del dispositivo.
///   · Punto de encuentro tras aceptar → exacto, pero cifrado E2E.
///   · Zona donde se necesita ayuda, antes de aceptar → ~1 km.
///   · Zona del ayudante mientras tiene turno → ~2 km.
///
/// Estos tests son la evidencia de que las dos últimas se redondean de verdad.
/// Sin ellos, la minimización sería una afirmación de la documentación; con
/// ellos es una propiedad comprobable, que es lo que hay que poder enseñar si
/// alguien pregunta por qué el tratamiento es proporcionado.
final class PrecisionBoundaryTests: XCTestCase {

    /// Puerta del Sol, con precisión de GPS real (7 decimales).
    private let latExacta = 40.4169473
    private let lngExacta = -3.7035285

    // MARK: Zona de la petición (~1 km)

    func testLaZonaDeLaPeticionPierdePrecision() {
        let lat = HelpCrypto.approximate(latExacta)
        XCTAssertNotEqual(lat, latExacta, "Publicar la coordenada exacta delataría el portal")
        XCTAssertEqual(lat, 40.42, accuracy: 0.0001)
    }

    func testDosPuntosCercanosCaenEnLaMismaZona() {
        // ~300 m de separación: deben ser indistinguibles tras redondear.
        XCTAssertEqual(HelpCrypto.approximate(40.4169), HelpCrypto.approximate(40.4192))
    }

    // MARK: Zona del ayudante (~2 km)

    func testLaZonaDelAyudanteEsMasBastaQueLaDeLaPeticion() {
        // La del ayudante se actualiza sola durante horas de turno, así que
        // debe ser al menos tan gruesa como la del solicitante, que se publica
        // una sola vez y por decisión propia.
        let pasoAyudante = distanciaEntreCeldas(HelpCrypto.coarse)
        let pasoPeticion = distanciaEntreCeldas(HelpCrypto.approximate)
        XCTAssertGreaterThan(pasoAyudante, pasoPeticion)
    }

    func testLaCeldaDelAyudanteRondaLos2Km() {
        // 0,02° de latitud ≈ 2,2 km. Se comprueba en metros reales, no en
        // grados, que es lo que importa para el riesgo de reidentificación.
        let metros = distanciaEntreCeldas(HelpCrypto.coarse) * 111_320
        XCTAssertGreaterThan(metros, 1_500, "Una celda menor no protegería lo suficiente")
        XCTAssertLessThan(metros, 3_000, "Una celda mayor degradaría el emparejamiento")
    }

    func testPuntosSeparadosUnKilometroPuedenCaerEnLaMismaCelda() {
        // Con celda de ~2 km, dos posiciones a ~1 km deben poder colapsar.
        let a = HelpCrypto.coarse(40.4100)
        let b = HelpCrypto.coarse(40.4180)
        XCTAssertEqual(a, b)
    }

    // MARK: El camino preciso sigue siendo preciso

    /// El punto de encuentro viaja cifrado y debe conservar la precisión: es lo
    /// que permite que el ayudante encuentre a la persona. Redondearlo aquí
    /// sería tan grave como publicar la zona sin redondear.
    func testElPuntoDeEncuentroNoSeRedondea() {
        let key = SymmetricKey(size: .bits256)
        let detalles = RequesterDetails(
            name: "Álvaro",
            originLatitude: nil, originLongitude: nil,
            destinationLatitude: latExacta, destinationLongitude: lngExacta,
            meetingPoint: "origin", meetingName: nil,
            meetingLatitude: latExacta, meetingLongitude: lngExacta
        )

        guard let sobre = HelpCrypto.sealJSON(detalles, with: key),
              let abierto = HelpCrypto.openJSON(RequesterDetails.self, from: sobre, with: key) else {
            return XCTFail("El sobre cifrado debe abrirse con la clave correcta")
        }
        XCTAssertEqual(abierto.meetingLatitude, latExacta, accuracy: 0.0000001)
        XCTAssertEqual(abierto.meetingLongitude, lngExacta, accuracy: 0.0000001)
    }

    // MARK: Utilidad

    /// Tamaño en grados del salto entre celdas de una función de redondeo.
    private func distanciaEntreCeldas(_ redondear: (Double) -> Double) -> Double {
        var valor = 40.0
        let base = redondear(valor)
        while redondear(valor) == base && valor < 41 { valor += 0.0001 }
        return valor - 40.0
    }
}
