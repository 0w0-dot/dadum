import AppKit
import SwiftUI

/// 버튼을 누르면 그 자리에서 열리는 결과 창. 누른 쪽(맞춤법 또는 번역) 하나만 보여 준다.
final class ResultPanel {
    static let width: CGFloat = 380
    static let margin: CGFloat = 18 // 그림자가 잘리지 않게 둘레에 둔 여백
    private static let maxHeight: CGFloat = 480

    private let panel: FloatingPanel
    private let model = ResultModel()
    private let host: FirstClickHostingView
    private var selection: Selection?
    private var mode = Mode.spelling
    private var task: Task<Void, Never>?
    private var anchor = NSRect.zero
    private var boxHeight: CGFloat = 0

    init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.margin * 2, height: 120))
        panel.isMovableByWindowBackground = true
        host = FirstClickHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host
        host.rootView = AnyView(ResultView(model: model, actions: ResultActions(
            replace: { [weak self] text in self?.replace(with: text) },
            copy: { [weak self] text in self?.copy(text) },
            retry: { [weak self] in self?.start() },
            saveKey: { [weak self] key in self?.saveKey(key) },
            close: { [weak self] in self?.close() },
            heightChanged: { [weak self] height in self?.fit(contentHeight: height) }
        )))
    }

    var isVisible: Bool { panel.isVisible }

    /// 고른 글을 검사하거나 번역한다. anchor는 방금 누른 버튼의 화면 위치.
    func show(for selection: Selection, mode: Mode, from anchor: NSRect) {
        self.selection = selection
        self.mode = mode
        open(at: anchor)
        start()
    }

    /// 메뉴에서 API 키를 넣을 때. 화면 가운데 위쪽에 연다.
    func showKeyForm() {
        selection = nil
        task?.cancel()
        let screen = NSScreen.main?.visibleFrame ?? .zero
        open(at: NSRect(x: screen.midX - Self.width / 2, y: screen.maxY - 160, width: 0, height: 0))
        askForKey(error: nil)
    }

    /// 다른 곳을 눌렀을 때. 키를 넣는 중이면 닫지 않는다(키를 복사하러 다른 창에 다녀와야 해서).
    func dismissForOutsideClick() {
        if case .needsKey = model.phase { return }
        close()
    }

    func close() {
        task?.cancel()
        panel.acceptsKeyboard = false
        panel.orderOut(nil)
    }

    // MARK: - 검사

    private func start() {
        guard let selection else { return }
        task?.cancel()
        guard let key = KeyStore.load() else {
            askForKey(error: nil)
            return
        }
        model.phase = .loading
        let text = selection.text
        let mode = mode
        task = Task {
            do {
                let client = ClaudeClient(apiKey: key)
                switch mode {
                case .spelling:
                    let (corrected, report) = try await client.correct(text)
                    UsageLog.record(report)
                    guard !Task.isCancelled else { return }
                    model.phase = .corrected(corrected, pieces: TextDiff.pieces(from: text, to: corrected))
                case .translation(let target, let tone):
                    let (translation, report) = try await client.translate(text, to: target, tone: tone)
                    UsageLog.record(report)
                    guard !Task.isCancelled else { return }
                    model.phase = .translated(translation.text, title: "\(target.label) · \(tone.label)", back: translation.back)
                }
            } catch let error as PolishError {
                guard !Task.isCancelled else { return }
                if case .badKey = error {
                    askForKey(error: error.message)
                } else {
                    model.phase = .failed(error)
                }
            } catch {
                guard !Task.isCancelled else { return }
                model.phase = .failed(.server(error.localizedDescription))
            }
        }
    }

    private func askForKey(error: String?) {
        model.phase = .needsKey(error: error)
        panel.acceptsKeyboard = true
        // 키를 치고 붙여 넣으려면 이 앱이 앞에 나와야 한다. 쓰던 앱의 선택은 그대로 남는다.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func saveKey(_ key: String) {
        guard KeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            model.phase = .needsKey(error: "키를 저장하지 못했어요")
            return
        }
        panel.acceptsKeyboard = false
        if selection != nil {
            // 키를 넣으면 하려던 검사가 바로 이어진다.
            start()
        } else {
            model.phase = .keySaved
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if case .keySaved = model.phase { close() }
            }
        }
    }

    private func replace(with text: String) {
        guard let selection else { return }
        close()
        Task { await SelectionReader.replace(with: text, in: selection.app) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            model.copied = false
        }
    }

    // MARK: - 자리와 크기

    private func open(at anchor: NSRect) {
        self.anchor = anchor
        let visible = screen(for: anchor).visibleFrame
        let spaceBelow = anchor.maxY - visible.minY
        let spaceAbove = visible.maxY - anchor.minY
        model.opensDownward = spaceBelow >= 320 || spaceBelow >= spaceAbove
        model.editable = selection?.editable ?? false
        model.copied = false
        model.showToken = UUID()
        panel.acceptsKeyboard = false
        boxHeight = 64
        panel.setFrame(frame(forBoxHeight: boxHeight), display: false)
        panel.orderFrontRegardless()
    }

    private func fit(contentHeight: CGFloat) {
        let visible = screen(for: anchor).visibleFrame
        let available = model.opensDownward ? anchor.maxY - visible.minY : visible.maxY - anchor.minY
        let height = min(contentHeight, Self.maxHeight, available - 8)
        guard abs(height - boxHeight) > 0.5 else { return }
        boxHeight = height
        let target = frame(forBoxHeight: height)
        guard panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// 버튼이 있던 자리에서 창이 자라나게 놓는다. 아래로 열면 위 끝을, 위로 열면 아래 끝을 버튼에 맞춘다.
    private func frame(forBoxHeight height: CGFloat) -> NSRect {
        let visible = screen(for: anchor).visibleFrame
        var x = anchor.minX
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let y = model.opensDownward ? anchor.maxY - height : anchor.minY
        return NSRect(x: x, y: y, width: Self.width, height: height).insetBy(dx: -Self.margin, dy: -Self.margin)
    }

    private func screen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - 상태

@Observable
final class ResultModel {
    enum Phase {
        case loading
        case corrected(String, pieces: [TextDiff.Piece])
        case translated(String, title: String, back: String?)
        case failed(PolishError)
        case needsKey(error: String?)
        case keySaved
    }

    var phase: Phase = .loading
    var editable = false
    var copied = false
    var opensDownward = true
    var showToken = UUID()
}

struct ResultActions {
    var replace: (String) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    var retry: () -> Void = {}
    var saveKey: (String) -> Void = { _ in }
    var close: () -> Void = {}
    var heightChanged: (CGFloat) -> Void = { _ in }
}

// MARK: - 화면

struct ResultView: View {
    let model: ResultModel
    let actions: ResultActions

    var body: some View {
        // 열 때마다 새로 그려야 나타나는 움직임이 처음부터 다시 돈다.
        ResultBox(model: model, actions: actions).id(model.showToken)
    }
}

private struct ResultBox: View {
    let model: ResultModel
    let actions: ResultActions
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            content
                .padding(16)
                .frame(width: ResultPanel.width, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actions.heightChanged($0) }
        }
        .scrollIndicators(.never)
        .frame(width: ResultPanel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectBackground())
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(ResultPanel.margin)
        // 버튼이 있던 모서리에서 자라나듯 연다. 줄인 움직임 설정이면 흐려지기만 한다.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97, anchor: model.opensDownward ? .topLeading : .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { appeared = true }
        }
        .onExitCommand(perform: actions.close)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 32)
        case .corrected(let corrected, let pieces):
            // 고칠 곳이 없으면 이미 화면에 있는 글을 다시 보여 주지 않고 상태만 알린다.
            if pieces.hasChanges {
                // 원래 글이 어떻게 바뀌는지 보인다. 바꾸기 · 복사는 고친 글만 쓴다.
                Section(title: "맞춤법", text: Text(TextDiff.rendered(pieces)), value: corrected, model: model, actions: actions)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            } else {
                SectionHeader(title: "맞춤법", status: "고칠 곳 없음")
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        case .translated(let translation, let title, let back):
            VStack(alignment: .leading, spacing: 10) {
                Section(title: title, text: Text(translation), value: translation, model: model, actions: actions)
                // 일본어 · 중국어는 직접 읽기 어려워서, 한국어로 되옮긴 뜻을 흐리게 곁에 둔다.
                if let back, !back.isBlank {
                    Text(back)
                        .font(.pretendard(13))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
        case .failed(let error):
            HStack(spacing: 12) {
                Text(error.message)
                    .font(.pretendard(14))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if error.canRetry {
                    Button("다시 하기", action: actions.retry)
                        .buttonStyle(SmallButtonStyle(prominent: false))
                }
            }
        case .needsKey(let error):
            KeyForm(error: error, save: actions.saveKey)
        case .keySaved:
            Text("저장됨")
                .font(.pretendard(14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
    }
}

private struct Section: View {
    let title: String
    let text: Text
    let value: String
    let model: ResultModel
    let actions: ResultActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, status: nil) {
                // 입력칸이 아니면 넣을 수 없으니 바꾸기를 보여 주지 않는다.
                if model.editable {
                    Button("바꾸기") { actions.replace(value) }
                        .buttonStyle(SmallButtonStyle(prominent: true))
                }
                Button { actions.copy(value) } label: {
                    // 글자 수가 달라도 버튼 너비가 흔들리지 않게 긴 쪽 자리를 잡아 둔다.
                    ZStack {
                        Text("복사됨").hidden()
                        Text(model.copied ? "복사됨" : "복사")
                    }
                }
                .buttonStyle(SmallButtonStyle(prominent: false))
            }
            text
                .font(.pretendard(14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    let status: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.pretendard(12, weight: .semibold))
                .foregroundStyle(.secondary)
            if let status {
                Text(status)
                    .font(.pretendard(12))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            trailing.controlSize(.small)
        }
        .frame(minHeight: 22)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, status: String?) {
        self.init(title: title, status: status) { EmptyView() }
    }
}

private struct KeyForm: View {
    let error: String?
    let save: (String) -> Void
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API 키")
                .font(.pretendard(12, weight: .semibold))
                .foregroundStyle(.secondary)
            SecureField("", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("API 키")
            if let error {
                Text(error)
                    .font(.pretendard(12))
                    .foregroundStyle(.red)
            }
            HStack {
                Link("키 만들기", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                    .font(.pretendard(12))
                Spacer()
                Button("저장", action: submit)
                    .buttonStyle(SmallButtonStyle(prominent: true))
                    .disabled(key.isBlank)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !key.isBlank else { return }
        save(key)
    }
}

/// 이 창은 앞에 나서지 않아서 기본 강조 버튼이 늘 회색으로 보인다. 그래서 색을 직접 칠한다.
private struct SmallButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pretendard(12, weight: .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.08)),
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// macOS 팝오버와 같은 반투명 바탕.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Font {
    /// 한글 글꼴은 Pretendard. 깔려 있지 않으면 시스템 글꼴로 보인다.
    static func pretendard(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Pretendard", size: size).weight(weight)
    }
}
