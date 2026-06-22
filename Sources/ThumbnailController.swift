import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Preview card nổi kiểu CleanShot X:
//  - bình thường: chỉ hiện ảnh thu nhỏ (đúng tỷ lệ, bo góc, đổ bóng)
//  - khi rê chuột: làm tối ảnh + hiện 2 nút Copy/Save ở giữa + 4 nút tròn 4 góc
//  - click ảnh = mở editor; kéo ra ngoài = lôi file sang app khác
// NSDraggingSource = "nguồn kéo".
// ─────────────────────────────────────────────────────────────────────────
final class ThumbnailView: NSView, NSDraggingSource {
    var image: NSImage?
    var fileURL: URL?
    // Chế độ video: thẻ clip vừa quay (như CleanShot). Bố cục đổi thành:
    //   - góc trên-phải: bỏ Pin → 👁 Quick Look (xem clip trong app)
    //   - góc dưới-trái: ✂️ Trim (mở tool cắt) — thay cho nút bút của ảnh
    //   - 2 capsule Copy/Save giữ nguyên (Copy = copy đường dẫn video)
    // + badge ▶ giữa thẻ; Share/Drag dùng file .mov.
    var isVideo = false {
        didSet {
            guard isVideo else { return }
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            // Góc trên-phải: Pin → 👁 Quick Look (mở màn xem của app).
            pinButton?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look")?
                .withSymbolConfiguration(cfg)
            pinButton?.toolTip = "Quick Look"
            pinButton?.action = #selector(tapQuickLook)
            // Góc dưới-trái: nút bút → ✂️ Trim (mở tool cắt clip vừa quay).
            editButton?.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim")?
                .withSymbolConfiguration(cfg)
            editButton?.toolTip = "Trim"
            editButton?.action = #selector(tapTrim)
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?         // ✏️ edit ảnh / 👁 Quick Look video (click ảnh hoặc nút góc)
    var onCopy: (() -> Void)?          // Copy lên clipboard
    var onTrim: (() -> Void)?          // ✂️ mở tool trim (chỉ video)
    var onSave: (() -> Void)?          // Save ra đích chọn
    var onClose: (() -> Void)?         // ✕ bỏ preview
    var onPin: (() -> Void)?           // 📌 ghim (không tự ẩn)
    var onHover: ((Bool) -> Void)?

    private var mouseDownPoint: NSPoint = .zero
    private var isDraggingOut = false
    private var hoverControls: [NSView] = []   // tất cả nút + lớp tối, ẩn khi không hover
    private let dimView = NSView()
    private weak var pinButton: NSButton?
    private weak var copyButton: NSButton?
    private weak var saveButton: NSButton?
    private weak var editButton: NSButton?
    private var pinned = false
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    // Lề chừa cho bóng đổ — dùng chung cho cả vẽ ảnh lẫn đặt nút.
    static let pad: CGFloat = 14
    private var pad: CGFloat { Self.pad }
    private let radius: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // ── Dựng lớp tối + 4 nút góc + 2 nút Copy/Save giữa (ẩn tới khi hover) ──
    private func setupControls() {
        let card = bounds.insetBy(dx: pad, dy: pad)   // vùng ảnh thật (trừ bóng đổ)

        // Lớp làm tối ảnh khi hover (để nút nổi rõ).
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        dimView.layer?.cornerRadius = radius
        dimView.frame = card
        dimView.isHidden = true
        addSubview(dimView)
        hoverControls.append(dimView)

        // 4 nút tròn ở góc. (SF Symbol, tooltip, hàm xử lý, góc)
        let corners: [(String, String, Selector, Corner)] = [
            ("xmark",                  "Discard", #selector(tapClose),      .topLeft),
            ("pin",                    "Pin",     #selector(tapPin),        .topRight),
            ("pencil.tip.crop.circle", "Edit",    #selector(tapEdit),       .bottomLeft),
            ("square.and.arrow.up",    "Share",   #selector(tapShare(_:)),  .bottomRight),
        ]
        let btn: CGFloat = 24, m: CGFloat = 6
        for (symbol, tip, action, corner) in corners {
            let b = makeCircleButton(symbol: symbol, tooltip: tip, action: action, size: btn)
            let x = (corner == .topLeft || corner == .bottomLeft)
                ? card.minX + m : card.maxX - m - btn
            let y = (corner == .topLeft || corner == .topRight)   // gốc toạ độ ở dưới-trái
                ? card.maxY - m - btn : card.minY + m
            b.frame = NSRect(x: x, y: y, width: btn, height: btn)
            b.isHidden = true
            addSubview(b)
            hoverControls.append(b)
            if symbol == "pin" { pinButton = b }
            if symbol == "pencil.tip.crop.circle" { editButton = b }
        }

        // 2 nút capsule ở giữa: Copy (trên) / Save (dưới).
        let cw: CGFloat = 68, ch: CGFloat = 23, gap: CGFloat = 6
        let cx = card.midX - cw / 2
        let copyB = makeCapsule(title: "Copy", action: #selector(tapCopy), size: NSSize(width: cw, height: ch))
        let saveB = makeCapsule(title: "Save", action: #selector(tapSave), size: NSSize(width: cw, height: ch))
        copyB.frame = NSRect(x: cx, y: card.midY + gap / 2, width: cw, height: ch)
        saveB.frame = NSRect(x: cx, y: card.midY - gap / 2 - ch, width: cw, height: ch)
        for b in [copyB, saveB] { b.isHidden = true; addSubview(b); hoverControls.append(b) }
        copyButton = copyB
        saveButton = saveB
    }

    // Rung nhẹ (chỉ trackpad Force Touch). React không có khái niệm này 😄
    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func capsuleTitle(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
    }

    // Copy/Save xong: nút đổi thành icon tick (đen) cho thấy rõ đã xong.
    // (Không cần revert vì ngay sau đó preview trượt đi rồi biến mất.)
    private func showTick(on b: NSButton?) {
        guard let b else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        b.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(cfg)
        b.imagePosition = .imageOnly
        b.contentTintColor = .black.withAlphaComponent(0.85)   // đen, không xanh
        b.attributedTitle = NSAttributedString(string: "")
    }

    private func makeCircleButton(symbol: String, tooltip: String,
                                  action: Selector, size: CGFloat) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .white
        b.toolTip = tooltip
        b.imageScaling = .scaleProportionallyDown
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        b.layer?.cornerRadius = size / 2
        (b.cell as? NSButtonCell)?.highlightsBy = []   // không đổi màu khi nhấn
        return b
    }

    private func makeCapsule(title: String, action: Selector, size: NSSize) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.attributedTitle = capsuleTitle(title, color: .black.withAlphaComponent(0.85))
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        b.layer?.cornerRadius = size.height / 2
        (b.cell as? NSButtonCell)?.highlightsBy = []   // không đổi màu khi nhấn
        return b
    }

    @objc private func tapEdit()  { haptic(); onClick?(); onClose?() }   // mở editor + trượt đi
    @objc private func tapCopy()  {
        haptic(); onCopy?(); showTick(on: copyButton)
        // cho thấy icon tick 1 nhịp rồi trượt biến mất
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.onClose?()
        }
    }
    @objc private func tapSave()  {
        haptic(); onSave?(); showTick(on: saveButton)
        // giống Copy: hiện tick 1 nhịp rồi trượt biến mất
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.onClose?()
        }
    }
    @objc private func tapQuickLook() { haptic(); onClick?() }          // 👁 mở màn xem (giữ preview)
    @objc private func tapTrim()  { haptic(); onTrim?(); onClose?() }   // ✂️ mở trim + trượt đi
    @objc private func tapClose() { haptic(); onClose?() }

    @objc private func tapPin() {
        haptic()
        pinned.toggle()
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                   accessibilityDescription: "Pin")?
            .withSymbolConfiguration(cfg)
        onPin?()
    }

    @objc private func tapShare(_ sender: NSButton) {
        haptic()
        // Video share file; ảnh share NSImage.
        let items: [Any] = isVideo ? [fileURL].compactMap { $0 } : [image].compactMap { $0 }
        guard !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    // ── Vẽ thẻ ảnh bo góc + viền + đổ bóng ───────────────────────────────
    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        let rect = bounds.insetBy(dx: pad, dy: pad)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // 1) Nền tối + bóng đổ mềm → card "nổi" khỏi màn hình.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor(white: 0.1, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 2) Ảnh: aspect-FILL trong ô vuông (phủ kín, cắt mép thừa → không méo).
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
        let fill = max(rect.width / iw, rect.height / ih)
        let dw = iw * fill, dh = ih * fill
        let imgRect = NSRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2,
                             width: dw, height: dh)
        image.draw(in: imgRect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 3) Viền sáng mảnh → tách nền.
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: radius, yRadius: radius)
        inner.lineWidth = 1
        inner.stroke()

        // 4) Video: vẽ nút ▶ tròn ở giữa cho biết đây là clip quay được.
        if isVideo {
            let r: CGFloat = 22
            let circle = NSRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let s: CGFloat = 15
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: rect.midX - s * 0.3, y: rect.midY - s * 0.55))
            tri.line(to: NSPoint(x: rect.midX - s * 0.3, y: rect.midY + s * 0.55))
            tri.line(to: NSPoint(x: rect.midX + s * 0.6,  y: rect.midY))
            tri.close()
            NSColor.white.withAlphaComponent(0.95).setFill()
            tri.fill()
        }
    }

    // ── Phân biệt "click" với "kéo ra ngoài" ─────────────────────────────
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDraggingOut = false
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - mouseDownPoint.x
        let dy = event.locationInWindow.y - mouseDownPoint.y
        if !isDraggingOut, (abs(dx) > 4 || abs(dy) > 4) {
            isDraggingOut = true
            beginFileDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDraggingOut { onClick?() }   // bấm mà không kéo = mở editor
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let fileURL = fileURL, let image = image else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: pad, dy: pad), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // ── Theo dõi rê chuột: hiện/ẩn nút + tạm dừng tự-ẩn ──────────────────
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        hoverControls.forEach { $0.isHidden = false }
    }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        hoverControls.forEach { $0.isHidden = true }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Controller: hiện/ẩn panel preview nổi ở góc dưới-trái màn hình.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class ThumbnailController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var pinned = false

    func show(image: NSImage,
              fileURL: URL,
              isVideo: Bool = false,
              onEdit: @escaping () -> Void,
              onCopy: @escaping () -> Void,
              onSave: @escaping () -> Void,
              onTrim: (() -> Void)? = nil) {
        hide()   // dọn cái cũ trước
        pinned = false

        // Card CHỮ NHẬT cố định 200×160. Ảnh aspect-fill bên trong (xem draw()).
        let pad = ThumbnailView.pad
        let card = CGSize(width: 210, height: 150)
        let size = NSSize(width: card.width + pad * 2, height: card.height + pad * 2)

        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let origin = NSPoint(x: screen.visibleFrame.minX + margin,
                             y: screen.visibleFrame.minY + margin)   // góc dưới-trái
        let frame = NSRect(origin: origin, size: size)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.fileURL = fileURL
        view.isVideo = isVideo
        view.onClick = onEdit
        view.onCopy = onCopy
        view.onSave = onSave
        view.onTrim = onTrim
        view.onClose = { [weak self] in self?.dismiss(slide: true) }
        view.onPin = { [weak self] in
            guard let self else { return }
            self.pinned.toggle()
            if self.pinned { self.dismissTask?.cancel() }
        }
        view.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.dismissTask?.cancel() }        // rê vào: giữ lại
            else if !self.pinned { self.scheduleDismiss(after: 1.5) }  // rê ra: ẩn (trừ khi ghim)
        }
        p.contentView = view

        // Trượt VÀO từ mép trái (đối xứng với lúc đóng trượt ra) + fade.
        var startFrame = frame
        startFrame.origin.x -= frame.width + 40   // bắt đầu ngoài mép trái
        p.setFrame(startFrame, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
        self.panel = p

        scheduleDismiss(after: 8)   // rê chuột vào / ghim sẽ huỷ hẹn ẩn
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // Trượt panel sang trái khỏi màn rồi ẩn hẳn (dùng cho Copy / Edit / Discard).
    func dismiss(slide: Bool) {
        dismissTask?.cancel(); dismissTask = nil
        guard slide, let p = panel else { hide(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var f = p.frame
            f.origin.x -= f.width + 40   // ra hẳn ngoài mép trái
            p.animator().setFrame(f, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.hide() }   // completion chạy trên main
        })
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}
