import Foundation
import CoreGraphics
import PDFKit
import XCTest
@testable import PdffCore

final class DocumentWorkspaceTests: XCTestCase {
    func testParsesDroppedFileURLData() {
        let url = URL(fileURLWithPath: "/tmp/example.pdf")
        let data = url.dataRepresentation

        XCTAssertEqual(DocumentWorkspace.fileURL(from: data as NSData), url)
    }

    @MainActor
    func testAddsManualCheckboxFieldAndSelectsIt() throws {
        let workspace = DocumentWorkspace()
        workspace.document = try makeBlankPDF()

        workspace.addManualField(tool: .checkbox, pageIndex: 0, center: CGPoint(x: 120, y: 140))

        XCTAssertEqual(workspace.fields.count, 1)
        XCTAssertEqual(workspace.fields[0].kind, .checkbox)
        XCTAssertEqual(workspace.fields[0].source, .user)
        XCTAssertTrue(workspace.fields[0].boolValue)
        XCTAssertEqual(workspace.selectedFieldID, workspace.fields[0].id)
        XCTAssertEqual(workspace.activeTool, .select)
    }

    private func makeBlankPDF() throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw TestError.failedToCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestError.failedToCreatePDF
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw TestError.failedToCreatePDF
        }
        return document
    }
}

private enum TestError: Error {
    case failedToCreatePDF
}
