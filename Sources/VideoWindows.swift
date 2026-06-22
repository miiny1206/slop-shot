import AppKit
import AVKit               // AVPlayerView: trình phát video AppKit
import AVFoundation        // AVAssetExportSession: cắt/đổi định dạng; AVAssetImageGenerator: lấy frame
import ImageIO             // CGImageDestination: ghi GIF động
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────
// Hai cửa sổ cho clip vừa quay (mô phỏng CleanShot):
//   1) VideoPlayerWindowController  — "Quick Look": 1 màn xem clip ngay trong app.
//   2) VideoTrimWindowController     — "Trim": tự dựng thanh trim (2 tay nắm vàng),
//      kèm 2 nút xuất: "Trim Only" (giữ .mov) và "Trim & Convert" (đổi MP4/GIF).
//
// Vì sao tự dựng thanh trim thay vì AVPlayerView.beginTrimming? — beginTrimming
// kèm sẵn 2 nút "Trim"/"Cancel" của hệ thống → trùng với 2 nút xuất của ta. Tự vẽ
// slider thì chỉ còn 2 nút xuất, gọn và rõ ràng.
//
// React-analogy: mỗi controller ~ 1 "modal component" tự quản cửa sổ + state.
// App chạy nền (.accessory); mở cửa sổ → tạm .regular để có focus, đóng → .accessory.
// ─────────────────────────────────────────────────────────────────────────

// MARK: - Quick Look (chỉ xem)

@MainActor
final class VideoPlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var player: AVPlayer?

    func open(url: URL) {
        window?.close()

        let pv = AVPlayerView()
        pv.controlsStyle = .floating
        pv.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        pv.player = player

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Quick Look — \(url.lastPathComponent)"
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = pv
        win.minSize = NSSize(width: 420, height: 280)
        win.delegate = self
        win.isReleasedWhenClosed = false
        self.window = win
        self.player = player

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
        player.play()
    }

    // Đóng màn Quick Look (gọi khi bắt đầu chụp/quay mới).
    @discardableResult
    func dismiss() -> Bool {
        guard window != nil else { return false }
        window?.close()      // windowWillClose lo dọn + trả .accessory
        return true
    }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        player = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Thanh trim tự vẽ (filmstrip + 2 tay nắm + playhead)

@MainActor
final class TrimSliderView: NSView {
    var startFrac: CGFloat = 0           // điểm bắt đầu chọn (0…1)
    var endFrac: CGFloat = 1             // điểm kết thúc chọn (0…1)
    var playheadFrac: CGFloat = 0        // vị trí đang phát
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }

    var onRangeChange: (() -> Void)?     // kéo tay nắm xong (đổi start/end)
    var onScrub: ((CGFloat) -> Void)?    // bấm/kéo vào giữa = tua tới frac

    private let handleW: CGFloat = 11
    private let minGap: CGFloat = 0.02   // khoảng chọn tối thiểu (~2%)
    private enum Drag { case none, start, end, scrub }
    private var drag: Drag = .none

    override var isFlipped: Bool { false }

    // Vùng filmstrip (chừa 2 mép cho tay nắm).
    private var track: NSRect { bounds.insetBy(dx: handleW, dy: 6) }
    private func x(for f: CGFloat) -> CGFloat { track.minX + f * track.width }
    private func frac(forX px: CGFloat) -> CGFloat {
        min(max((px - track.minX) / track.width, 0), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let radius: CGFloat = 7

        // 1) Nền filmstrip: trải đều các thumbnail theo chiều ngang.
        let clip = NSBezierPath(roundedRect: t, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor(white: 0.08, alpha: 1).setFill()
        t.fill()
        if !thumbnails.isEmpty {
            let cw = t.width / CGFloat(thumbnails.count)
            for (i, img) in thumbnails.enumerated() {
                let cell = NSRect(x: t.minX + CGFloat(i) * cw, y: t.minY, width: cw + 1, height: t.height)
                let iw = max(img.size.width, 1), ih = max(img.size.height, 1)
                let fill = max(cell.width / iw, cell.height / ih)
                let dw = iw * fill, dh = ih * fill
                let r = NSRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh)
                img.draw(in: r, from: .zero, operation: .copy, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // 2) Làm tối 2 vùng NGOÀI khoảng chọn.
        let sx = x(for: startFrac), ex = x(for: endFrac)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: t.minX, y: t.minY, width: sx - t.minX, height: t.height).fill()
        NSRect(x: ex, y: t.minY, width: t.maxX - ex, height: t.height).fill()

        // 3) Viền vàng quanh khoảng chọn + 2 tay nắm.
        let yellow = NSColor.systemYellow
        yellow.setStroke()
        let sel = NSBezierPath(rect: NSRect(x: sx, y: t.minY, width: ex - sx, height: t.height))
        sel.lineWidth = 3
        sel.stroke()
        yellow.setFill()
        for hx in [sx, ex] {
            let h = NSRect(x: hx - handleW / 2, y: bounds.minY + 2, width: handleW, height: bounds.height - 4)
            NSBezierPath(roundedRect: h, xRadius: 4, yRadius: 4).fill()
            // 2 vạch nhỏ giữa tay nắm cho dễ nhận.
            NSColor.black.withAlphaComponent(0.4).setStroke()
            for off in [-2.0, 2.0] {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: hx + off, y: h.midY - 5))
                p.line(to: NSPoint(x: hx + off, y: h.midY + 5))
                p.lineWidth = 1
                p.stroke()
            }
            yellow.setFill()
        }

        // 4) Playhead trắng (chỉ trong khoảng chọn).
        let pf = min(max(playheadFrac, startFrac), endFrac)
        let phx = x(for: pf)
        NSColor.white.setFill()
        NSRect(x: phx - 1, y: t.minY - 2, width: 2, height: t.height + 4).fill()
    }

    // ── Kéo chuột: tay nắm gần điểm bấm → kéo start/end; giữa → tua ───────
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let sx = x(for: startFrac), ex = x(for: endFrac)
        if abs(p.x - sx) <= handleW { drag = .start }
        else if abs(p.x - ex) <= handleW { drag = .end }
        else { drag = .scrub; playheadFrac = frac(forX: p.x); onScrub?(playheadFrac); needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let f = frac(forX: p.x)
        switch drag {
        case .start:
            startFrac = min(f, endFrac - minGap)
            playheadFrac = startFrac
            onRangeChange?(); onScrub?(startFrac)
        case .end:
            endFrac = max(f, startFrac + minGap)
            playheadFrac = endFrac
            onRangeChange?(); onScrub?(endFrac)
        case .scrub:
            playheadFrac = f; onScrub?(f)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { drag = .none }
}

// MARK: - Trim (cắt + xuất)

@MainActor
final class VideoTrimWindowController: NSObject, NSWindowDelegate {
    private enum ConvertFormat: Int { case mp4 = 0, gif = 1 }

    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var sourceURL: URL?
    private var saveFolder: URL = FileManager.default.temporaryDirectory
    private var durationS: Double = 0
    private var timeObserver: Any?

    private weak var slider: TrimSliderView?
    private weak var formatPopup: NSPopUpButton?
    private weak var trimOnlyButton: NSButton?
    private weak var convertButton: NSButton?
    private var busyOverlay: NSView?

    var onDone: ((URL?) -> Void)?

    func open(url: URL, saveFolder: URL) {
        window?.close()
        self.sourceURL = url
        self.saveFolder = saveFolder

        let W: CGFloat = 760, H: CGFloat = 560, barH: CGFloat = 56, stripH: CGFloat = 76
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Trim — \(url.lastPathComponent)"
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 560, height: 400)
        win.delegate = self
        win.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // Player (trên cùng) — controls .floating: chỉ play/scrub, KHÔNG có nút trim.
        let pv = AVPlayerView(frame: NSRect(x: 0, y: barH + stripH, width: W, height: H - barH - stripH))
        pv.controlsStyle = .floating
        pv.videoGravity = .resizeAspect
        pv.autoresizingMask = [.width, .height]
        let player = AVPlayer(url: url)
        pv.player = player
        container.addSubview(pv)

        // Thanh trim tự vẽ (ngay trên bottom bar).
        let strip = TrimSliderView(frame: NSRect(x: 14, y: barH + 8, width: W - 28, height: stripH - 16))
        strip.autoresizingMask = [.width]
        strip.onScrub = { [weak self] f in self?.seek(toFrac: f) }
        container.addSubview(strip)
        self.slider = strip

        // Bottom bar: [Convert to ▾]  …  [Trim Only] [Trim & Convert]
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: W, height: barH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        bar.autoresizingMask = [.width]
        container.addSubview(bar)

        let label = NSTextField(labelWithString: "Convert to:")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 16, y: (barH - 18) / 2, width: 76, height: 18)
        bar.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 94, y: (barH - 26) / 2, width: 84, height: 26))
        popup.addItems(withTitles: ["MP4", "GIF"])
        bar.addSubview(popup)
        self.formatPopup = popup

        let bw: CGFloat = 134, bh: CGFloat = 30, gap: CGFloat = 10
        let convert = NSButton(title: "Trim & Convert", target: self, action: #selector(tapConvert))
        convert.bezelStyle = .rounded
        convert.frame = NSRect(x: W - 16 - bw, y: (barH - bh) / 2, width: bw, height: bh)
        convert.autoresizingMask = [.minXMargin]
        bar.addSubview(convert)
        self.convertButton = convert

        let trimOnly = NSButton(title: "Trim Only", target: self, action: #selector(tapTrimOnly))
        trimOnly.bezelStyle = .rounded
        trimOnly.keyEquivalent = "\r"
        trimOnly.frame = NSRect(x: W - 16 - bw - gap - 104, y: (barH - bh) / 2, width: 104, height: bh)
        trimOnly.autoresizingMask = [.minXMargin]
        bar.addSubview(trimOnly)
        self.trimOnlyButton = trimOnly

        win.contentView = container
        self.window = win
        self.playerView = pv
        self.player = player

        // Playhead chạy theo video; tự dừng khi chạm cuối khoảng chọn.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)

        loadDurationAndThumbnails(url: url)
    }

    // ── Nạp thời lượng + filmstrip (async API mới, không block main) ──────
    private func loadDurationAndThumbnails(url: URL) {
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            // load(.duration): API async thay cho asset.duration (deprecated từ macOS 13).
            let dur = (try? await asset.load(.duration)) ?? .zero
            let durS = CMTimeGetSeconds(dur)
            self.durationS = durS.isFinite ? durS : 0
            guard durS.isFinite, durS > 0 else { return }

            let n = 12
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            var thumbs: [NSImage] = []
            for i in 0..<n {
                let s = durS * (Double(i) + 0.5) / Double(n)
                let t = CMTime(seconds: s, preferredTimescale: 600)
                // image(at:) async giải mã off-main rồi trả về trên main — không đơ UI.
                if let r = try? await gen.image(at: t) {
                    thumbs.append(NSImage(cgImage: r.image,
                                          size: NSSize(width: r.image.width, height: r.image.height)))
                }
            }
            self.slider?.thumbnails = thumbs
        }
    }

    private func seek(toFrac f: CGFloat) {
        guard durationS > 0 else { return }
        player?.seek(to: CMTime(seconds: Double(f) * durationS, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: CMTime) {
        guard let slider, durationS > 0 else { return }
        let f = CGFloat(CMTimeGetSeconds(time) / durationS)
        slider.playheadFrac = f
        slider.needsDisplay = true
        // Đang phát mà vượt quá điểm cuối khoảng chọn → dừng, quay về đầu chọn.
        if (player?.rate ?? 0) > 0, f >= slider.endFrac {
            player?.pause()
            seek(toFrac: slider.startFrac)
        }
    }

    // Khoảng đang chọn (từ slider) → CMTimeRange.
    private func selectedRange() -> CMTimeRange {
        let s = Double(slider?.startFrac ?? 0) * durationS
        let e = Double(slider?.endFrac ?? 1) * durationS
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                           end:   CMTime(seconds: max(e, s + 0.05), preferredTimescale: 600))
    }

    // ── 2 nút xuất ────────────────────────────────────────────────────────
    @objc private func tapTrimOnly() {
        guard let src = sourceURL else { return }
        setBusy(true)
        exportSession(asset: AVURLAsset(url: src), range: selectedRange(),
                      preset: AVAssetExportPresetPassthrough, fileType: .mov, ext: "mov")
    }

    @objc private func tapConvert() {
        guard let src = sourceURL else { return }
        let fmt = ConvertFormat(rawValue: formatPopup?.indexOfSelectedItem ?? 0) ?? .mp4
        setBusy(true)
        let asset = AVURLAsset(url: src)
        switch fmt {
        case .mp4:
            exportSession(asset: asset, range: selectedRange(),
                          preset: AVAssetExportPresetHighestQuality, fileType: .mp4, ext: "mp4")
        case .gif:
            exportGIF(asset: asset, range: selectedRange(), fps: 12, maxSide: 640)
        }
    }

    private func exportSession(asset: AVAsset, range: CMTimeRange,
                               preset: String, fileType: AVFileType, ext: String) {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            finish(nil); return
        }
        let dest = uniqueDest(ext: ext)
        session.timeRange = range   // outputURL/outputFileType giờ truyền qua export(to:as:)
        Task { @MainActor in
            // export(to:as:) async (macOS 15+): throw nếu lỗi, không cần đọc .status.
            do {
                try await session.export(to: dest, as: fileType)
                self.finish(dest)
            } catch {
                self.finish(nil)
            }
        }
    }

    private func exportGIF(asset: AVAsset, range: CMTimeRange, fps: Double, maxSide: CGFloat) {
        let dest = uniqueDest(ext: "gif")
        let startS = CMTimeGetSeconds(range.start)
        let durS = CMTimeGetSeconds(range.duration)
        let frameCount = max(Int((durS * fps).rounded()), 1)
        let delay = 1.0 / fps

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)

        // Tất cả trên main actor: image(at:) async tự giải mã off-main, các điểm
        // `await` chừa nhịp cho UI; ImageIO add/finalize nhẹ nên xen vào được.
        Task { @MainActor in
            guard let out = CGImageDestinationCreateWithURL(
                dest as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
                self.finish(nil); return
            }
            let gifProps = [kCGImagePropertyGIFDictionary as String:
                                [kCGImagePropertyGIFLoopCount as String: 0]]
            CGImageDestinationSetProperties(out, gifProps as CFDictionary)
            let frameProps = [kCGImagePropertyGIFDictionary as String:
                                [kCGImagePropertyGIFDelayTime as String: delay]]
            var added = 0
            for i in 0..<frameCount {
                let t = CMTime(seconds: startS + Double(i) * delay, preferredTimescale: 600)
                if let r = try? await gen.image(at: t) {
                    CGImageDestinationAddImage(out, r.image, frameProps as CFDictionary)
                    added += 1
                }
            }
            let ok = CGImageDestinationFinalize(out)
            self.finish(ok && added > 0 ? dest : nil)
        }
    }

    private func finish(_ outURL: URL?) {
        setBusy(false)
        guard let outURL else { onDone?(nil); return }
        NSWorkspace.shared.activateFileViewerSelecting([outURL])
        onDone?(outURL)
        window?.close()
    }

    private func uniqueDest(ext: String) -> URL {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "SlopShot"
        var candidate = saveFolder.appendingPathComponent("\(base) (trimmed).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = saveFolder.appendingPathComponent("\(base) (trimmed \(i)).\(ext)")
            i += 1
        }
        return candidate
    }

    private func setBusy(_ on: Bool) {
        trimOnlyButton?.isEnabled = !on
        convertButton?.isEnabled = !on
        formatPopup?.isEnabled = !on
        if on {
            guard busyOverlay == nil, let content = window?.contentView else { return }
            let ov = NSView(frame: content.bounds)
            ov.autoresizingMask = [.width, .height]
            ov.wantsLayer = true
            ov.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .regular
            spin.sizeToFit()
            spin.frame.origin = CGPoint(x: ov.bounds.midX - spin.frame.width / 2,
                                        y: ov.bounds.midY - spin.frame.height / 2 + 8)
            spin.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            spin.startAnimation(nil)
            ov.addSubview(spin)
            let lbl = NSTextField(labelWithString: "Exporting…")
            lbl.textColor = .white
            lbl.font = .systemFont(ofSize: 13)
            lbl.sizeToFit()
            lbl.frame.origin = CGPoint(x: ov.bounds.midX - lbl.frame.width / 2, y: ov.bounds.midY - 22)
            lbl.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            ov.addSubview(lbl)
            content.addSubview(ov)
            busyOverlay = ov
        } else {
            busyOverlay?.removeFromSuperview()
            busyOverlay = nil
        }
    }

    // Đóng tool Trim mà KHÔNG xuất (gọi khi bắt đầu chụp/quay mới).
    @discardableResult
    func dismiss() -> Bool {
        guard window != nil else { return false }
        window?.close()      // windowWillClose lo dọn + trả .accessory
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        playerView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
