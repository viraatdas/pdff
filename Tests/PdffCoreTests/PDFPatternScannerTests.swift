import XCTest
@testable import PdffCore

final class PDFPatternScannerTests: XCTestCase {
    func testDetectsLabelledTextAndDateBlanks() {
        let text = """
        Full Name: ______________________
        Date: ________________
        """

        let fields = PDFPatternScanner.scan(text)

        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].label, "Full Name")
        XCTAssertEqual(fields[0].kind, .text)
        XCTAssertEqual(fields[1].label, "Date")
        XCTAssertEqual(fields[1].kind, .date)
    }

    func testDetectsCheckboxLabels() {
        let fields = PDFPatternScanner.scan("☐ Married\n[ ] Single\n")

        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].kind, .checkbox)
        XCTAssertEqual(fields[0].label, "Married")
        XCTAssertEqual(fields[1].kind, .checkbox)
        XCTAssertEqual(fields[1].label, "Single")
    }

    func testStandaloneBlankUsesLinePrefixAsLabel() {
        let fields = PDFPatternScanner.scan("Applicant phone __________________")

        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].label, "Applicant phone")
    }
}
