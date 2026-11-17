import AppKit
import SwiftUI

/// 글을 고른 곳 옆에 뜨는 [맞춤법 | 번역] 버튼. 눌러도 지금 쓰던 앱의 선택과 초점이 그대로 남는다.
/// [번역]에 마우스를 올리면 언어 → 말투(일상 · 업무 · 정석) 메뉴가 열리고, 누르면 마지막에 고른 것으로 바로 번역한다.
final class FloatingButton: NSObject {
    static let height: CGFloat = 30
    fileprivate static let margin: CGFloat = 8 // 그림자가 잘리지 않게 둘레에 둔 여백

    var onPress: ((Mode) -> Void)?
    private let panel: FloatingPanel
    private let host: FirstClickHostingView
    private let tracker = HoverTracker()
    private var targets: [Language] = []
    private var translateFrame = CGRect.zero
    private var hoverTask: Task<Void, Never>?
    private var menuOpen = false

    override init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: Self.height + Self.margin * 2))
        panel.acceptsMouseMovedEvents = true
        host = FirstClickHostingView(rootView: AnyView(EmptyView()))
        super.init()
        panel.contentView = host
        // 이 앱은 앞에 나서지 않아서, 앱이 뒤에 있어도 마우스 움직임을 받는 감지판을 따로 깐다.
        tracker.frame = host.bounds
        tracker.autoresizingMask = [.width, .height]
        tracker.onMove = { [weak self] point in self?.mouseMoved(to: point) }
        host.addSubview(tracker)
    }

    var isVisible: Bool { panel.isVisible }

    /// 버튼 묶음의 화면 위치.
    var buttonFrame: NSRect { panel.frame.insetBy(dx: Self.margin, dy: Self.margin) }

    /// 마우스를 뗀 곳(또는 고른 글의 끝)의 오른쪽 아래에 띄운다.
    func show(near point: NSPoint, targets: [Language]) {
        self.targets = targets
        hoverTask?.cancel()
        // 새로 그려야 나타나는 움직임이 처음부터 다시 돈다.
        host.rootView = AnyView(FloatingButtonView(
            spelling: { [weak self] in self?.onPress?(.spelling) },
            translation: { [weak self] in self?.translateWithLastChoice() },
            translationFrame: { [weak self] frame in self?.translateFrame = frame }
        ).id(UUID()))
        let size = host.fittingSize
        var origin = NSPoint(x: point.x + 6 - Self.margin, y: point.y - 10 - Self.height - Self.margin)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        hoverTask?.cancel()
        panel.orderOut(nil)
    }

    // MARK: - 번역 메뉴

    /// 번역 칸 위에 잠깐 머물면 메뉴를 연다. 지나가기만 하면 열지 않는다.
    private func mouseMoved(to point: NSPoint) {
        guard translateFrame.contains(point) else {
            hoverTask?.cancel()
            hoverTask = nil
            return
        }
        guard hoverTask == nil, !menuOpen else { return }
        hoverTask = Task {
            // 누르려고 지나가는 동안 열리면 클릭이 메뉴를 닫는 데 쓰여서, 잠깐 머물 때만 연다.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            hoverTask = nil
            openTranslationMenu()
        }
    }

    /// 마지막에 고른 언어 · 말투로 바로 번역한다. 처음이라 고른 적이 없으면 메뉴를 연다.
    private func translateWithLastChoice() {
        guard let (language, tone) = LastTranslation.choice(for: targets) else {
            openTranslationMenu()
            return
        }
        translate(language, tone)
    }

    private func translate(_ language: Language, _ tone: Tone) {
        hoverTask?.cancel()
        LastTranslation.remember(language, tone)
        onPress?(.translation(language, tone))
    }

    func openTranslationMenu() {
        hoverTask?.cancel()
        hoverTask = nil
        guard !menuOpen, panel.isVisible, !targets.isEmpty else { return }
        let last = LastTranslation.choice(for: targets)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, language) in targets.enumerated() {
            // 한국어 글의 "한국어"는 번역이 아니라 말투 다듬기라 줄을 그어 나눈다.
            if language == .korean, index > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: language.label, action: nil, keyEquivalent: "")
            // 체크 표시는 [번역]을 누르면 쓰이는 마지막 선택.
            item.state = last?.0 == language ? .on : .off
            let tones = NSMenu()
            for tone in Tone.allCases {
                let toneItem = NSMenuItem(title: tone.label, action: #selector(chooseTranslation(_:)), keyEquivalent: "")
                toneItem.target = self
                toneItem.representedObject = [language.rawValue, tone.rawValue]
                toneItem.state = last?.0 == language && last?.1 == tone ? .on : .off
                tones.addItem(toneItem)
            }
            item.submenu = tones
            menu.addItem(item)
        }
        menuOpen = true
        chosenFromMenu = false
        // 번역 칸 바로 아래, 왼쪽 끝을 맞춰 연다. 이 화면은 위가 원점이라 maxY가 아래쪽이다.
        menu.popUp(positioning: nil, at: NSPoint(x: translateFrame.minX, y: translateFrame.maxY + 4), in: host)
        menuOpen = false
        // 메뉴가 열린 채로 [번역]을 누르면 그 클릭은 메뉴를 닫는 데 쓰인다. 그래도 누른 것으로 친다.
        if !chosenFromMenu, NSEvent.pressedMouseButtons & 1 != 0, translateFrame.contains(mouseInHost()) {
            translateWithLastChoice()
        }
    }

    private var chosenFromMenu = false

    private func mouseInHost() -> NSPoint {
        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return host.convert(inWindow, from: nil)
    }

    @objc private func chooseTranslation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? [String], raw.count == 2,
              let language = Language(rawValue: raw[0]),
              let tone = Tone(rawValue: raw[1])
        else { return }
        chosenFromMenu = true
        translate(language, tone)
    }
}

/// 클릭은 그대로 아래로 넘기고, 마우스 위치만 알려 주는 투명한 판.
private final class HoverTracker: NSView {
    var onMove: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onMove?(NSPoint(x: -1, y: -1)) }

    private func report(_ event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }
}

private struct FloatingButtonView: View {
    let spelling: () -> Void
    let translation: () -> Void
    let translationFrame: (CGRect) -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            segment(action: spelling) {
                Text("맞춤법")
            }
            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(width: 0.5, height: 14)
            // 아래 화살표는 더 고를 것(언어 · 말투)이 있다는 표시.
            segment(action: translation) {
                HStack(spacing: 3) {
                    Text("번역")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { translationFrame($0) }
        }
        .frame(height: FloatingButton.height)
        .background(.regularMaterial, in: Capsule())
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .fixedSize()
        .padding(FloatingButton.margin)
        // 하루에 수십 번 뜨므로 거의 느껴지지 않을 만큼만 움직인다.
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .topLeading)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)) { shown = true }
        }
    }

    private func segment<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.pretendard(12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(SegmentStyle())
    }
}

/// 누르는 동안 그 칸만 살짝 어두워져 눌렸다는 것을 알린다.
private struct SegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0))
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: configuration.isPressed)
    }
}

/// 다른 앱 위에 떠 있지만 그 앱을 밀어내지 않는 창.
final class FloatingPanel: NSPanel {
    /// 글자를 쳐야 할 때(API 키 넣기)만 true로 바꾼다.
    var acceptsKeyboard = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// 앞에 있지 않은 창이어도 첫 클릭부터 버튼이 눌리게 한다.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
