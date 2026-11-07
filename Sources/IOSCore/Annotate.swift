import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Numbered boxes drawn over a screenshot, one per element `ios layout` lists, with the same [N].
/// The boxes' tap points are saved in the PNG itself (its Description text), so `ios screen resolve`
/// can turn "#N" into coordinates later without asking the device again.
public enum Annotate {
    public struct Mark: Codable, Equatable, Sendable {
        public let index: Int
        public let x: Double
        public let y: Double
    }

    /// Marker that starts the PNG Description, so another tool's description isn't mistaken for ours.
    static let tag = "ios-cli-annotations:"

    /// Draws `elements` over the PNG at `path` (points → pixels by the image/screen ratio) and saves it in place.
    public static func draw(_ elements: [LayoutElement], screen: Rect, png path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw IOSError.invalidOutput(tool: "screenshot", reason: "\(path) isn't a readable PNG")
        }
        let width = image.width, height = image.height
        let sx = Double(width) / max(screen.width, 1), sy = Double(height) / max(screen.height, 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IOSError.invalidOutput(tool: "screenshot", reason: "couldn't create a drawing context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(sx, sy)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 11 * scale, nil)
        for group in boxes(elements, screen: screen) {
            let element = group[0], visible = group.visible
            let color = palette[(element.index - 1) % palette.count]
            // CoreGraphics counts y from the bottom.
            let box = CGRect(x: (visible.x - screen.x) * sx, y: Double(height) - (visible.y - screen.y + visible.height) * sy,
                             width: visible.width * sx, height: visible.height * sy)
            context.setStrokeColor(color)
            context.setLineWidth(max(2, scale))
            if element.covered { context.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale]) }
            context.stroke(box.insetBy(dx: 1, dy: 1))
            context.setLineDash(phase: 0, lengths: [])

            let text = NSAttributedString(string: group.elements.map { "\($0.index)" }.joined(separator: ","), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = .zero // the image bounds below are measured from the current text position
            let bounds = CTLineGetImageBounds(line, context)
            let pad = 2 * scale
            let tagRect = CGRect(x: box.minX, y: box.maxY - bounds.height - 2 * pad,
                                 width: bounds.width + 2 * pad, height: bounds.height + 2 * pad)
            context.setFillColor(color)
            context.fill(tagRect)
            context.textPosition = CGPoint(x: tagRect.minX + pad - bounds.minX, y: tagRect.minY + pad - bounds.minY)
            CTLineDraw(line, context)
        }
        guard let annotated = context.makeImage() else {
            throw IOSError.invalidOutput(tool: "screenshot", reason: "couldn't render the annotations")
        }
        let marks = elements.map { Mark(index: $0.index, x: $0.center.x, y: $0.center.y) }
        let description = tag + String(decoding: try JSONEncoder().encode(marks), as: UTF8.self)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw IOSError.invalidOutput(tool: "screenshot", reason: "couldn't write \(path)")
        }
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]] as CFDictionary
        CGImageDestinationAddImage(destination, annotated, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw IOSError.invalidOutput(tool: "screenshot", reason: "couldn't write \(path)")
        }
    }

    struct Box {
        var elements: [LayoutElement]
        let visible: Rect
        subscript(_ i: Int) -> LayoutElement { elements[i] }
    }

    /// One box per distinct on-screen frame: a row's Cell and its Button share a box labelled "31,32".
    /// Elements spanning (nearly) the whole screen, like a toolbar container, get no box; they're
    /// still in the printed list.
    static func boxes(_ elements: [LayoutElement], screen: Rect) -> [Box] {
        var out: [Box] = []
        for element in elements {
            guard let visible = element.frame.intersection(screen), !Layout.covers(visible, screen) else { continue }
            if let i = out.firstIndex(where: { same($0.visible, visible) }) {
                out[i].elements.append(element)
            } else {
                out.append(Box(elements: [element], visible: visible))
            }
        }
        return out
    }

    private static func same(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The tap points saved in an annotated screenshot.
    public static func marks(in path: String) throws -> [Mark] {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw IOSError.failed("Can't read \(path) as an image.")
        }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        guard let description = png?[kCGImagePropertyPNGDescription] as? String, description.hasPrefix(tag) else {
            throw IOSError.failed("\(path) has no element marks; take it with `ios screen capture --annotate`.")
        }
        return try JSONDecoder().decode([Mark].self, from: Data(description.dropFirst(tag.count).utf8))
    }

    /// Replaces every "#N" in `text` with mark N's tap point as "x y" (whole points).
    public static func resolve(_ text: String, marks: [Mark]) throws -> String {
        let byIndex = Dictionary(marks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var out = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: /#(\d+)/) {
            out += rest[..<match.range.lowerBound]
            guard let index = Int(match.1), let mark = byIndex[index] else {
                throw IOSError.failed("The screenshot has no #\(match.1); its marks are 1–\(marks.count).")
            }
            out += "\(Int(mark.x.rounded())) \(Int(mark.y.rounded()))"
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    /// Distinct, saturated colours that stay readable over light and dark screens.
    static let palette: [CGColor] = [
        (0.90, 0.10, 0.29), (0.00, 0.51, 0.78), (0.24, 0.65, 0.25), (0.96, 0.51, 0.19),
        (0.57, 0.12, 0.71), (0.00, 0.60, 0.60), (0.80, 0.33, 0.00), (0.35, 0.35, 0.85),
    ].map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
}
