import CoreGraphics
import PDFKit
import XCTest
@testable import PdffCore

final class PDFFillWriterTests: XCTestCase {
    func testExportsReadableFlattenedPDFWithOverlayField() throws {
        let document = try makeBlankPDF()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let field = DetectedField(
            pageIndex: 0,
            bounds: CGRect(x: 72, y: 680, width: 220, height: 24),
            kind: .text,
            label: "Full Name",
            source: .pattern,
            confidence: 0.8,
            value: "Ada Lovelace"
        )

        try PDFFillWriter.exportFlattened(
            document: document,
            fields: [field],
            signatures: [],
            signatureAssets: [:],
            to: outputURL
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? UInt64 ?? 0, 0)
        XCTAssertEqual(PDFDocument(url: outputURL)?.pageCount, 1)
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
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
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
