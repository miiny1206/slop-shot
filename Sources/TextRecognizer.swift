import Vision   // framework OCR có sẵn của Apple — chạy on-device, không cần mạng
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────
// Nhận chữ trong 1 ảnh (OCR). Vision tự lo phần máy học, ta chỉ gọi & gom kết quả.
//
// React analogy: như 1 hàm async tiện ích `await ocr(image)` trả về string,
// không giữ state gì — nên để static cho gọn.
// ─────────────────────────────────────────────────────────────────────────
enum TextRecognizer {

    // Trả về toàn bộ chữ đọc được (mỗi dòng cách nhau bằng "\n"). "" nếu không có chữ.
    static func recognize(in cgImage: CGImage) async -> String {
        await withCheckedContinuation { cont in
            // 1) Tạo "yêu cầu" nhận chữ. Callback chạy khi Vision xử lý xong.
            let request = VNRecognizeTextRequest { req, _ in
                // Mỗi observation = 1 dòng chữ Vision tìm thấy; lấy ứng viên tốt nhất.
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            // .accurate = ưu tiên độ chính xác hơn tốc độ (ảnh tĩnh nên chấp nhận chậm hơn).
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // 2) Chạy request trên ảnh. Đẩy sang background để khỏi chặn main thread.
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }
}
