import AppKit
import CoreGraphics

enum PDFFieldTextSizer {
    static func exportFontSize(for text: String, in bounds: CGRect) -> CGFloat {
        fittedFontSize(
            for: text,
            in: bounds.insetBy(dx: 2, dy: 2),
            startingAt: min(max(bounds.height * 0.62, 7), 28),
            minimum: 5.5
        )
    }

    static func previewFontSize(for text: String, in bounds: CGRect) -> CGFloat {
        fittedFontSize(
            for: text,
            in: bounds.insetBy(dx: 4, dy: 2),
            startingAt: min(max(bounds.height * 0.62, 7), 72),
            minimum: 5.5
        )
    }

    private static func fittedFontSize(
        for text: String,
        in bounds: CGRect,
        startingAt initialSize: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return minimum }

        var size = initialSize
        while size > minimum {
            let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)])
            if measured.width <= bounds.width && measured.height <= bounds.height + 2 {
                return size
            }
            size -= 0.5
        }
        return minimum
    }
}
