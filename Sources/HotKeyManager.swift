import Carbon   // API Carbon cũ nhưng chuẩn nhất để đăng ký phím tắt toàn cục
import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Hàm callback kiểu C mà Carbon gọi mỗi khi 1 hotkey được bấm.
// Phải là hàm top-level (không "capture" biến ngoài) vì nó là con trỏ hàm C.
// userData = con trỏ tới HotKeyManager mà ta truyền vào lúc cài handler.
// ─────────────────────────────────────────────────────────────────────────
private func hotKeyCallback(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else { return noErr }

    // Lấy ID của hotkey vừa được bấm.
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    // Đổi con trỏ thô trở lại thành object HotKeyManager rồi gọi đúng closure.
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handle(id: hotKeyID.id)
    return noErr
}

// ─────────────────────────────────────────────────────────────────────────
// Quản lý nhiều phím tắt toàn cục. Mỗi hotkey gắn 1 closure.
// ─────────────────────────────────────────────────────────────────────────
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]   // id -> việc cần làm
    private var refs: [UInt32: EventHotKeyRef] = [:]    // id -> tham chiếu để gỡ sau này
    private var installed = false
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x4D595348          // 'MYSH' — chữ ký riêng của app

    private init() {}

    /// Đăng ký 1 phím tắt. keyCode + modifiers theo bảng mã Carbon.
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            refs[id] = ref
        } else {
            // Thường gặp khi tổ hợp phím đã bị app khác chiếm.
            NSLog("SlopShot: failed to register hotkey (status=\(status)) — it may be taken by another app.")
        }
    }

    /// Gỡ toàn bộ phím tắt đang đăng ký (gọi trước khi đăng ký lại bộ mới).
    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        nextID = 1
    }

    // Cài 1 event handler dùng chung cho mọi hotkey (chỉ cài 1 lần).
    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, selfPtr, nil)
    }

    // Được callback gọi: tìm đúng closure theo id và chạy.
    fileprivate func handle(id: UInt32) {
        handlers[id]?()
    }
}
