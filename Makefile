# Giống "scripts" trong package.json. Chạy: make run
APP     = SlopShot
CONFIG  = Debug
BUILD   = build
# cert self-signed cố định -> quyền macOS không bị reset mỗi lần build
SIGN_ID = SlopShot Dev
APP_PATH = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: gen build run clean install

gen:                 # sinh SlopShot.xcodeproj từ project.yml
	xcodegen generate

build: gen           # build app rồi ký lại bằng cert cố định
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) \
		-configuration $(CONFIG) -derivedDataPath $(BUILD) build
	codesign --force --deep --sign "$(SIGN_ID)" "$(APP_PATH)"
	@echo "Đã ký bằng: $(SIGN_ID)"

run: build           # build xong mở app luôn
	open "$(APP_PATH)"

# Cài "production" vào /Applications: build bản Release (tối ưu) rồi copy + ký.
# CONFIG=Release chỉ áp riêng cho lệnh này (target-specific), nên APP_PATH trỏ đúng Release.
install: CONFIG = Release
install: build
	@echo "→ Đóng SlopShot đang chạy (nếu có)…"
	-osascript -e 'quit app "SlopShot"' >/dev/null 2>&1 || true
	rm -rf "/Applications/$(APP).app"
	cp -R "$(APP_PATH)" "/Applications/$(APP).app"
	codesign --force --deep --sign "$(SIGN_ID)" "/Applications/$(APP).app"
	@echo "✅ Đã cài: /Applications/$(APP).app  (mở: open -a $(APP))"
	@echo "   Lần đầu nhớ cấp lại Screen Recording + Accessibility cho bản trong /Applications."

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
