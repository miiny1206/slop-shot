import ScreenCaptureKit   // SCStream: "vòi" bắn ra từng frame màn hình
import AVFoundation        // AVAssetWriter: gom frame → nén H.264 → ghi file .mov
import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Quay 1 VÙNG màn hình ra file .mov.
//
//   SCStream  ──(mỗi frame là 1 CMSampleBuffer)──►  AVAssetWriterInput  ──►  file .mov
//
// Lưu ý threading: SCStream trả frame trên 1 background queue (`queue`),
// KHÔNG phải main thread. AVAssetWriter lại không an toàn đa luồng, nên TẤT CẢ
// thao tác ghi (append/finish) đều dồn về đúng `queue` đó để khỏi đụng độ.
// Vì thế class này KHÔNG đánh @MainActor — start()/stop() gọi từ main vẫn ok.
// ─────────────────────────────────────────────────────────────────────────
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false      // đã startSession ở frame đầu chưa
    private(set) var url: URL?       // file .mov tạm đang ghi

    // Pause/resume: AVAssetWriter không có "pause", nên ta TỰ trừ thời gian đã
    // tạm dừng ra khỏi mốc của mọi frame sau đó → clip liền mạch, không đơ.
    private var paused = false
    private var resuming = false             // frame đầu ngay sau khi resume
    private var timeOffset = CMTime.zero     // tổng thời gian đã pause (để trừ đi)
    private var lastOrigPTS = CMTime.invalid // PTS gốc của frame cuối trước khi pause

    // Hàng đợi nối tiếp: vừa nhận frame vừa ghi file, không tranh chấp.
    private let queue = DispatchQueue(label: "com.thanglb.slopshot.recorder")

    var isRunning: Bool { stream != nil }
    var isPaused: Bool { paused }

    // ── Bắt đầu quay vùng `rect` (points, gốc trên-trái màn hình) ──────────
    func start(rect: CGRect, screen: NSScreen) async throws {
        // 1) Tìm SCDisplay khớp với NSScreen.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID })
                ?? content.displays.first else {
            throw err("No display found to record.")
        }

        // 2) Kích thước pixel = points × scale. H.264 cần chiều CHẴN nên ép chẵn.
        let scale = screen.backingScaleFactor
        var pxW = Int((rect.width  * scale).rounded()); if pxW % 2 != 0 { pxW -= 1 }
        var pxH = Int((rect.height * scale).rounded()); if pxH % 2 != 0 { pxH -= 1 }
        pxW = max(pxW, 2); pxH = max(pxH, 2)

        // 3) File .mov tạm (bấm Save trên preview mới lưu đích thật).
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlopShot \(timestamp()).mov")
        try? FileManager.default.removeItem(at: outURL)

        // 4) Bộ ghi file + 1 "input" video H.264.
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  pxW,
            AVVideoHeightKey: pxH,
        ])
        input.expectsMediaDataInRealTime = true   // dữ liệu đến theo thời gian thực
        writer.add(input)

        // 5) Cấu hình stream: CROP đúng vùng chọn qua sourceRect.
        let config = SCStreamConfiguration()
        config.sourceRect = rect                  // chỉ lấy vùng này (points, gốc trên-trái)
        config.width  = pxW                        // cỡ pixel xuất ra
        config.height = pxH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // tối đa 60 fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true                  // quay cả con trỏ
        config.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        self.writer = writer; self.input = input; self.url = outURL; self.stream = stream
        // Reset state pause cho lần quay mới (frame chưa về nên chưa có tranh chấp).
        self.started = false; self.paused = false; self.resuming = false
        self.timeOffset = .zero; self.lastOrigPTS = .invalid

        try await stream.startCapture()
    }

    // ── Tạm dừng / tiếp tục ────────────────────────────────────────────────
    func pause()  { queue.async { self.paused = true } }
    func resume() { queue.async { self.paused = false; self.resuming = true } }

    // ── Huỷ quay: tắt stream, bỏ file đang ghi, không lưu gì ────────────────
    func discard() async {
        if let stream { try? await stream.stopCapture(); self.stream = nil }
        let fileURL = url
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                self?.input?.markAsFinished()
                self?.writer?.cancelWriting()
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                self?.reset()
                cont.resume()
            }
        }
    }

    // ── Dừng quay: tắt stream → đóng file → trả về URL (nil nếu hỏng) ───────
    func stop() async -> URL? {
        guard let stream = stream else { return url }
        try? await stream.stopCapture()
        self.stream = nil

        // Đóng file trên `queue` để chắc chắn mọi frame đã append xong.
        return await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let writer = self.writer, let input = self.input, self.started else {
                    cont.resume(returning: nil); return
                }
                let fileURL = self.url
                input.markAsFinished()
                writer.finishWriting {
                    let result = writer.status == .completed ? fileURL : nil
                    self.queue.async { self.reset() }
                    cont.resume(returning: result)
                }
            }
        }
    }

    // ── SCStreamOutput: nhận từng frame (chạy trên `queue`, KHÔNG phải main) ─
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Chỉ nhận frame trạng thái .complete (bỏ frame "không đổi"/nhàn rỗi).
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let writer, let input else { return }

        let origPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Đang pause: bỏ frame, KHÔNG cập nhật lastOrigPTS (giữ mốc trước pause).
        if paused { return }

        // Frame đầu tiên: mở "phiên ghi", lấy mốc thời gian chính là PTS của nó.
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: origPTS)
            started = true
        }

        // Frame đầu sau khi resume: cộng khoảng vừa pause vào offset để trừ đi.
        // CHỪA LẠI 1 khoảng-frame, nếu không mốc của frame này sẽ TRÙNG đúng
        // frame cuối trước pause → AVAssetWriter đòi mốc tăng dần nên fail cả file.
        if resuming {
            if lastOrigPTS.isValid {
                var frameDur = CMSampleBufferGetDuration(sampleBuffer)
                if !frameDur.isValid || frameDur.value <= 0 {
                    frameDur = CMTime(value: 1, timescale: 60)   // ~1 frame ở 60fps
                }
                let gap = CMTimeSubtract(CMTimeSubtract(origPTS, lastOrigPTS), frameDur)
                if gap.value > 0 {
                    timeOffset = CMTimeAdd(timeOffset, gap)
                }
            }
            resuming = false
        }
        lastOrigPTS = origPTS

        // Trừ tổng thời gian đã pause khỏi mốc của frame này.
        let outBuffer = (timeOffset.value > 0)
            ? (adjustTiming(sampleBuffer, by: timeOffset) ?? sampleBuffer)
            : sampleBuffer

        if input.isReadyForMoreMediaData {
            input.append(outBuffer)
        }
    }

    // Tạo bản sao sample buffer với mốc thời gian đã dời lùi `offset`.
    private func adjustTiming(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in 0..<count {
            info[i].presentationTimeStamp = CMTimeSubtract(info[i].presentationTimeStamp, offset)
            if info[i].decodeTimeStamp.isValid {
                info[i].decodeTimeStamp = CMTimeSubtract(info[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: count, sampleTimingArray: &info,
                                              sampleBufferOut: &out)
        return out
    }

    // Trả state về 0 cho lần quay sau (gọi sau stop/discard).
    private func reset() {
        writer = nil; input = nil; url = nil
        started = false; paused = false; resuming = false
        timeOffset = .zero; lastOrigPTS = .invalid
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SlopShot: recording stream stopped with error — \(error.localizedDescription)")
    }

    // ── tiện ích nhỏ ──────────────────────────────────────────────────────
    private func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
    private func err(_ msg: String) -> NSError {
        NSError(domain: "SlopShot", code: 10, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
