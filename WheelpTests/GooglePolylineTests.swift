import XCTest
import CoreLocation
@testable import Wheelp

/// El decodificador de polilíneas es el punto donde un fallo pasaría inadvertido:
/// si devolviera coordenadas erróneas, la navegación en transporte avanzaría de
/// tramo en momentos equivocados sin que nada pareciera roto.
final class GooglePolylineTests: XCTestCase {

    /// Ejemplo canónico de la documentación de Google:
    /// `_p~iF~ps|U_ulLnnqC_mqNvxq`@` → (38.5, -120.2), (40.7, -120.95), (43.252, -126.453)
    func testDecodificaElEjemploDeLaDocumentacionDeGoogle() {
        let coords = GooglePolyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")

        XCTAssertEqual(coords.count, 3)
        guard coords.count == 3 else { return }

        XCTAssertEqual(coords[0].latitude, 38.5, accuracy: 0.00001)
        XCTAssertEqual(coords[0].longitude, -120.2, accuracy: 0.00001)
        XCTAssertEqual(coords[1].latitude, 40.7, accuracy: 0.00001)
        XCTAssertEqual(coords[1].longitude, -120.95, accuracy: 0.00001)
        XCTAssertEqual(coords[2].latitude, 43.252, accuracy: 0.00001)
        XCTAssertEqual(coords[2].longitude, -126.453, accuracy: 0.00001)
    }

    func testCadenaVaciaDevuelveListaVacia() {
        XCTAssertTrue(GooglePolyline.decode("").isEmpty)
    }

    /// Una cadena truncada a la mitad de un valor no debe colgar ni petar:
    /// se descarta el resto y se devuelve lo que se pudo leer.
    func testCadenaTruncadaNoRompe() {
        let completa = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        let truncada = String(completa.prefix(completa.count - 2))
        let coords = GooglePolyline.decode(truncada)
        XCTAssertLessThan(coords.count, 3)
    }

    func testCaracteresInvalidosNoRompen() {
        XCTAssertTrue(GooglePolyline.decode("   ").isEmpty)
    }

    /// Un solo punto: el primer par siempre es delta respecto a (0,0).
    func testUnSoloPunto() {
        let coords = GooglePolyline.decode("_p~iF~ps|U")
        XCTAssertEqual(coords.count, 1)
        XCTAssertEqual(coords.first?.latitude ?? 0, 38.5, accuracy: 0.00001)
        XCTAssertEqual(coords.first?.longitude ?? 0, -120.2, accuracy: 0.00001)
    }
}
