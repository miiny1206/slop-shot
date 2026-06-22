import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Lớp phủ FOCUS khi đang quay: tối xung quanh + khoét trong suốt đúng vùng
// đang quay + viền quanh vùng. Cho click xuyên qua (ignoresMouseEvents) để
// vẫn thao tác được app đang quay.
//
// dim + viền vẽ NGOÀI vùng quay → KHÔNG lọt vào video (SCStream chỉ crop
// đúng vùng qua sourceRect; vùng quay ở đây trong suốt nên quay ra nội dung thật).
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class RecordingOverlayController {
    private var window: NSWindow?

    func show(rect: CGRect, on screen: NSScreen) {
        hide()

        let view = RecordingOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.regionRect = rect

        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true   // click xuyên qua: vẫn dùng được app đang quay
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = view
        win.orderFrontRegardless()
        window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class RecordingOverlayView: NSView {
    var regionRect: CGRect = .zero
    // Gốc toạ độ trên-trái cho khớp rect từ overlay chọn vùng.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 1) Tối toàn màn hình.
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()

        guard !regionRect.isEmpty else { return }

        // 2) Khoét vùng đang quay cho trong suốt (thấy nội dung thật).
        NSColor.clear.setFill()
        regionRect.fill(using: .copy)

        // 3) Viền quanh vùng — vẽ NGOÀI mép 1.5px để không lọt vào khung quay.
        let border = NSBezierPath(rect: regionRect.insetBy(dx: -1.5, dy: -1.5))
        border.lineWidth = 2
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()   // đỏ = đang quay
        border.stroke()
    }
}
