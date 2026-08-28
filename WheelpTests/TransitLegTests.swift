import XCTest
import SwiftUI
import CoreLocation
@testable import Wheelp

/// El color de línea y la frase de embarque se construyen a partir de campos
/// opcionales de Google. Si alguno falta, la app debe degradar a algo legible
/// en vez de pintar un color aleatorio o dejar la fila en blanco.
final class TransitLegTests: XCTestCase {

    private func leg(
        vehicleName: String? = "Autobús",
        lineShort: String? = "9",
        lineName: String? = "Puerta del Sol - Hortaleza",
        headsign: String? = "Sol/sevilla",
        stopCount: Int? = 5,
        colorHex: String? = "#0178bc"
    ) -> TransitItinerary.Leg {
        TransitItinerary.Leg(
            mode: .transit,
            durationSeconds: 390,
            distanceMeters: 1500,
            instruction: "Toma el autobús",
            vehicleEmoji: "🚌",
            lineName: lineName,
            lineShort: lineShort,
            departureStop: "Serrano - Diego de León",
            arrivalStop: "Museo Arqueológico",
            departureStopCoordinate: CLLocationCoordinate2D(latitude: 40.4358, longitude: -3.6866),
            arrivalStopCoordinate: CLLocationCoordinate2D(latitude: 40.4230, longitude: -3.6884),
            headsign: headsign,
            stopCount: stopCount,
            departureTimeText: "12:54",
            arrivalTimeText: "13:01",
            vehicleName: vehicleName,
            lineColorHex: colorHex,
            lineTextColorHex: "#ffffff",
            agencyName: "EMT Madrid",
            path: []
        )
    }

    // MARK: Frase de embarque

    func testFraseDeEmbarqueCompleta() {
        XCTAssertEqual(leg().boardingSummary, "Autobús 9 dirección Sol/sevilla")
    }

    func testSinHeadsignNoDejaLaPreposicionColgando() {
        XCTAssertEqual(leg(headsign: nil).boardingSummary, "Autobús 9")
    }

    func testSoloHeadsignEmpiezaEnMayuscula() {
        let summary = leg(vehicleName: nil, lineShort: nil, lineName: nil).boardingSummary
        XCTAssertEqual(summary, "Dirección Sol/sevilla")
    }

    /// Sin ningún dato de línea se recurre a la instrucción de Google en vez de
    /// dejar la fila vacía.
    func testSinDatosCaeEnLaInstruccion() {
        let summary = leg(
            vehicleName: nil, lineShort: nil, lineName: nil, headsign: nil
        ).boardingSummary
        XCTAssertEqual(summary, "Toma el autobús")
    }

    // MARK: Distintivo y paradas

    func testElDistintivoPrefiereElNumeroCorto() {
        XCTAssertEqual(leg().lineBadge, "9")
        XCTAssertEqual(leg(lineShort: nil).lineBadge, "Puerta del Sol - Hortaleza")
        XCTAssertNil(leg(lineShort: nil, lineName: nil).lineBadge)
    }

    func testTextoDeParadasSingularYPlural() {
        XCTAssertEqual(leg(stopCount: 5).stopCountText, "5 paradas")
        XCTAssertEqual(leg(stopCount: 1).stopCountText, "1 parada")
        XCTAssertNil(leg(stopCount: 0).stopCountText)
        XCTAssertNil(leg(stopCount: nil).stopCountText)
    }

    // MARK: Color de línea

    func testHexValidoConYSinAlmohadilla() {
        XCTAssertNotNil(Color(hex: "#0178bc"))
        XCTAssertNotNil(Color(hex: "0178bc"))
        XCTAssertNotNil(Color(hex: "  #FFFFFF  "))
    }

    func testHexInvalidoDevuelveNil() {
        XCTAssertNil(Color(hex: nil))
        XCTAssertNil(Color(hex: ""))
        XCTAssertNil(Color(hex: "#fff"))        // 3 dígitos: no lo usa Google
        XCTAssertNil(Color(hex: "#zzzzzz"))
        XCTAssertNil(Color(hex: "#0178bcff"))   // 8 dígitos con alfa
    }
}
