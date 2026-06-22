// make_icon.swift — vẽ app icon SlopShot (chữ S kiểu Anthropic) ra đủ size PNG
// rồi sinh luôn Assets.xcassets/AppIcon.appiconset/Contents.json.
//
// Chạy:  swift tools/make_icon.swift     (từ thư mục gốc repo)
//
// Vì sao vẽ bằng code thay vì file ảnh: icon là vector thuần (squircle + 1 glyph),
// vẽ lại ở mọi size cho nét căng, sửa màu/độ đậm chỉ cần đổi hằng số ở đây.

import AppKit
import CoreText
import CoreGraphics

// ── Bảng màu (tông clay ấm của Anthropic) ────────────────────────────────
func hex(_ s: String, _ a: CGFloat = 1) -> CGColor {
    var h = s; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green:   CGFloat((v >> 8) & 0xff) / 255,
                   blue:    CGFloat(v & 0xff) / 255, alpha: a)
}
let clayTop = hex("E89A72")   // clay sáng (đỉnh)
let clayBot = hex("C8623C")   // clay đậm (đáy)
let cream   = hex("F4EFE4")   // kem (chữ S)

// ── Đường viền glyph "S" (font tròn, đậm) tại cỡ `fontSize` ──────────────
func sGlyphPath(fontSize: CGFloat) -> CGPath? {
    let base = NSFont.systemFont(ofSize: fontSize, weight: .black)
    let nsFont = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                        size: fontSize) ?? base
    let ctFont = CTFontCreateWithFontDescriptor(nsFont.fontDescriptor as CTFontDescriptor, fontSize, nil)
    var chars: [UniChar] = Array("S".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count)
    return CTFontCreatePathForGlyph(ctFont, glyphs[0], nil)
}

// ── 4 góc "khung ngắm" (crop corner) quanh hình chữ nhật `frame` ─────────
// Mỗi góc là 1 chữ L (2 đoạn) bo tròn — gợi ý app chụp/cắt màn hình.
func drawCropCorners(into ctx: CGContext, frame r: CGRect,
                     arm: CGFloat, lineWidth: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // CG toạ độ y hướng LÊN: maxY = trên, minY = dưới.
    func L(_ cx: CGFloat, _ cy: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        ctx.move(to: CGPoint(x: cx + dx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy))
        ctx.strokePath()
    }
    L(r.minX, r.maxY,  arm, -arm)   // trên-trái
    L(r.maxX, r.maxY, -arm, -arm)   // trên-phải
    L(r.minX, r.minY,  arm,  arm)   // dưới-trái
    L(r.maxX, r.minY, -arm,  arm)   // dưới-phải
    ctx.restoreGState()
}

// ── Vẽ icon vào 1 CGContext vuông cạnh `side` (px) ───────────────────────
func drawIcon(into ctx: CGContext, side: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setShouldAntialias(true)

    // 1) Squircle nền (rounded-rect tỉ lệ kiểu macOS) + gradient clay.
    let margin = side * 0.092
    let rect = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs,
                          colors: [clayTop, clayBot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end:   CGPoint(x: rect.midX, y: rect.minY), options: [])
    // Ánh sáng nhẹ phía trên cho icon "có khối".
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
                                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end:   CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Viền trong mảnh cho tách nền sáng.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06))
    ctx.setLineWidth(side * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    // 2) Khung ngắm + chữ "S" ở giữa (cùng màu kem, chung bóng đổ nhẹ).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                  blur: side * 0.02,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))

    // Khung ngắm: 4 góc crop bao quanh chữ S.
    let frame = rect.insetBy(dx: rect.width * 0.16, dy: rect.width * 0.16)
    drawCropCorners(into: ctx, frame: frame,
                    arm: frame.width * 0.24, lineWidth: rect.width * 0.05, color: cream)

    // Chữ "S" — căn giữa TUYỆT ĐỐI theo bounding box glyph (nhỏ để nằm gọn trong khung).
    if let glyphPath = sGlyphPath(fontSize: side * 0.42) {
        let b = glyphPath.boundingBoxOfPath
        ctx.saveGState()
        ctx.translateBy(x: (side - b.width) / 2 - b.minX, y: (side - b.height) / 2 - b.minY)
        ctx.addPath(glyphPath)
        ctx.setFillColor(cream)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// ── Khung ngắm + chữ "S" đen trên nền trong (template menu bar) ──────────
func drawSTemplate(into ctx: CGContext, side: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setShouldAntialias(true)
    let black = CGColor(gray: 0, alpha: 1)              // macOS tự tô lại khi là template

    // Khung ngắm 4 góc (đậm cho rõ ở size nhỏ ~16px).
    let frame = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.06)
    drawCropCorners(into: ctx, frame: frame,
                    arm: frame.width * 0.30, lineWidth: side * 0.085, color: black)

    // Chữ "S" nhỏ ở giữa khung.
    guard let p = sGlyphPath(fontSize: side) else { return }
    let b = p.boundingBoxOfPath
    let scale = (side * 0.5) / max(b.width, b.height)
    ctx.saveGState()
    ctx.translateBy(x: side / 2, y: side / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -b.midX, y: -b.midY)
    ctx.addPath(p)
    ctx.setFillColor(black)
    ctx.fillPath()
    ctx.restoreGState()
}

// ── Render 1 size ra file PNG (chọn vẽ icon đầy đủ hay glyph template) ────
func renderPNG(side: Int, to url: URL, template: Bool = false) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    if template { drawSTemplate(into: nsCtx.cgContext, side: CGFloat(side)) }
    else        { drawIcon(into: nsCtx.cgContext, side: CGFloat(side)) }
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
    }
}

// ── Sinh appiconset (PNG + Contents.json) ─────────────────────────────────
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let setDir = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
try? fm.createDirectory(at: setDir, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    renderPNG(side: s, to: setDir.appendingPathComponent("icon_\(s).png"))
    print("✓ icon_\(s).png")
}

// Map size@scale → file (macOS cần 16/32/128/256/512, mỗi cái 1x & 2x).
func entry(_ size: Int, _ scale: Int, _ file: Int) -> [String: String] {
    ["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": "icon_\(file).png"]
}
let images: [[String: String]] = [
    entry(16, 1, 16), entry(16, 2, 32),
    entry(32, 1, 32), entry(32, 2, 64),
    entry(128, 1, 128), entry(128, 2, 256),
    entry(256, 1, 256), entry(256, 2, 512),
    entry(512, 1, 512), entry(512, 2, 1024),
]
let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "xcode"],
]
let data = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try data.write(to: setDir.appendingPathComponent("Contents.json"))
print("✓ Contents.json → \(setDir.path)")

// ── Icon thanh menu: imageset template (16pt @1x/2x/3x) ──────────────────
let barDir = root.appendingPathComponent("Sources/Assets.xcassets/MenuBarIcon.imageset")
try? fm.createDirectory(at: barDir, withIntermediateDirectories: true)
for px in [16, 32, 48] {
    renderPNG(side: px, to: barDir.appendingPathComponent("bar_\(px).png"), template: true)
    print("✓ bar_\(px).png")
}
let barContents: [String: Any] = [
    "images": [
        ["idiom": "universal", "scale": "1x", "filename": "bar_16.png"],
        ["idiom": "universal", "scale": "2x", "filename": "bar_32.png"],
        ["idiom": "universal", "scale": "3x", "filename": "bar_48.png"],
    ],
    "info": ["version": 1, "author": "xcode"],
    "properties": ["template-rendering-intent": "template"],   // macOS tự tô đen/trắng theo nền
]
let barData = try JSONSerialization.data(withJSONObject: barContents,
                                         options: [.prettyPrinted, .sortedKeys])
try barData.write(to: barDir.appendingPathComponent("Contents.json"))
print("✓ Contents.json → \(barDir.path)")
