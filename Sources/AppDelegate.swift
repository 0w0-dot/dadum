import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let watchKey = "watchDrag"

    private var statusItem: NSStatusItem?
    private let watcher = DragWatcher()
    private let button = FloatingButton()
    private let panel = ResultPanel()
    private var pending: Selection?
    private var trustTask: Task<Void, Never>?

    /// 메뉴의 켜고 끄기 값. 실제로 도는지는 손쉬운 사용 권한도 있어야 한다.
    private var wantsWatching: Bool {
        get { UserDefaults.standard.bool(forKey: Self.watchKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.watchKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.watchKey: true])
        setUpEditMenu()
        setUpStatusItem()
        connect()
        registerLoginItemOnce()
        applyWatching(askIfNeeded: true)
    }

    // MARK: - 연결

    private func connect() {
        watcher.onSelect = { [weak self] selection, point in
            guard let self else { return }
            pending = selection
            panel.close()
            button.show(near: point, targets: Language.translationTargets(for: selection.text))
        }
        watcher.onClick = { [weak self] in
            self?.button.hide()
            self?.panel.dismissForOutsideClick()
        }
        watcher.onTypeOrScroll = { [weak self] in self?.button.hide() }
        watcher.onEscape = { [weak self] in
            self?.button.hide()
            self?.panel.close()
        }
        button.onPress = { [weak self] mode in
            guard let self, let selection = pending else { return }
            let anchor = button.buttonFrame
            button.hide()
            panel.show(for: selection, mode: mode, from: anchor)
        }
    }

    // MARK: - 손쉬운 사용 권한

    private func applyWatching(askIfNeeded: Bool) {
        guard wantsWatching else {
            watcher.stop()
            button.hide()
            return
        }
        if AXIsProcessTrusted() {
            watcher.start()
            return
        }
        selectionLog.notice("손쉬운 사용 권한을 기다리는 중")
        // 시스템 권한 창은 처음 한 번만 저절로 띄운다. 그 뒤로는 메뉴를 누를 때 띄운다.
        let askedKey = "askedAccessibility"
        if askIfNeeded, !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            promptForPermission()
        }
        waitForPermission()
    }

    private func promptForPermission() {
        // kAXTrustedCheckOptionPrompt의 값. 그 상수는 Swift 6에서 바로 쓸 수 없어서 글자로 적는다.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 권한이 켜지면 저절로 감시를 시작한다.
    private func waitForPermission() {
        guard trustTask == nil else { return }
        trustTask = Task {
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            trustTask = nil
            applyWatching(askIfNeeded: false)
        }
    }

    // MARK: - 로그인할 때 열기

    /// 처음 한 번만 로그인 항목에 넣는다. 사용자가 시스템 설정에서 빼면 다시 넣지 않는다.
    private func registerLoginItemOnce() {
        let key = "registeredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    // MARK: - 메뉴 막대

    /// 화면에 보이지 않는 편집 메뉴. 이게 있어야 API 키 칸에서 ⌘V · ⌘C · ⌘A가 먹는다.
    private func setUpEditMenu() {
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Dadum")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // 열 때마다 지금 상태로 다시 채운다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 상태 표시라 누를 수 없다. 글 내용은 남기지 않고 토큰 수로만 센다.
        let usage = NSMenuItem(title: UsageLog.summary, action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        menu.addItem(.separator())
        // 권한이 없으면 실제로 동작하지 않으니 꺼진 것으로 보여 준다.
        let watch = menuItem("드래그하면 버튼 띄우기", #selector(toggleWatching))
        watch.state = wantsWatching && AXIsProcessTrusted() ? .on : .off
        menu.addItem(watch)
        menu.addItem(menuItem("API 키…", #selector(editKey)))
        menu.addItem(.separator())
        menu.addItem(menuItem("종료", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // 권한이 없을 때 누르면 켜 두고 권한 설정 화면을 연다. 권한을 켜면 바로 동작한다.
    @objc private func toggleWatching() {
        guard AXIsProcessTrusted() else {
            wantsWatching = true
            promptForPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            waitForPermission()
            return
        }
        wantsWatching.toggle()
        applyWatching(askIfNeeded: false)
    }

    @objc private func editKey() {
        button.hide()
        panel.showKeyForm()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
