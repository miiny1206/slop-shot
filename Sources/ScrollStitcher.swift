import CoreGraphics
import AppKit

// Kết quả nạp 1 frame: tiến thêm / đứng yên / cuộn quá nhanh (khớp thất bại).
enum AddOutcome { case advanced, idle, tooFast }

// ─────────────────────────────────────────────────────────────────────────
// Ghép nhiều ảnh chụp CÙNG 1 vùng (chụp lại liên tục trong lúc user cuộn)
// thành 1 ảnh DÀI duy nhất.
//
// Ý tưởng: 2 frame chụp liên tiếp gần như giống nhau, chỉ bị "trượt lên" một
// đoạn = quãng vừa cuộn. Ta dò xem trượt bao nhiêu hàng pixel (`d`), rồi chỉ
// nối thêm `d` hàng MỚI ở đáy frame sau vào ảnh tích luỹ. Lặp lại → ảnh dài.
//
//   frame trước:  [A B C D E]          (E = hàng dưới cùng đang thấy)
//   cuộn xuống →  frame sau: [C D E F G]   ⇒ trượt d=2, hàng mới = F G
//   ảnh ghép:     [A B C D E F G ...]
//
// Khớp bằng "chữ ký" mỗi hàng (downsample hàng thành 16 mẫu) cho nhanh & ít
// nhiễu, thay vì so từng pixel.
// ─────────────────────────────────────────────────────────────────────────
final class ScrollStitcher {
    private let width: Int          // bề rộng pixel (cố định theo vùng chọn)
    private let bytesPerRow: Int    // = width * 4 (RGBA)
    private let samples = 16        // số mẫu/hàng khi tạo chữ ký

    private var accum: [UInt8] = [] // toàn bộ pixel RGBA đã ghép (row-major)
    private var rows = 0            // số hàng đã ghép

    // Chữ ký của FRAME ĐẦY ĐỦ gần nhất (để so với frame kế tiếp tìm `d`).
    private var lastSig: [[Float]] = []
    private var frameHeight = 0

    // Preview thu nhỏ, XÂY DẦN cho nhẹ (chỉ lấy mẫu thưa các hàng mới thêm).
    // Nhờ vậy hiện cả ảnh dài đang lớn dần mà không phải scale lại ảnh gốc mỗi nhịp.
    private var previewStep = 0     // bước lấy mẫu (≈ tỉ lệ thu nhỏ)
    private var previewW = 0        // bề rộng preview (px)
    private var previewAccum: [UInt8] = []
    private var previewRows = 0

    var capturedRows: Int { rows }
    var hasContent: Bool { rows > 0 }

    init(width: Int) {
        self.width = max(width, 1)
        self.bytesPerRow = self.width * 4
    }

    // Bật preview: chọn bề rộng đích → suy ra bước lấy mẫu (thu nhỏ giữ tỉ lệ).
    func enablePreview(targetWidth: Int) {
        previewStep = max(width / max(targetWidth, 1), 1)
        previewW = max(width / previewStep, 1)
        previewAccum = []
        previewRows = 0
    }

    // Nạp các hàng source [y0, y1) vào preview: lấy mẫu thưa (1 pixel/ô) cho nhanh.
    private func appendPreview(from pixels: [UInt8], y0: Int, y1: Int) {
        guard previewW > 0 else { return }
        let bucket = previewStep
        var y = y0
        previewAccum.reserveCapacity(previewAccum.count + ((y1 - y0) / max(previewStep, 1)) * previewW * 4)
        while y < y1 {
            let rowBase = y * bytesPerRow
            for sx in 0 ..< previewW {
                let srcX = min(sx * bucket + bucket / 2, width - 1)
                let p = rowBase + srcX * 4
                previewAccum.append(pixels[p]); previewAccum.append(pixels[p + 1])
                previewAccum.append(pixels[p + 2]); previewAccum.append(255)
            }
            previewRows += 1
            y += previewStep
        }
    }

    // Ảnh preview hiện tại (nhỏ → tạo nhanh, gọi mỗi nhịp được).
    func previewImage() -> CGImage? {
        guard previewW > 0, previewRows > 0 else { return nil }
        let bpr = previewW * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(previewAccum) as CFData) else { return nil }
        return CGImage(
            width: previewW, height: previewRows,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
            space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // ── Nạp 1 frame mới (gọi mỗi lần chụp lại vùng) ────────────────────────
    // knownShift: độ trượt CHÍNH XÁC (px) đo từ AX. Có thì dùng thẳng (khỏi dò
    // ảnh, không bao giờ "tooFast"); nil thì rơi về dò khớp bằng chữ ký hàng.
    @discardableResult
    func add(frame cg: CGImage, knownShift: Int? = nil) -> AddOutcome {
        guard cg.width == width, cg.height > 0,
              let (pixels, sig) = decode(cg) else { return .idle }
        let h = cg.height

        // Frame đầu tiên: lấy nguyên làm nền.
        if !hasContent {
            accum = pixels
            rows = h
            lastSig = sig
            frameHeight = h
            appendPreview(from: pixels, y0: 0, y1: h)
            return .advanced
        }

        // Độ trượt d: ưu tiên offset AX (chính xác), nếu không có thì dò ảnh.
        let d: Int
        if let k = knownShift {
            // Tin offset AX, chỉ kẹp về [0,h] cho an toàn.
            d = max(0, min(k, h))
            lastSig = sig
        } else {
            // Dò bằng chữ ký hàng. s < 0 = KHỚP THẤT BẠI (cuộn quá nhanh / đổi hẳn):
            // KHÔNG ghi đè gì, giữ mỏ neo cũ, báo .tooFast để UI hiện "slow down".
            let s = bestShift(prev: lastSig, next: sig, height: h)
            guard s >= 0 else { return .tooFast }
            lastSig = sig
            guard s <= h else { return .idle }
            d = s
        }

        let overlap = h - d                 // số hàng frame mới CHỒNG lên ảnh hiện có
        let (bandTop, bandH) = bandGeometry(h)
        // Chỉ "heal" từ dưới band trở xuống → chắc chắn là nội dung cuộn, KHÔNG
        // phải header dính ở trên (tránh dán nhầm header vào giữa trang).
        let safeTop = min(bandTop + bandH, overlap)

        // GHI ĐÈ phần chồng (dưới band) của ảnh hiện có bằng pixel tươi của frame
        // mới. Nhờ vậy vết ghép hơi lệch của frame TRƯỚC bị frame này lấp lại →
        // ảnh liền mạch thay vì có đường rách.
        if overlap > safeTop {
            let dstStart = (rows - overlap + safeTop) * bytesPerRow
            let srcStart = safeTop * bytesPerRow
            let srcEnd   = overlap * bytesPerRow
            accum.replaceSubrange(dstStart ..< accum.count, with: pixels[srcStart ..< srcEnd])
        }

        // Nối `d` hàng MỚI ở đáy (vùng [overlap ..< h]).
        if d > 0 {
            accum.append(contentsOf: pixels[overlap * bytesPerRow ..< pixels.count])
            rows += d
            appendPreview(from: pixels, y0: overlap, y1: h)
            return .advanced
        }
        return .idle
    }

    // Hình học của "dải mẫu" (band): bắt đầu ~20% và cao ~18% chiều cao.
    // Dùng chung cho cả dò khớp lẫn vùng heal an toàn.
    private func bandGeometry(_ h: Int) -> (top: Int, height: Int) {
        // top ~16.7% (vẫn bỏ qua header dính), band ~14% → tầm dò d tối đa ~0.69h
        // (rộng hơn trước, đỡ "kẹt" khi user cuộn nhanh một chút).
        (max(h / 6, 4), max(h * 14 / 100, 8))
    }

    // ── Xuất ảnh dài cuối cùng ─────────────────────────────────────────────
    func finalImage() -> CGImage? {
        guard rows > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(accum) as CFData) else { return nil }
        return CGImage(
            width: width, height: rows,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    // ───────────────────────────────────────────────────────────────────────
    // Tìm độ trượt d: frame sau bị đẩy LÊN d hàng so với frame trước.
    // Tức next.row[y] ≈ prev.row[y+d].
    //
    // Mẹo: KHÔNG dò cả frame (vừa chậm O(h²), vừa dễ dính header/footer cố
    // định). Thay vào đó lấy 1 "dải" (band) Ở GIỮA-TRÊN frame sau rồi tìm xem
    // nó nằm ở đâu trong frame trước → chỉ O(band × tầm-dò), nhanh hơn nhiều
    // và né được thanh header dính (vì band không lấy từ sát mép trên).
    // ───────────────────────────────────────────────────────────────────────
    private func bestShift(prev: [[Float]], next: [[Float]], height h: Int) -> Int {
        // Trả -1 ở các trường hợp KHÔNG dò được → add() sẽ bỏ frame (an toàn,
        // không ghi đè bậy) thay vì hiểu nhầm thành "đứng yên" (d=0).
        guard prev.count == h, next.count == h else { return -1 }

        // Dải mẫu: bắt đầu ở ~20% và cao ~18% chiều cao (bỏ qua header dính trên).
        let (bandTop, bandH) = bandGeometry(h)
        guard bandTop + bandH < h else { return -1 }

        // d tối đa dò được = khoảng trống còn lại bên dưới dải.
        let maxD = h - bandTop - bandH
        guard maxD >= 1 else { return -1 }

        var bestD = 0
        var bestCost = Float.greatestFiniteMagnitude
        for d in 0 ... maxD {
            var cost: Float = 0
            // So band của next với cùng dải nhưng dịch xuống d hàng trong prev.
            for i in 0 ..< bandH {
                cost += rowDistance(next[bandTop + i], prev[bandTop + d + i])
            }
            cost /= Float(bandH)
            if cost < bestCost { bestCost = cost; bestD = d }
        }

        // Khớp tốt nhất vẫn quá khác (cuộn quá nhanh / nội dung đổi hẳn) → -1 = bỏ.
        let acceptThreshold: Float = 12
        if bestCost > acceptThreshold { return -1 }
        return bestD
    }

    // Khoảng cách giữa 2 chữ ký hàng = trung bình |hiệu| từng mẫu.
    private func rowDistance(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for k in 0 ..< samples { sum += abs(a[k] - b[k]) }
        return sum / Float(samples)
    }

    // ── Giải mã CGImage → (mảng pixel RGBA, chữ ký từng hàng) ──────────────
    private func decode(_ cg: CGImage) -> (pixels: [UInt8], sig: [[Float]])? {
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = pixels.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(data: buf.baseAddress, width: width, height: h,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: cs, bitmapInfo: info)
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: h))

        // Chữ ký: chia mỗi hàng thành 16 ô, lấy độ sáng trung bình mỗi ô.
        var sig = [[Float]](repeating: [Float](repeating: 0, count: samples), count: h)
        let bucket = max(width / samples, 1)
        for y in 0 ..< h {
            let rowBase = y * bytesPerRow
            for s in 0 ..< samples {
                let x0 = s * bucket
                let x1 = min(x0 + bucket, width)
                guard x1 > x0 else { continue }
                var acc: Float = 0
                for x in x0 ..< x1 {
                    let p = rowBase + x * 4
                    // Độ sáng ~ trung bình R,G,B (đủ để khớp bố cục).
                    acc += Float(pixels[p]) + Float(pixels[p + 1]) + Float(pixels[p + 2])
                }
                sig[y][s] = acc / Float((x1 - x0) * 3)
            }
        }
        return (pixels, sig)
    }
}
