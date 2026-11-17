import AppKit
import ApplicationServices
import os

let selectionLog = Logger(subsystem: "io.github.0w0-dot.dadum", category: "selection")

/// 다른 앱에서 고른 글.
struct Selection {
    let text: String
    /// 그 자리에 고친 글을 넣을 수 있는지(입력칸인지).
    let editable: Bool
    let app: NSRunningApplication
    /// 고른 글의 끝(오른쪽 아래) 화면 위치. 키보드로 골랐을 때 버튼을 여기에 띄운다.
    var end: NSPoint?
}

/// 맨 앞 앱에서 고른 글을 읽고, 고친 글을 그 자리에 넣는다.
enum SelectionReader {
    /// 우리가 보낸 키 입력에 붙이는 표시. 키 입력 감시에서 이 표시가 있으면 건너뛴다.
    static let syntheticMarker: Int64 = 0xDAD0

    /// - Parameter points: 드래그를 시작한 곳과 마우스를 뗀 곳(화면 좌표, 왼쪽 아래가 원점).
    ///   키보드(⌘A)로 골랐으면 비워 둔다.
    static func read(from app: NSRunningApplication, at points: [NSPoint]) async -> Selection? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let appID = app.bundleIdentifier ?? "?"

        // 1. 손쉬운 사용 정보로 읽는다. 클립보드를 건드리지 않는다.
        //    드래그는 칸 밖에서 끝나기 쉬워서, 시작한 곳이나 뗀 곳 중 하나만 칸 안이면 된다.
        if let focused = element(appElement, kAXFocusedUIElementAttribute) {
            if points.isEmpty || points.contains(where: { contains(focused, $0) }) {
                let text: String? = value(focused, kAXSelectedTextAttribute)
                if let text, !text.isBlank {
                    selectionLog.info("\(appID, privacy: .public): 손쉬운 사용으로 \(text.count)자")
                    return Selection(text: text, editable: isEditable(focused), app: app, end: selectionEnd(focused))
                }
                selectionLog.info("\(appID, privacy: .public): 고른 글 없음(\(text == nil ? "읽기 실패" : "빈 글", privacy: .public))")
            } else {
                selectionLog.info("\(appID, privacy: .public): 마우스가 입력 중인 칸 밖")
            }
        } else {
            selectionLog.info("\(appID, privacy: .public): 초점 칸을 못 읽음")
        }

        // 2. 크롬 · 일렉트론 앱은 고른 글을 알려 주지 않는 때가 많아서 복사해서 읽는다.
        //    다른 앱에서는 복사가 글 대신 그림 · 파일을 옮길 수 있어서 하지 않는다.
        guard isWebEngine(app), !isCanvasPage(appElement),
              let text = await copySelection(), !text.isBlank
        else { return nil }
        selectionLog.info("\(appID, privacy: .public): 복사로 \(text.count)자")
        return Selection(text: text, editable: pasteEnabled(appElement) ?? true, app: app)
    }

    /// 고른 글이 차지한 사각형의 오른쪽 아래. 못 구하면 그 칸의 왼쪽 아래.
    private static func selectionEnd(_ element: AXUIElement) -> NSPoint? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var rect = CGRect.null
        if let range: AXValue = value(element, kAXSelectedTextRangeAttribute) {
            var bounds: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds
            ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
            }
        }
        if !rect.isNull, rect.width > 0 || rect.height > 0 {
            // 손쉬운 사용 좌표는 맨 위 왼쪽이 원점이라 뒤집는다.
            return NSPoint(x: rect.maxX, y: primaryHeight - rect.maxY)
        }
        guard let positionValue: AXValue = value(element, kAXPositionAttribute),
              let sizeValue: AXValue = value(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return NSPoint(x: origin.x, y: primaryHeight - origin.y - size.height)
    }

    /// 드래그가 글 고르기가 아니라 칸 · 도형 고르기인 웹 앱. 여기서 복사하면 복사 표시가 남는다.
    private static let canvasPageTitles = ["Google Sheets", "Google 스프레드시트", "Figma", "Miro", "Canva"]

    private static func isCanvasPage(_ appElement: AXUIElement) -> Bool {
        guard let window = element(appElement, kAXFocusedWindowAttribute),
              let title: String = value(window, kAXTitleAttribute)
        else { return false }
        return canvasPageTitles.contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// 고른 글 자리에 붙여 넣는다. 원래 클립보드는 돌려놓는다.
    static func replace(with text: String, in app: NSRunningApplication) async {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // 클립보드 기록 앱이 이 잠깐의 내용을 남기지 않게 한다.
        item.setData(Data(), forType: .transient)
        pasteboard.writeObjects([item])

        app.activate()
        try? await Task.sleep(for: .milliseconds(60))
        pressKey(9) // V
        try? await Task.sleep(for: .milliseconds(500))
        saved.restore(to: pasteboard)
    }

    // MARK: - 손쉬운 사용

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// 창을 끌거나 다른 곳을 눌렀을 때 예전 선택이 잡히지 않게, 마우스가 그 칸 안에 있었는지 본다.
    private static func contains(_ element: AXUIElement, _ point: NSPoint) -> Bool {
        guard let positionValue: AXValue = value(element, kAXPositionAttribute),
              let sizeValue: AXValue = value(element, kAXSizeAttribute)
        else { return true }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        // 손쉬운 사용 좌표는 맨 위 왼쪽이 원점이다.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: point.x, y: primaryHeight - point.y)
        return CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4).contains(flipped)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        let role: String? = value(element, kAXRoleAttribute)
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
    }

    /// 편집 메뉴의 붙여넣기(⌘V)가 켜져 있으면 입력칸에 있다고 본다. 찾지 못하면 nil.
    private static func pasteEnabled(_ appElement: AXUIElement) -> Bool? {
        guard let menuBar = element(appElement, kAXMenuBarAttribute),
              let menus: [AXUIElement] = value(menuBar, kAXChildrenAttribute)
        else { return nil }
        for menu in menus.prefix(6) {
            guard let submenus: [AXUIElement] = value(menu, kAXChildrenAttribute),
                  let submenu = submenus.first,
                  let items: [AXUIElement] = value(submenu, kAXChildrenAttribute)
            else { continue }
            for item in items {
                let key: String? = value(item, kAXMenuItemCmdCharAttribute)
                let modifiers: Int? = value(item, kAXMenuItemCmdModifiersAttribute)
                if key == "V", modifiers == 0 {
                    return value(item, kAXEnabledAttribute) ?? true
                }
            }
        }
        return nil
    }

    // MARK: - 복사로 읽기

    private static let webEngineCache = WebEngineCache()

    /// 크롬 계열(Chrome, Aside, ego lite)과 일렉트론 앱(Slack, Discord)은 안에 "~ Framework.framework"가 있다.
    private static func isWebEngine(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = webEngineCache.value[url] { return known }
        let frameworks = url.appending(path: "Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let result = names.contains { $0.hasSuffix(" Framework.framework") }
        webEngineCache.value[url] = result
        return result
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        pressKey(8) // C
        for _ in 0..<15 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else { return nil }
        let hasFiles = pasteboard.types?.contains(.fileURL) ?? false
        let text = pasteboard.string(forType: .string)
        saved.restore(to: pasteboard)
        return hasFiles ? nil : text
    }

    /// ⌘ + 키를 누른다. 키 번호는 자판 위치(8 = C, 9 = V)라 한글 입력 중에도 같다.
    private static func pressKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

private final class WebEngineCache {
    var value: [URL: Bool] = [:]
}

/// 클립보드 내용을 잠깐 맡아 두었다가 돌려놓는다.
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
    }
}

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org 약속: 잠깐 쓰는 내용이라 기록하지 말라는 표시.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
