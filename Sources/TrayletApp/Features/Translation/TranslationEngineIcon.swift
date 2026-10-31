import SwiftUI
import TrayletCore

/// Engine marks drawn as one monochrome set so they match the app's glass controls: Google and DeepL use the vector
/// paths published by the CC0 simple-icons set (24×24 viewBox), system translation uses Apple's SF Symbol, and engines
/// without an official vector mark keep a neutral SF Symbol. All share one tint, size and optical weight.
struct TranslationEngineIcon: View {
    let engine: TranslationEngineChoice
    var size: CGFloat = 16
    var tint: Color = .primary
    var body: some View {
        Group {
            switch engine {
            case .system: Image(systemName: "apple.logo").font(.system(size: size * 0.92, weight: .medium))
            case .ai: Image(systemName: "sparkles").font(.system(size: size * 0.86, weight: .medium))
            case .deepl: V2SVGShape(path: V2SVGPaths.deepL).fill(tint).frame(width: size * 0.94, height: size * 0.94)
            case .google: V2SVGShape(path: V2SVGPaths.google).fill(tint).frame(width: size * 0.9, height: size * 0.9)
            case .myMemory: Image(systemName: "memorychip").font(.system(size: size * 0.86, weight: .medium))
            }
        }
        .foregroundStyle(tint).frame(width: size, height: size)
    }
}

enum V2SVGPaths {
    static let google = "M12.48 10.92v3.28h7.84c-.24 1.84-.853 3.187-1.787 4.133-1.147 1.147-2.933 2.4-6.053 2.4-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0 5.867 0 .307 5.387.307 12s5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36 2.16-2.16 2.84-5.213 2.84-7.667 0-.76-.053-1.467-.173-2.053H12.48z"
    static let deepL = "M20.907 4.93953 12.68543.18573a1.3577 1.3577 0 0 0-1.3709 0L3.09298 4.9565a1.3766 1.3766 0 0 0-.68639 1.18233v9.52646a1.3766 1.3766 0 0 0 .68639 1.19363l8.22157 4.75946.06223.03583 4.04856 2.3458-.01131-2.06106.0075-1.1446.0038.01885v-.38467c0-.23006.1188-.43371.29605-.56005l.264-.15086.12633-.06977h-.0075l4.80283-2.7795a1.3803 1.3803 0 0 0 .68639-1.19551V6.13505a1.3803 1.3803 0 0 0-.68642-1.19552m-9.85269 9.68863a1.4275 1.4275 0 0 1-.39976 1.3841 1.4086 1.4086 0 0 1-1.97054 0 1.4199 1.4199 0 0 1 0-2.06294 1.4086 1.4086 0 0 1 2.0422.07543l3.32822-1.91585.6864.38656zm5.77019-2.41367a1.4086 1.4086 0 0 1-1.97054 0 1.4256 1.4256 0 0 1-.3696-1.47837l-.0132.0075-3.7525-2.1723-.05657.05656a1.4086 1.4086 0 0 1-1.97053 0 1.4199 1.4199 0 0 1 0-2.06293 1.4086 1.4086 0 0 1 1.97242 0c.3941.37713.52422.91832.39033 1.40672l3.7808 2.20059.01886-.01886a1.4086 1.4086 0 0 1 1.97242 0 1.42746 1.42746 0 0 1 0 2.06105z"
}

/// Draws SVG path data scaled from its 24×24 viewBox into the shape's rectangle.
struct V2SVGShape: Shape {
    let path: String
    func path(in rect: CGRect) -> Path {
        let base = V2SVGPathParser.parse(path)
        let scale = min(rect.width, rect.height) / 24
        return base.applying(CGAffineTransform(scaleX: scale, y: scale)).applying(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale))
    }
}

/// Minimal SVG path parser: M L H V C S A Z in absolute and relative forms (the commands simple-icons uses).
enum V2SVGPathParser {
    static func parse(_ data: String) -> Path {
        var tokens = Tokenizer(Array(data))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: Character = "M"
        while let next = tokens.nextCommand(or: command) {
            command = next
            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            switch command.uppercased() {
            case "M":
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                current = point(x, y); start = current; path.move(to: current); lastControl = nil
                command = relative ? "l" : "L"
            case "L":
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                current = point(x, y); path.addLine(to: current); lastControl = nil
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case "C":
                guard let a = tokens.number(), let b = tokens.number(), let c = tokens.number(), let d = tokens.number(), let e = tokens.number(), let f = tokens.number() else { return path }
                let c1 = point(a, b), c2 = point(c, d), end = point(e, f)
                path.addCurve(to: end, control1: c1, control2: c2); current = end; lastControl = c2
            case "S":
                guard let c = tokens.number(), let d = tokens.number(), let e = tokens.number(), let f = tokens.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(c, d), end = point(e, f)
                path.addCurve(to: end, control1: c1, control2: c2); current = end; lastControl = c2
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(), let large = tokens.flag(), let sweep = tokens.flag(),
                      let x = tokens.number(), let y = tokens.number() else { return path }
                let end = point(x, y)
                addArc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default: return path
            }
        }
        return path
    }

    private struct Tokenizer {
        let chars: [Character]; var index = 0
        init(_ chars: [Character]) { self.chars = chars }
        mutating func skipSeparators() { while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" { index += 1 } }
        /// The next command letter, or the repeated previous command when numbers follow; nil at the end.
        mutating func nextCommand(or previous: Character) -> Character? {
            skipSeparators()
            guard index < chars.count else { return nil }
            if chars[index].isLetter { defer { index += 1 }; return chars[index] }
            return previous
        }
        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var sawDot = false, sawExponent = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber { text.append(c) }
                else if (c == "-" || c == "+") && (text.isEmpty || text.last == "e" || text.last == "E") { text.append(c) }
                else if c == "." && !sawDot && !sawExponent { sawDot = true; text.append(c) }
                else if (c == "e" || c == "E") && !sawExponent && !text.isEmpty { sawExponent = true; text.append(c) }
                else { break }
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }
        /// Arc flags are single characters and may touch the next number ("01.4").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1"
        }
    }

    /// SVG endpoint arc → cubic Béziers (SVG implementation notes F.6.5).
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1 / ry, cyp = -coefficient * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2, cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy, length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var value = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var angle1 = theta1
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy) }
        for _ in 0..<segments {
            let angle2 = angle1 + step
            let c1 = map(cos(angle1) - t * sin(angle1), sin(angle1) + t * cos(angle1))
            let c2 = map(cos(angle2) + t * sin(angle2), sin(angle2) - t * cos(angle2))
            path.addCurve(to: map(cos(angle2), sin(angle2)), control1: c1, control2: c2)
            angle1 = angle2
        }
    }
}
