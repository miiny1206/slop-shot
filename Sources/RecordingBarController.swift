import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Thanh điều khiển khi ĐANG QUAY — bố cục giống CleanShot X:
//   [■ stop]  0:05  │  ⏸ pause   ↺ restart   🗑 discard   ≡ kéo
// Kéo chỗ trống / icon ≡ để di chuyển thanh (isMovableByWindowBackground).
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class RecordingBarController {
    private var panel: NSPanel?
    private var timer: Timer?
    private var seconds = 0
    private var paused = false
    private weak var timeLabel: NSTextField?
    private weak var pauseButton: NSButton?

    var onStop: (() -> Void)?
    var onPauseToggle: ((_ paused: Bool) -> Void)?
    var onRestart: (() -> Void)?
    var onDiscard: (() -> Void)?

    func show(below rect: CGRect, on screen: NSScreen) {
        hide()
        paused = false; seconds = 0

        let h: CGFloat = 38
        // Toạ độ X từng phần tử (ghép tay cho gọn như CleanShot).
        let stopX: CGFloat = 10
        let timeX = stopX + 22 + 8          // sau nút stop
        let dividerX = timeX + 46 + 8
        let pauseX = dividerX + 1 + 8
        let restartX = pauseX + 24 + 6
        let discardX = restartX + 24 + 6
        let handleX = discardX + 24 + 8
        let w = handleX + 16 + 10            // + icon kéo + lề phải

        // Đặt thanh ngay DƯỚI viền vùng quay (rect: gốc trên-trái của màn hình).
        // Đổi sang toạ độ AppKit (gốc dưới-trái) để định vị panel.
        let gap: CGFloat = 12
        let regionBottomY = screen.frame.minY + (screen.frame.height - rect.maxY)
        let regionTopY    = screen.frame.minY + (screen.frame.height - rect.minY)

        var y = regionBottomY - gap - h          // mặc định: ngay dưới vùng quay
        if y < screen.visibleFrame.minY + 6 {     // sát đáy → lật lên trên vùng quay
            y = regionTopY + gap
        }
        y = min(max(y, screen.visibleFrame.minY + 6), screen.visibleFrame.maxY - h - 6)

        let cx = screen.frame.minX + rect.midX - w / 2
        let x = min(max(cx, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - w - 6)
        let frame = NSRect(x: x, y: y, width: w, height: h)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true   // kéo nền để di chuyển thanh
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Nền pill tối.
        let bg = NSView(frame: NSRect(origin: .zero, size: frame.size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        bg.layer?.cornerRadius = 11

        // ■ Stop — ô vuông đỏ bo nhẹ.
        let stop = iconButton(symbol: "stop.fill", tip: "Stop & save",
                              action: #selector(tapStop), tint: .systemRed, size: 22)
        stop.frame = NSRect(x: stopX, y: (h - 22) / 2, width: 22, height: 22)
        bg.addSubview(stop)

        // Đồng hồ.
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: timeX, y: h / 2 - 9, width: 46, height: 18)
        bg.addSubview(label)
        timeLabel = label

        // Vạch ngăn.
        let divider = NSView(frame: NSRect(x: dividerX, y: 9, width: 1, height: h - 18))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        bg.addSubview(divider)

        // ⏸ Pause / ▶ Resume (toggle).
        let pause = iconButton(symbol: "pause.fill", tip: "Pause",
                               action: #selector(tapPause), tint: .white, size: 24)
        pause.frame = NSRect(x: pauseX, y: (h - 24) / 2, width: 24, height: 24)
        bg.addSubview(pause)
        pauseButton = pause

        // ↺ Restart (quay lại từ đầu).
        let restart = iconButton(symbol: "arrow.counterclockwise", tip: "Restart",
                                 action: #selector(tapRestart), tint: .white, size: 24)
        restart.frame = NSRect(x: restartX, y: (h - 24) / 2, width: 24, height: 24)
        bg.addSubview(restart)

        // 🗑 Discard (huỷ, không lưu).
        let discard = iconButton(symbol: "trash", tip: "Discard (don't save)",
                                 action: #selector(tapDiscard), tint: .white, size: 24)
        discard.frame = NSRect(x: discardX, y: (h - 24) / 2, width: 24, height: 24)
        bg.addSubview(discard)

        // ≡ Tay kéo (chỉ để nhìn — kéo nền là di chuyển được rồi).
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal",
                                              accessibilityDescription: "Drag")?
            .withSymbolConfiguration(cfg) ?? NSImage())
        grip.contentTintColor = NSColor(white: 1, alpha: 0.35)
        grip.frame = NSRect(x: handleX, y: h / 2 - 8, width: 16, height: 16)
        bg.addSubview(grip)

        p.contentView = bg
        p.orderFrontRegardless()
        self.panel = p
        startTimer()
    }

    func resetTimer() {
        seconds = 0
        timeLabel?.stringValue = "0:00"
        if paused { setPaused(false) }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
    }

    // ── nút bấm ─────────────────────────────────────────────────────────────
    @objc private func tapStop()    { onStop?() }
    @objc private func tapRestart() { resetTimer(); onRestart?() }
    @objc private func tapDiscard() { onDiscard?() }
    @objc private func tapPause() {
        setPaused(!paused)
        onPauseToggle?(paused)
    }

    // ── trợ giúp ──────────────────────────────────────────────────────────
    private func setPaused(_ value: Bool) {
        paused = value
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        pauseButton?.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                     accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(cfg)
        pauseButton?.toolTip = paused ? "Resume" : "Pause"
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.paused else { return }   // pause thì đồng hồ đứng
                self.seconds += 1
                self.timeLabel?.stringValue = String(format: "%d:%02d",
                                                     self.seconds / 60, self.seconds % 60)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func iconButton(symbol: String, tip: String, action: Selector,
                            tint: NSColor, size: CGFloat) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = tint
        b.toolTip = tip
        (b.cell as? NSButtonCell)?.highlightsBy = []
        return b
    }
}
