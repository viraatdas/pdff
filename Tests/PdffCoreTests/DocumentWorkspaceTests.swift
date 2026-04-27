import Foundation
import AppKit
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

    @MainActor
    func testChangingWidgetSignatureToTextDetachesAndResizesField() throws {
        let workspace = DocumentWorkspace()
        workspace.document = try makeBlankPDF()
        let field = DetectedField(
            pageIndex: 0,
            bounds: CGRect(x: 80, y: 120, width: 220, height: 56),
            kind: .signature,
            label: "Signature",
            source: .widget,
            confidence: 1,
            value: UUID().uuidString,
            widgetFieldName: "signature"
        )
        workspace.fields = [field]
        workspace.selectedFieldID = field.id

        workspace.updateCurrentFieldKind(.text)

        XCTAssertEqual(workspace.fields[0].kind, .text)
        XCTAssertEqual(workspace.fields[0].source, .user)
        XCTAssertNil(workspace.fields[0].widgetFieldName)
        XCTAssertEqual(workspace.fields[0].value, "")
        XCTAssertLessThan(workspace.fields[0].bounds.height, field.bounds.height)
    }

    @MainActor
    func testChangingSignaturePatternToTextUsesRescannedTextBounds() throws {
        let document = try makeTextPDF("Signature: ____________________", at: CGPoint(x: 72, y: 680))
        guard let detected = FieldDetector.detect(in: document).first(where: { $0.label == "Signature" }) else {
            XCTFail("Expected signature pattern field")
            return
        }
        XCTAssertEqual(detected.kind, .signature)

        let workspace = DocumentWorkspace()
        workspace.document = document
        workspace.fields = [detected]
        workspace.selectedFieldID = detected.id

        workspace.updateCurrentFieldKind(.text)

        XCTAssertEqual(workspace.fields[0].kind, .text)
        XCTAssertEqual(workspace.fields[0].source, .user)
        XCTAssertLessThan(workspace.fields[0].bounds.height, detected.bounds.height)
        XCTAssertGreaterThan(workspace.fields[0].bounds.width, 80)
    }

    @MainActor
    func testCheckboxBoundsStaySquareWhenEdited() throws {
        let workspace = DocumentWorkspace()
        workspace.document = try makeBlankPDF()
        let field = DetectedField(
            pageIndex: 0,
            bounds: CGRect(x: 80, y: 120, width: 16, height: 16),
            kind: .checkbox,
            label: "Checkbox",
            source: .pattern,
            confidence: 1
        )
        workspace.fields = [field]

        workspace.setFieldBounds(id: field.id, bounds: CGRect(x: 90, y: 130, width: 36, height: 12))

        XCTAssertEqual(workspace.fields[0].bounds.width, workspace.fields[0].bounds.height)
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

    private func makeTextPDF(_ text: String, at point: CGPoint) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw TestError.failedToCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TestError.failedToCreatePDF
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.black
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
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
