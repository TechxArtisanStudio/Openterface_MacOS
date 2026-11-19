import XCTest
@testable import openterface

final class SerialPortSelectionTests: XCTestCase {
    private let kvmPort = "/dev/cu.usbserial-14120"
    private let monitorPort = "/dev/cu.usbmodem510NTYTNF6182"
    private let kvmLocation = "0x02200000"
    private let monitorLocation = "0x01100000"

    func testMatchesExpectedLocationInsteadOfFirstPort() {
        let candidates = [
            (port: monitorPort, locationID: monitorLocation),
            (port: kvmPort, locationID: kvmLocation),
        ]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation)

        XCTAssertEqual(selected, kvmPort)
    }

    func testSingleWrongDeviceIsRejected() {
        let candidates = [(port: monitorPort, locationID: monitorLocation)]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation)

        XCTAssertNil(selected)
    }

    func testNoMatchingIdentityReturnsNilForRetry() {
        let candidates = [
            (port: monitorPort, locationID: monitorLocation),
            (port: "/dev/cu.usbserial-other", locationID: "0x03300000"),
        ]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation)

        XCTAssertNil(selected)
    }

    func testMatchWinsEvenWhenOtherIdentitiesAreUnresolved() {
        let candidates: [(port: String, locationID: String?)] = [
            (port: monitorPort, locationID: nil),
            (port: kvmPort, locationID: kvmLocation),
        ]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation)

        XCTAssertEqual(selected, kvmPort)
    }

    func testNoExpectedLocationFallsBackToFirstPort() {
        let candidates = [
            (port: monitorPort, locationID: monitorLocation),
            (port: kvmPort, locationID: kvmLocation),
        ]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: nil)

        XCTAssertEqual(selected, monitorPort)
    }

    func testUnresolvedIdentitiesFallBackToFirstPort() {
        let candidates: [(port: String, locationID: String?)] = [
            (port: monitorPort, locationID: nil),
            (port: kvmPort, locationID: nil),
        ]

        let selected = SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation)

        XCTAssertEqual(selected, monitorPort)
    }

    func testEmptyCandidatesReturnsNil() {
        let candidates: [(port: String, locationID: String?)] = []

        XCTAssertNil(SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: kvmLocation))
        XCTAssertNil(SerialPortManager.selectSerialPort(candidates: candidates, expectedLocationID: nil))
    }
}