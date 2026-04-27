import XCTest
@testable import PdffCore

final class MemoryStoreTests: XCTestCase {
    func testNormalizesLabelsForStableSuggestions() {
        XCTAssertEqual(MemoryStore.normalizedLabel("Full Name:"), "full name")
        XCTAssertEqual(MemoryStore.normalizedLabel("Applicant_Email"), "applicant email")
        XCTAssertEqual(MemoryStore.normalizedLabel("Date of Birth (DOB)"), "date of birth dob")
    }
}
