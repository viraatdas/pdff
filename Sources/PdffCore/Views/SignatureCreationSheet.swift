import AppKit
import SwiftUI

public struct SignatureCreationSheet: View {
    public var onSave: (String, Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: SignatureMode = .draw
    @State private var name = "Signature"
    @State private var typedName = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var errorMessage: String?

    public init(onSave: @escaping (String, Data) -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Signature")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Mode", selection: $mode) {
                ForEach(SignatureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .draw:
                    SignatureDrawingPad(strokes: $strokes)
                        .frame(height: 180)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator)
                        }
                    HStack {
                        Spacer()
                        Button {
                            strokes = []
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }

                case .type:
                    TextField("Typed signature", text: $typedName)
                        .font(.system(size: 28, weight: .regular, design: .serif))
                        .textFieldStyle(.roundedBorder)
                    TypedSignaturePreview(text: typedName)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator)
                        }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        do {
            let data: Data
            switch mode {
            case .draw:
                guard strokes.contains(where: { $0.count > 1 }) else {
                    errorMessage = "Draw a signature before saving."
                    return
                }
                data = try SignatureRenderer.renderDrawn(strokes: strokes)
            case .type:
                let text = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    errorMessage = "Type a signature before saving."
                    return
                }
                data = try SignatureRenderer.renderTyped(text)
            }
            onSave(name, data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum SignatureMode: String, CaseIterable, Identifiable {
    case draw
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draw: "Draw"
        case .type: "Type"
        }
    }
}

private struct TypedSignaturePreview: View {
    var text: String

    var body: some View {
        Text(text.isEmpty ? "Signature" : text)
            .font(.system(size: 44, weight: .regular, design: .serif))
            .italic()
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
    }
}

private struct SignatureDrawingPad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]

    func makeNSView(context: Context) -> DrawingPadView {
        let view = DrawingPadView()
        view.onChange = { strokes = $0 }
        return view
    }

    func updateNSView(_ nsView: DrawingPadView, context: Context) {
        nsView.strokes = strokes
        nsView.needsDisplay = true
    }
}

private final class DrawingPadView: NSView {
    var strokes: [[CGPoint]] = []
    var onChange: (([[CGPoint]]) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.setFill()
        dirtyRect.fill()

        NSColor.black.setStroke()
        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for point in stroke.dropFirst() {
                path.line(to: point)
            }
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        onChange?(strokes)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        onChange?(strokes)
        needsDisplay = true
    }
}

private enum SignatureRenderer {
    static func renderDrawn(strokes: [[CGPoint]], size: CGSize = CGSize(width: 720, height: 240)) throws -> Data {
        let sourceBounds = strokes
            .flatMap { $0 }
            .reduce(CGRect.null) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            .insetBy(dx: -12, dy: -12)

        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()

        NSColor.black.setStroke()
        let scale = min(size.width / max(sourceBounds.width, 1), size.height / max(sourceBounds.height, 1)) * 0.86
        let xOffset = (size.width - sourceBounds.width * scale) / 2 - sourceBounds.minX * scale
        let yOffset = (size.height - sourceBounds.height * scale) / 2 - sourceBounds.minY * scale

        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = max(2.6, 3.2 * scale)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: transform(stroke[0], scale: scale, xOffset: xOffset, yOffset: yOffset))
            for point in stroke.dropFirst() {
                path.line(to: transform(point, scale: scale, xOffset: xOffset, yOffset: yOffset))
            }
            path.stroke()
        }
        image.unlockFocus()
        return try pngData(from: image)
    }

    static func renderTyped(_ text: String, size: CGSize = CGSize(width: 720, height: 240)) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()

        let fallback = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 82), toHaveTrait: .italicFontMask)
        let font = NSFont(name: "Snell Roundhand", size: 92) ?? fallback
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.size()
        let rect = CGRect(
            x: 24,
            y: max(0, (size.height - measured.height) / 2 - 4),
            width: size.width - 48,
            height: measured.height + 12
        )
        attributed.draw(in: rect)
        image.unlockFocus()
        return try pngData(from: image)
    }

    private static func transform(_ point: CGPoint, scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale + xOffset, y: point.y * scale + yOffset)
    }

    private static func pngData(from image: NSImage) throws -> Data {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw SignatureRenderError.failed
        }
        return data
    }
}

private enum SignatureRenderError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The signature image could not be created."
    }
}
