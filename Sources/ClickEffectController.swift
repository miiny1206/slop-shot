import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Hiện vòng tròn "nảy ra" tại mỗi cú click chuột khi đang quay (giống CleanShot)
// → người xem video thấy rõ bạn bấm ở đâu.
//
// Bắt click bằng GLOBAL monitor (thấy click ở app khác — đúng cái mình quay).
// Mỗi click tạo 1 cửa sổ nhỏ trong suốt, vẽ vòng tròn animate rồi tự huỷ.
// Cửa sổ này NẰM TRONG vùng quay nên ĐƯỢC ghi vào video (khác dim/viền ở ngoài).
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class ClickEffectController {
    private var monitor: Any?
    private var region: CGRect = .zero   // vùng quay (toạ độ AppKit toàn cục)

    // Bắt đầu lắng nghe click, chỉ hiện hiệu ứng trong `region`.
    func start(in region: CGRect) {
        stop()
        self.region = region
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation               // gốc dưới-trái, toàn cục
                if NSPointInRect(p, self.region) { self.ripple(at: p) }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    // Vẽ 1 vòng tròn xanh phình to + mờ dần tại điểm click (giống CleanShot).
    private func ripple(at point: NSPoint) {
        let size: CGFloat = 56
        let win = NSWindow(contentRect: NSRect(x: point.x - size / 2, y: point.y - size / 2,
                                               width: size, height: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver           // trên mọi thứ → chắc chắn vào khung quay
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        view.wantsLayer = true

        let ring = CAShapeLayer()
        ring.frame = view.bounds
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 3, dy: 3), transform: nil)
        ring.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        ring.strokeColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 2.5
        view.layer?.addSublayer(ring)
        win.contentView = view
        win.orderFrontRegardless()

        // Phình từ 0.3→1.0 quanh tâm + mờ dần về 0 trong 0.45s.
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3; grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0; fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ripple")

        // Huỷ cửa sổ sau khi animate xong (giữ ref qua closure để không bị thu sớm).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            win.orderOut(nil)
        }
    }
}
