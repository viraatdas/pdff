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
        let fields = PDFPatternScanner.scan("☐ Married\n[ ] Single\n□ Citizen\n◻ Authorized\n")

        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0].kind, .checkbox)
        XCTAssertEqual(fields[0].label, "Married")
        XCTAssertEqual(fields[1].kind, .checkbox)
        XCTAssertEqual(fields[1].label, "Single")
        XCTAssertEqual(fields[2].kind, .checkbox)
        XCTAssertEqual(fields[2].label, "Citizen")
        XCTAssertEqual(fields[3].kind, .checkbox)
        XCTAssertEqual(fields[3].label, "Authorized")
    }

    func testStandaloneBlankUsesLinePrefixAsLabel() {
        let fields = PDFPatternScanner.scan("Applicant phone __________________")

        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].label, "Applicant phone")
    }

    func testDetectsLabelOnlyOpenings() {
        let fields = PDFPatternScanner.scan("Name:\nDate of Birth:\nAddress:\n")

        XCTAssertEqual(fields.count, 3)
        guard fields.count == 3 else { return }
        XCTAssertEqual(fields[0].label, "Name")
        XCTAssertTrue(fields[0].isLabelOnly)
        XCTAssertEqual(fields[1].label, "Date of Birth")
        XCTAssertEqual(fields[1].kind, .date)
        XCTAssertEqual(fields[2].label, "Address")
    }
}
