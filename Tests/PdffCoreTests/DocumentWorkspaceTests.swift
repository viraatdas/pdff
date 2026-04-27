import Foundation
import XCTest
@testable import PdffCore

final class DocumentWorkspaceTests: XCTestCase {
    func testParsesDroppedFileURLData() {
        let url = URL(fileURLWithPath: "/tmp/example.pdf")
        let data = url.dataRepresentation

        XCTAssertEqual(DocumentWorkspace.fileURL(from: data as NSData), url)
    }
}
