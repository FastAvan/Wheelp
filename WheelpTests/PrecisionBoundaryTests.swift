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
        // debe ser más gruesa que la del solicitante, que se publica una sola
        // vez y por decisión propia.
        XCTAssertGreaterThan(ladoDeCelda(HelpCrypto.coarse),
                             ladoDeCelda(HelpCrypto.approximate))
    }

    func testLaCeldaDelAyudanteRondaLos2Km() {
        // Se comprueba en metros reales, no en grados: es lo que importa para
        // el riesgo de reidentificación.
        let metros = ladoDeCelda(HelpCrypto.coarse) * 111_320
        XCTAssertGreaterThan(metros, 1_500, "Una celda menor no protegería lo suficiente")
        XCTAssertLessThan(metros, 3_000, "Una celda mayor degradaría el emparejamiento")
    }

    /// Dos posiciones dentro de la misma celda deben publicarse idénticas.
    ///
    /// Se toman a ambos lados del centro de una celda a propósito: puntos
    /// cercanos que caen sobre una frontera SÍ se separan, y eso es inherente a
    /// cualquier rejilla, no un defecto. Lo que garantiza el anonimato no es que
    /// dos puntos cualesquiera colapsen, sino que el resultado no permita
    /// distinguir dónde está alguien dentro de una celda de ~2 km.
    func testDosPosicionesDeLaMismaCeldaSePublicanIguales() {
        let centro = HelpCrypto.coarse(40.41)
        let lado = ladoDeCelda(HelpCrypto.coarse)
        let a = centro - lado / 4      // dentro, a la izquierda del centro
        let b = centro + lado / 4      // dentro, a la derecha
        XCTAssertEqual(HelpCrypto.coarse(a), HelpCrypto.coarse(b),
                       "Dentro de la misma celda no debe poder distinguirse la posición")
    }

    /// La salida siempre cae en la rejilla, sin valores intermedios que
    /// filtrarían precisión.
    func testLaSalidaSiempreCaeEnLaRejilla() {
        let lado = ladoDeCelda(HelpCrypto.coarse)
        for paso in 0..<200 {
            let entrada = 40.0 + Double(paso) * 0.0013   // valores arbitrarios
            let salida = HelpCrypto.coarse(entrada)
            let resto = (salida / lado).rounded() * lado
            XCTAssertEqual(salida, resto, accuracy: 1e-9,
                           "coarse(\(entrada)) devolvió \(salida), fuera de la rejilla")
        }
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

    /// Lado de la celda, en grados: la separación entre dos SALIDAS distintas
    /// consecutivas.
    ///
    /// Ojo, que es donde me equivoqué la primera vez: medir desde el centro de
    /// una celda hasta que cambia la salida da la MEDIA celda, no la celda. Hay
    /// que comparar salidas entre sí, no entradas contra su salida.
    private func ladoDeCelda(_ redondear: (Double) -> Double) -> Double {
        var valor = 40.0
        let primera = redondear(valor)
        var segunda = primera
        while segunda == primera && valor < 41 {
            valor += 0.0001
            segunda = redondear(valor)
        }
        var tercera = segunda
        while tercera == segunda && valor < 42 {
            valor += 0.0001
            tercera = redondear(valor)
        }
        return abs(tercera - segunda)
    }
}
