import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Tiện ích: lấy displayID (số định danh màn hình) từ 1 NSScreen.
// Cần nó để ghép NSScreen (AppKit) với SCDisplay (ScreenCaptureKit).
// ─────────────────────────────────────────────────────────────────────────
extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Cửa sổ overlay phải tự nhận được phím (để bắt ESC huỷ).
// Cửa sổ borderless mặc định KHÔNG thể thành "key window", nên phải override.
// ─────────────────────────────────────────────────────────────────────────
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// ─────────────────────────────────────────────────────────────────────────
// View vẽ lớp tối mờ + khung chọn, và bắt sự kiện kéo chuột.
// Tương tự 1 component React với onMouseDown/Move/Up + vẽ div khung chọn.
// ─────────────────────────────────────────────────────────────────────────
final class SelectionView: NSView {
    // Callback trả kết quả ra ngoài (giống props onSelected / onCancel).
    var onSelected: ((CGRect) -> Void)?   // rect theo points, gốc trên-trái màn hình
    var onCancel: (() -> Void)?

    var scaleFactor: CGFloat = 2           // để hiện kích thước theo pixel
    var hintText: String = "Drag to capture"   // gợi ý hiện giữa màn khi chưa kéo

    private var startPoint: NSPoint?
    private var currentRect: CGRect = .zero

    // Lật trục y: gốc toạ độ về góc TRÊN-trái, khớp với ảnh CGImage → đỡ phải convert.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Con trỏ hình chữ thập như mọi tool chụp màn hình.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // ── Vẽ ───────────────────────────────────────────────────────────────
    override func draw(_ dirtyRect: NSRect) {
        // 1. Phủ tối toàn bộ màn hình.
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()

        // Chưa kéo chọn gì → hiện gợi ý "Drag to capture" ở giữa.
        guard !currentRect.isEmpty else { drawHint(); return }

        // 2. "Khoét" vùng chọn cho trong suốt (thấy nội dung thật bên dưới).
        NSColor.clear.setFill()
        currentRect.fill(using: .copy)

        // 3. Viền khung chọn.
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        border.stroke()

        // 4. Nhãn kích thước "W × H" (px) ngay trên khung — chi tiết kiểu CleanShot.
        let w = Int(currentRect.width * scaleFactor)
        let h = Int(currentRect.height * scaleFactor)
        let label = "\(w) × \(h)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let pad: CGFloat = 6
        var labelOrigin = CGPoint(x: currentRect.minX, y: currentRect.minY - size.height - 8)
        if labelOrigin.y < 0 { labelOrigin.y = currentRect.maxY + 8 } // nếu sát mép trên thì hiện bên dưới
        let bg = CGRect(x: labelOrigin.x, y: labelOrigin.y,
                        width: size.width + pad * 2, height: size.height + pad)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad / 2), withAttributes: attrs)
    }

    // Pill gợi ý ở GIỮA màn hình, chỉ hiện khi user chưa bắt đầu kéo.
    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = hintText.size(withAttributes: attrs)
        let padX: CGFloat = 20, padY: CGFloat = 13
        let boxW = size.width + padX * 2, boxH = size.height + padY * 2
        let box = CGRect(x: bounds.midX - boxW / 2, y: bounds.midY - boxH / 2,
                         width: boxW, height: boxH)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
        hintText.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY), withAttributes: attrs)
    }

    // ── Sự kiện chuột ─────────────────────────────────────────────────────
    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Chuẩn hoá để kéo theo hướng nào cũng ra rect dương.
        currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Kéo quá nhỏ coi như lỡ tay → huỷ.
        if currentRect.width < 5 || currentRect.height < 5 {
            onCancel?()
        } else {
            onSelected?(currentRect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // 53 = phím ESC
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Controller: mở overlay trên 1 màn hình, chờ user chọn, gọi completion.
// completion trả về rect (points, gốc trên-trái của màn hình đó) hoặc nil nếu huỷ.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class RegionSelectionController {
    private var window: OverlayWindow?

    func begin(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.scaleFactor = screen.backingScaleFactor

        // completion chỉ được phép chạy ĐÚNG 1 lần. Nếu không, các sự kiện dồn
        // nhau (Esc lúc đang kéo chuột, Esc nhấn 2 lần, Esc sát lúc thả chuột)
        // có thể bắn callback 2 lần → withCheckedContinuation resume 2 lần →
        // fatalError "continuation misuse" → CẢ APP TẮT. Guard 1-lần ở đây.
        var finished = false
        let finishOnce: (CGRect?) -> Void = { [weak self] rect in
            guard !finished else { return }
            finished = true
            self?.cleanup()
            completion(rect)
        }

        let win = OverlayWindow(contentRect: screen.frame,
                                styleMask: .borderless,
                                backing: .buffered,
                                defer: false)
        win.level = .screenSaver          // nằm trên cả menu bar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = view

        view.onSelected = { rect in finishOnce(rect) }
        view.onCancel = { finishOnce(nil) }

        // Hiện ở alpha 0 trước, ÉP vẽ xong lớp dim, rồi mới fade lên nhanh.
        // Nếu order-front ngay ở alpha 1, cửa sổ kịp lộ 1 frame ĐEN trước khi
        // view vẽ → đó là cái "flash đen lên chậm" hay thấy.
        win.alphaValue = 0
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        win.displayIfNeeded()                     // vẽ lớp dim ngay, khỏi lộ nền đen
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            win.animator().alphaValue = 1
        }
        self.window = win
    }

    private func cleanup() {
        window?.orderOut(nil)
        window = nil
    }
}
