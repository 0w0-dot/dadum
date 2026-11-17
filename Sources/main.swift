import AppKit

// 점검용: Dadum --check "글" [모델]                      맞춤법
//         Dadum --translate "글" [언어] [말투] [모델]     번역(언어: 영어 · 일본어 · 중국어 · 한국어, 말투: 일상 · 업무 · 정석)
// 앱과 같은 서명이라 키체인의 API 키를 묻지 않고 꺼내 쓴다. 결과와 걸린 시간, 토큰 수를 찍는다.
let arguments = CommandLine.arguments
if arguments.count >= 3, ["--check", "--translate"].contains(arguments[1]) {
    let text = arguments[2]
    guard let key = KeyStore.load() else {
        print("API 키가 없어요")
        exit(1)
    }
    var client = ClaudeClient(apiKey: key)
    let translating = arguments[1] == "--translate"
    let extra = Array(arguments.dropFirst(3))
    let target = Language.allCases.first { $0.label == extra.first } ?? Language.translationTargets(for: text)[0]
    let tone = Tone.allCases.first { extra.count > 1 && $0.label == extra[1] } ?? .standard
    let modelIndex = translating ? 2 : 0
    if extra.count > modelIndex { client.modelOverride = extra[modelIndex] }
    Task {
        let start = Date()
        do {
            let result: String
            let report: ClaudeClient.Report
            var back: String?
            if translating {
                let (translation, translationReport) = try await client.translate(text, to: target, tone: tone)
                (result, report, back) = (translation.text, translationReport, translation.back)
            } else {
                (result, report) = try await client.correct(text)
            }
            // 점검도 실제로 돈이 드니 이번 달 비용에 함께 센다.
            UsageLog.record(report)
            print("모델: \(report.model)  시간: \(String(format: "%.1f", Date().timeIntervalSince(start)))초  토큰: 입력 \(report.inputTokens) / 출력 \(report.outputTokens)")
            print("\(translating ? "\(target.label) · \(tone.label)" : "맞춤법"): \(result)")
            if let back { print("되옮김: \(back)") }
            print(UsageLog.summary)
            exit(0)
        } catch let error as PolishError {
            print("오류: \(error.message) (\(error))")
            exit(1)
        } catch {
            print("오류: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

// 메뉴 막대에만 사는 앱이다. Dock에는 나오지 않는다(Info.plist의 LSUIElement).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
