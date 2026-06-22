import ScreenCaptureKit   // API của Apple để chụp/record màn hình (CleanShot cũng xài cái này)
import AppKit             // NSBitmapImageRep, NSScreen, NSWorkspace...
import AVFoundation        // tạo ảnh poster từ video (1 frame đầu)
import UniformTypeIdentifiers   // UTType.quickTimeMovie cho save panel

// "Store" nhỏ: chứa logic chụp + state để UI bám vào.
// ObservableObject ~ 1 store Zustand. @Published ~ các slice state.
// @MainActor: đảm bảo cập nhật state luôn chạy trên main thread (UI thread).
@MainActor
final class ScreenCapturer: ObservableObject {

    @Published var lastStatus: String = ""   // rỗng = chưa làm gì → menu không hiện dòng status
    @Published var lastSavedURL: URL?
    @Published var isRecording = false   // đang quay vùng hay không

    private let selection = RegionSelectionController()
    private let thumbnail = ThumbnailController()
    private let editor = EditorWindowController()
    private let recorder = ScreenRecorder()
    private let videoViewer = VideoPlayerWindowController()       // 👁 Quick Look clip trong app
    private let videoTrimmer = VideoTrimWindowController()        // ✂️ cắt + đổi định dạng clip
    private let recordingBar = RecordingBarController()
    private let recordingOverlay = RecordingOverlayController()   // dim + viền focus
    private let clickEffect = ClickEffectController()             // vòng tròn click
    private let scrollCapture = ScrollCaptureController()         // chụp cuộn (ghép ảnh dài)
    private let settings = AppSettings.shared                     // cấu hình (folder/format…)
    private let history = CaptureHistory.shared                   // lịch sử capture
    private let historyWindow = HistoryWindowController()
    private let settingsWindow = SettingsWindowController()
    private var recRect: CGRect = .zero      // vùng đang quay (để Restart)
    private var recScreen: NSScreen?         // màn hình đang quay
    private var lastImage: NSImage?   // giữ ảnh gần nhất để mở editor

    // Chỉ ẢNH mới mở được editor; clip video thì không (lastImage = nil).
    var canEditLast: Bool { lastImage != nil }

    // Bắt đầu chụp/quay mới → tự đóng MỌI cửa sổ đang mở (editor ảnh, Quick Look,
    // Trim) mà KHÔNG lưu — giống CleanShot. Tránh việc thao tác mới nhảy về cái cũ.
    private func dismissOpenEditors() {
        editor.dismiss()
        videoViewer.dismiss()
        videoTrimmer.dismiss()
    }

    // Mở editor cho ảnh gần nhất (gọi từ menu).
    func openLastInEditor() {
        guard let img = lastImage else { return }
        editor.open(image: img, sourceURL: lastSavedURL)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BƯỚC 1: chụp toàn màn hình chính.
    // ═══════════════════════════════════════════════════════════════════════
    func captureFullScreen() async {
        dismissOpenEditors()   // chụp mới → tự đóng editor cũ (không lưu), như CleanShot
        // Ẩn thumbnail cũ để nó không lọt vào ảnh mới, đợi nó biến mất khỏi màn hình.
        thumbnail.hide()
        try? await Task.sleep(nanoseconds: 120_000_000)

        do {
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let display = try await shareableDisplay(for: screen)
            let cgImage = try await captureImage(of: display, scale: screen.backingScaleFactor)
            finishImage(cgImage, subtitle: "\(cgImage.width)×\(cgImage.height)px")
        } catch {
            lastStatus = "❌ \(error.localizedDescription)\n→ Open System Settings › Privacy & Security › Screen Recording, enable SlopShot, then reopen the app."
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BƯỚC 2: kéo chuột chọn vùng rồi chụp đúng vùng đó.
    // ═══════════════════════════════════════════════════════════════════════
    func captureRegion() async {
        dismissOpenEditors()   // chụp mới → tự đóng editor cũ (không lưu)
        // Chọn màn hình đang có con trỏ chuột (xài đa màn hình vẫn đúng).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first!

        // Ẩn thumbnail cũ để nó không lọt vào ảnh chụp.
        thumbnail.hide()

        // Bọc callback chọn vùng thành async/await cho gọn (continuation = "Promise" của Swift).
        let rectInScreen: CGRect? = await withCheckedContinuation { cont in
            selection.begin(on: screen) { rect in
                cont.resume(returning: rect)
            }
        }

        guard let rect = rectInScreen else {
            lastStatus = "Selection cancelled."
            return
        }

        // Đợi overlay biến mất hẳn khỏi màn hình rồi mới chụp (~150ms).
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            let cropped = try await captureCropped(rect: rect, on: screen)
            finishImage(cropped, subtitle: "\(cropped.width)×\(cropped.height)px")
        } catch {
            lastStatus = "❌ \(error.localizedDescription)"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // OCR: kéo chọn vùng → đọc chữ trong vùng → copy thẳng text vào clipboard.
    // ═══════════════════════════════════════════════════════════════════════
    func captureText() async {
        dismissOpenEditors()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        thumbnail.hide()

        let rect: CGRect? = await withCheckedContinuation { cont in
            selection.begin(on: screen) { cont.resume(returning: $0) }
        }
        guard let rect else { lastStatus = "Text capture cancelled."; return }
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            let cropped = try await captureCropped(rect: rect, on: screen)
            let text = await TextRecognizer.recognize(in: cropped)
            guard !text.isEmpty else { lastStatus = "No text found in the selected area."; return }

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            let count = text.count
            history.add(kind: .text, fileURL: nil, text: text,
                        subtitle: "\(count) chars", thumbnail: nil)
            lastStatus = "✅ Copied \(count) character\(count == 1 ? "" : "s") of text to clipboard."
        } catch {
            lastStatus = "❌ \(error.localizedDescription)"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CHỤP CUỘN: chọn vùng → vừa cuộn vừa chụp → ghép thành 1 ảnh dài.
    // ═══════════════════════════════════════════════════════════════════════
    func captureScrollingArea() async {
        dismissOpenEditors()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        thumbnail.hide()

        let rect: CGRect? = await withCheckedContinuation { cont in
            selection.begin(on: screen) { cont.resume(returning: $0) }
        }
        guard let rect else { lastStatus = "Scrolling capture cancelled."; return }
        try? await Task.sleep(nanoseconds: 150_000_000)

        recordingOverlay.show(rect: rect, on: screen)   // tối xung quanh + viền focus
        lastStatus = "Scroll through the area, then click Done."

        do {
            // start() bật phiên rồi trả về ngay; continuation chờ tới khi bấm Done/Cancel.
            // onStop chạy NGAY lúc bấm Done → ẩn viền đỏ liền, không đợi dựng ảnh dài
            // (ảnh có thể rất cao nên dựng mất chút thời gian).
            let result: CGImage? = try await withCheckedThrowingContinuation { cont in
                Task { @MainActor in
                    do {
                        try await scrollCapture.start(
                            rect: rect, screen: screen,
                            onStop: { [weak self] in self?.recordingOverlay.hide() },
                            onFinish: { image in cont.resume(returning: image) })
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            recordingOverlay.hide()

            guard let cg = result else {
                lastStatus = "Scrolling capture cancelled (nothing captured)."
                return
            }
            finishImage(cg, subtitle: "\(cg.width)×\(cg.height)px (scrolling)")
        } catch {
            recordingOverlay.hide()
            lastStatus = "❌ Scrolling capture failed: \(error.localizedDescription)"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BƯỚC 3: QUAY VIDEO 1 vùng màn hình. Bấm lần nữa (hoặc nút ⏹) để dừng.
    // ═══════════════════════════════════════════════════════════════════════
    func recordRegion() async {
        // Đang quay → coi như lệnh dừng (để phím tắt bật/tắt cùng 1 tổ hợp).
        if isRecording { await stopRecording(); return }
        dismissOpenEditors()   // bắt đầu quay mới → đóng editor cũ (không lưu)

        // Chọn màn hình đang có con trỏ (giống captureRegion).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first!

        thumbnail.hide()

        // Kéo chuột chọn vùng (tái dùng overlay của chụp ảnh).
        let rect: CGRect? = await withCheckedContinuation { cont in
            selection.begin(on: screen) { cont.resume(returning: $0) }
        }
        guard let rect else { lastStatus = "Recording cancelled."; return }

        // Đợi overlay biến mất rồi mới bật stream (~150ms).
        try? await Task.sleep(nanoseconds: 150_000_000)

        do {
            try await recorder.start(rect: rect, screen: screen)
            isRecording = true
            recRect = rect; recScreen = screen
            recordingBar.onStop      = { [weak self] in Task { await self?.stopRecording() } }
            recordingBar.onPauseToggle = { [weak self] paused in
                if paused { self?.recorder.pause() } else { self?.recorder.resume() }
            }
            recordingBar.onRestart   = { [weak self] in Task { await self?.restartRecording() } }
            recordingBar.onDiscard   = { [weak self] in Task { await self?.discardRecording() } }
            recordingOverlay.show(rect: rect, on: screen)   // tối xung quanh + viền focus
            recordingBar.show(below: rect, on: screen)
            // Vùng quay theo toạ độ AppKit toàn cục (gốc dưới-trái) cho hiệu ứng click.
            let globalRegion = CGRect(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.minY + (screen.frame.height - rect.maxY),
                width: rect.width, height: rect.height)
            clickEffect.start(in: globalRegion)
            lastStatus = "🔴 Recording… click ⏹ (or ⌃⌥⌘5) to stop."
        } catch {
            recordingOverlay.hide()
            lastStatus = "❌ Couldn't start recording: \(error.localizedDescription)"
        }
    }

    // Quay lại từ đầu: bỏ clip hiện tại rồi bật quay lại đúng vùng đó.
    func restartRecording() async {
        guard isRecording, let screen = recScreen else { return }
        await recorder.discard()
        do {
            try await recorder.start(rect: recRect, screen: screen)
            lastStatus = "🔴 Restarting…"
        } catch {
            isRecording = false
            recordingBar.hide()
            lastStatus = "❌ Couldn't restart: \(error.localizedDescription)"
        }
    }

    // Huỷ: dừng + xoá file, không hiện preview.
    func discardRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordingBar.hide()
        recordingOverlay.hide()
        clickEffect.stop()
        await recorder.discard()
        lastStatus = "Recording discarded (not saved)."
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordingBar.hide()
        recordingOverlay.hide()
        clickEffect.stop()

        guard let tmpURL = await recorder.stop() else {
            lastStatus = "❌ Recording failed (no frames captured)."
            return
        }

        // Giữ nguyên file .mov TẠM; bấm Save trên preview mới copy ra folder.
        let url = tmpURL

        // Chép FILE video lên clipboard (tùy cài đặt).
        if settings.copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
        }

        lastSavedURL = url
        lastImage = nil
        lastStatus = "✅ Recording finished. Click Save to keep it."

        // Poster = 1 frame của video để làm ảnh thu nhỏ cho preview card.
        let poster = await posterImage(for: url) ?? NSImage(size: NSSize(width: 16, height: 9))

        // Ghi vào lịch sử (kèm thời lượng).
        history.add(kind: .video, fileURL: url, text: nil,
                    subtitle: await videoDuration(url), thumbnail: poster)

        guard settings.showThumbnail else { return }
        thumbnail.show(
            image: poster,
            fileURL: url,
            isVideo: true,
            onEdit: { [weak self] in self?.videoViewer.open(url: url) },   // 👁 Quick Look trong app
            onCopy: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([url as NSURL])
            },
            onSave: { [weak self] in self?.quickSaveVideo(url) },
            onTrim: { [weak self] in   // ✂️ mở tool trim với clip vừa quay
                guard let self else { return }
                self.videoTrimmer.onDone = { [weak self] out in
                    guard let self, let out else { return }
                    self.lastSavedURL = out
                    self.lastStatus = "✅ Exported to \(self.settings.saveFolderDisplay)"
                }
                self.videoTrimmer.open(url: url, saveFolder: self.settings.saveFolderURL)
            }
        )
    }

    // Thời lượng video → "m:ss" cho phụ đề lịch sử. (load(.duration) async, không deprecated)
    private func videoDuration(_ url: URL) async -> String {
        let dur = (try? await AVURLAsset(url: url).load(.duration)) ?? .zero
        let secs = CMTimeGetSeconds(dur)
        guard secs.isFinite, secs >= 0 else { return "video" }
        let s = Int(secs.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // Lấy 1 khung hình ~0.1s đầu làm ảnh đại diện (tránh frame đen đầu clip).
    private func posterImage(for url: URL) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        // image(at:) async thay cho copyCGImage (deprecated từ macOS 15).
        guard let r = try? await gen.image(at: time) else { return nil }
        return NSImage(cgImage: r.image, size: NSSize(width: r.image.width, height: r.image.height))
    }

    // Bấm "Save" trên preview ẢNH: ghi THẲNG vào folder đích (đúng định dạng đã chọn).
    private func quickSaveImage(_ cgImage: CGImage, baseName: String) {
        do {
            let dest = try writeImage(cgImage, baseName: baseName, to: settings.saveFolderURL)
            lastSavedURL = dest
            lastStatus = "✅ Saved to \(settings.saveFolderDisplay)"
            // KHÔNG hide() ở đây — preview tự hiện tick rồi trượt đi (như Copy).
        } catch {
            lastStatus = "❌ Save failed: \(error.localizedDescription)"
        }
    }

    // Bấm "Save" trên preview VIDEO: copy .mov tạm THẲNG vào folder đích.
    private func quickSaveVideo(_ url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: settings.saveFolderURL, withIntermediateDirectories: true)
            let dest = uniqueURL(settings.saveFolderURL.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: dest)
            lastSavedURL = dest
            lastStatus = "✅ Saved to \(settings.saveFolderDisplay)"
            // KHÔNG hide() ở đây — preview tự hiện tick rồi trượt đi (như Copy).
        } catch {
            lastStatus = "❌ Save failed: \(error.localizedDescription)"
        }
    }

    // Lưu 1 mục lịch sử vào folder đích (copy file gốc sang, không hỏi).
    private func saveHistoryItemToFolder(_ src: URL) {
        do {
            try FileManager.default.createDirectory(
                at: settings.saveFolderURL, withIntermediateDirectories: true)
            let dest = uniqueURL(settings.saveFolderURL.appendingPathComponent(src.lastPathComponent))
            try FileManager.default.copyItem(at: src, to: dest)
            lastStatus = "✅ Saved to \(settings.saveFolderDisplay)"
        } catch {
            lastStatus = "❌ Save failed: \(error.localizedDescription)"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Sau khi chụp xong: chép clipboard + hiện thumbnail nổi + cập nhật state.
    // ═══════════════════════════════════════════════════════════════════════
    private func finishImage(_ cgImage: CGImage, subtitle: String) {
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))
        let baseName = "SlopShot \(timestampNow())"

        // 1) LUÔN ghi tạm. File thật chỉ ra khi user bấm Save trên preview.
        let url = try? saveTempPNG(cgImage)

        // 2) Clipboard (tùy cài đặt): chép cả ảnh lẫn file.
        if settings.copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let url { pb.writeObjects([nsImage, url as NSURL]) } else { pb.writeObjects([nsImage]) }
        }

        lastImage = nsImage
        lastSavedURL = url

        // 3) Ghi vào lịch sử.
        history.add(kind: .image, fileURL: url, text: nil, subtitle: subtitle, thumbnail: nsImage)

        // 4) Trạng thái.
        lastStatus = settings.copyToClipboard
            ? "✅ \(subtitle) · copied to clipboard."
            : "✅ Captured \(subtitle)."

        // 5) Preview thumbnail. Save = ghi THẲNG vào folder đích (không hỏi).
        guard settings.showThumbnail, let url else { return }
        thumbnail.show(
            image: nsImage,
            fileURL: url,
            onEdit: { [weak self] in self?.editor.open(image: nsImage, sourceURL: url) },
            onCopy: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([nsImage, url as NSURL])
            },
            onSave: { [weak self] in self?.quickSaveImage(cgImage, baseName: baseName) }
        )
    }

    // Ghi CGImage thành file ảnh (theo format đã chọn) vào `folder`, tránh trùng tên.
    @discardableResult
    private func writeImage(_ cgImage: CGImage, baseName: String, to folder: URL) throws -> URL {
        let fmt = settings.imageFormat
        guard let data = fmt.encode(cgImage) else {
            throw NSError(domain: "SlopShot", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the image."])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = uniqueURL(folder.appendingPathComponent("\(baseName).\(fmt.ext)"))
        try data.write(to: dest)
        return dest
    }

    // Nếu file đã tồn tại thì thêm " (2)", " (3)"… để khỏi ghi đè.
    private func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(name) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private func timestampNow() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    // ── Mở cửa sổ History / Settings (gọi từ menu) ─────────────────────────
    func showHistory() {
        let actions = HistoryActions(
            copy:   { [weak self] in self?.historyCopy($0) },
            saveAs: { [weak self] in self?.historySaveAs($0) },
            edit:   { [weak self] in self?.historyEdit($0) },
            open:   { [weak self] in if let u = $0.fileURL { NSWorkspace.shared.open(u) } },
            delete: { [weak self] in self?.history.remove($0) },
            openSettings: { [weak self] in self?.showSettings() }
        )
        historyWindow.show(history: history, actions: actions)
    }

    func showSettings() { settingsWindow.show(settings: settings) }

    // Copy 1 mục lịch sử lên clipboard.
    private func historyCopy(_ item: HistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.kind == .text, let text = item.text {
            pb.setString(text, forType: .string)
        } else if let url = item.fileURL {
            if item.kind == .image, let img = NSImage(contentsOf: url) {
                pb.writeObjects([img, url as NSURL])
            } else {
                pb.writeObjects([url as NSURL])
            }
        }
        lastStatus = "✅ Copied from history."
    }

    // "Save" cho 1 mục lịch sử: copy file vào folder đích (không hỏi).
    private func historySaveAs(_ item: HistoryItem) {
        guard let url = item.fileURL else { return }
        saveHistoryItemToFolder(url)
    }

    // Mở editor cho 1 ảnh trong lịch sử.
    private func historyEdit(_ item: HistoryItem) {
        guard item.kind == .image, let url = item.fileURL,
              let img = NSImage(contentsOf: url) else { return }
        editor.open(image: img, sourceURL: url)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Hàm dùng chung
    // ═══════════════════════════════════════════════════════════════════════

    // Tìm SCDisplay (ScreenCaptureKit) tương ứng với 1 NSScreen.
    // Dòng SCShareableContent cũng là chỗ macOS xin quyền Screen Recording lần đầu.
    private func shareableDisplay(for screen: NSScreen) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        if let match = content.displays.first(where: { $0.displayID == screen.displayID }) {
            return match
        }
        guard let any = content.displays.first else {
            throw NSError(domain: "SlopShot", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No display found."])
        }
        return any
    }

    // Chụp toàn màn hình rồi CẮT đúng vùng `rect` (points) → CGImage vùng đó.
    // Dùng chung cho chụp vùng + OCR.
    private func captureCropped(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let scale = screen.backingScaleFactor
        let display = try await shareableDisplay(for: screen)
        let cgFull = try await captureImage(of: display, scale: scale)

        // Đổi rect (points, gốc trên-trái) → rect pixel để cắt ảnh.
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
        // Cắt cho an toàn trong biên ảnh.
        let imageBounds = CGRect(x: 0, y: 0, width: cgFull.width, height: cgFull.height)
        let safeRect = pixelRect.intersection(imageBounds).integral

        guard let cropped = cgFull.cropping(to: safeRect) else {
            throw NSError(domain: "SlopShot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't crop the selected area."])
        }
        return cropped
    }

    // Chụp nguyên 1 display → CGImage (đúng độ phân giải pixel theo scale).
    private func captureImage(of display: SCDisplay, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width  = Int(CGFloat(display.width)  * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    // Đổi CGImage → PNG → ghi vào THƯ MỤC TẠM (chưa lưu chính thức).
    // Người dùng bấm Save trên preview mới chọn đích lưu thật.
    private func saveTempPNG(_ cgImage: CGImage) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SlopShot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create PNG data."])
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "SlopShot \(formatter.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

}
