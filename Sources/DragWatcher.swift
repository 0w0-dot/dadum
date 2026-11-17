import AppKit

/// 다른 앱에서 글을 드래그(또는 두 번 · 세 번 클릭)해 고르는 순간을 알아챈다.
final class DragWatcher {
    /// 글을 골랐다. 두 번째 값은 마우스를 뗀 곳.
    var onSelect: ((Selection, NSPoint) -> Void)?
    /// 다른 곳을 눌렀다.
    var onClick: (() -> Void)?
    /// 글을 치거나 화면을 굴렸다.
    var onTypeOrScroll: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    private var dragged = false
    private var readTask: Task<Void, Never>?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        selectionLog.notice("감시 시작")
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let other: NSEvent.EventTypeMask = [.keyDown, .scrollWheel]
        for mask in [mouse, other] {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }) {
                monitors.append(monitor)
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        readTask?.cancel()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            readTask?.cancel()
            downPoint = NSEvent.mouseLocation
            dragged = false
            onClick?()
        case .leftMouseDragged:
            let now = NSEvent.mouseLocation
            if hypot(now.x - downPoint.x, now.y - downPoint.y) > 5 { dragged = true }
        case .leftMouseUp:
            guard dragged || event.clickCount >= 2 else { return }
            selectionLog.info("드래그 끝(끌기 \(self.dragged, privacy: .public), 클릭 \(event.clickCount, privacy: .public)번)")
            readSelection(at: [downPoint, NSEvent.mouseLocation])
        case .keyDown:
            // 고친 글을 넣으려고 우리가 누른 ⌘C · ⌘V는 무시한다.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SelectionReader.syntheticMarker { return }
            if event.keyCode == 53 {
                onEscape?()
                return
            }
            onTypeOrScroll?()
            // ⌘A(전체 선택)도 글을 고른 것으로 본다. 키 번호 0은 자판의 A 자리라 한글 입력 중에도 같다.
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 0, modifiers == .command {
                selectionLog.info("⌘A")
                readSelection(at: [])
            }
        case .scrollWheel:
            onTypeOrScroll?()
        default:
            break
        }
    }

    private func readSelection(at points: [NSPoint]) {
        readTask?.cancel()
        readTask = Task {
            // 앱이 선택을 다 그릴 때까지 아주 잠깐 기다린다.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let selection = await SelectionReader.read(from: app, at: points),
                  !Task.isCancelled
            else { return }
            // 마우스로 골랐으면 손을 뗀 곳, 키보드로 골랐으면 고른 글의 끝에 버튼을 띄운다.
            onSelect?(selection, points.last ?? selection.end ?? NSEvent.mouseLocation)
        }
    }
}
