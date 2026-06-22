import ApplicationServices
import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Đọc vị trí cuộn THẬT của vùng đang chụp qua Accessibility (AX) API.
//
// Ý tưởng (như CleanShot): thay vì đoán độ trượt bằng so ảnh, ta hỏi thẳng hệ
// thống "thanh cuộn dọc dưới con trỏ đang ở đâu" (giá trị 0…1). Biết offset thật
// thì ghép chính xác tuyệt đối — không "tooFast", không lệch, biết chắc khi hết
// trang (value ≈ 1).
//
// Cần quyền Accessibility (app đã có sẵn để autoscroll/CGEvent).
//
// Lưu ý: vài app bật AX "lười" (Chrome chỉ bật cây accessibility khi có trợ lý
// hỏi tới) → lần hỏi đầu có thể chưa ra; nên gọi vài nhịp rồi mới kết luận.
// ─────────────────────────────────────────────────────────────────────────
final class ScrollAreaTracker {
    private var scrollArea: AXUIElement?
    private var vbar: AXUIElement?

    var isAttached: Bool { vbar != nil }

    // Quên scroll area cũ (gọi khi kết thúc 1 phiên chụp).
    func reset() {
        scrollArea = nil
        vbar = nil
    }

    // Gắn vào scroll area tại điểm `p` (toạ độ toàn cục, gốc TRÊN-trái màn chính
    // — cùng hệ với CGEvent). Trả về true nếu tìm được thanh cuộn dọc đọc được.
    @discardableResult
    func attach(atGlobalTopLeft p: CGPoint) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success,
              let start = el else { return false }

        // Đi NGƯỢC lên cha tới khi gặp 1 AXScrollArea (vùng cuộn).
        var cur: AXUIElement? = start
        var hops = 0
        while let c = cur, hops < 30 {
            if role(of: c) == (kAXScrollAreaRole as String) {
                scrollArea = c
                break
            }
            cur = parent(of: c)
            hops += 1
        }
        guard let sa = scrollArea else { return false }

        // Thanh cuộn dọc của scroll area đó.
        if let vb = element(sa, attr: kAXVerticalScrollBarAttribute as String) {
            vbar = vb
            return value() != nil          // đọc thử 1 phát cho chắc
        }
        return false
    }

    // Giá trị cuộn dọc hiện tại trong [0,1] (nil nếu không đọc được / không có).
    func value() -> CGFloat? {
        guard let vb = vbar else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(vb, kAXValueAttribute as CFString, &v) == .success,
              let num = v as? NSNumber else { return nil }
        let d = num.doubleValue
        return d.isFinite ? CGFloat(d) : nil
    }

    // ── AX helpers ─────────────────────────────────────────────────────────
    private func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success
        else { return nil }
        return v as? String
    }

    private func parent(of el: AXUIElement) -> AXUIElement? {
        element(el, attr: kAXParentAttribute as String)
    }

    private func element(_ el: AXUIElement, attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }
}
