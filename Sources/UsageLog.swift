import Foundation

/// 이번 달 쓴 토큰과 비용. 글 내용은 남기지 않고 횟수와 숫자만 이 맥에 남긴다.
enum UsageLog {
    struct Month: Codable {
        var calls = 0
        var inputTokens = 0
        var outputTokens = 0
        var dollars = 0.0
    }

    /// 1달러당 원. FRED 2026-10-30 값(1,333.99)을 어림했다. 실제 청구는 달러로 된다.
    static let wonPerDollar = 1334.0

    private static let key = "usageByMonth"

    static func record(_ report: ClaudeClient.Report) {
        var all = load()
        let month = monthKey(Date())
        var entry = all[month] ?? Month()
        let price = price(for: report.model)
        entry.calls += 1
        entry.inputTokens += report.inputTokens
        entry.outputTokens += report.outputTokens
        let inputCost = Double(report.inputTokens) * price.input
        let outputCost = Double(report.outputTokens) * price.output
        entry.dollars += (inputCost + outputCost) / 1_000_000
        all[month] = entry
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 메뉴에 보이는 한 줄. 예: "이번 달 $0.84 · 약 1,120원"
    static var summary: String {
        let month = load()[monthKey(Date())] ?? Month()
        let won = Int((month.dollars * wonPerDollar / 10).rounded()) * 10
        return "이번 달 \(String(format: "$%.2f", month.dollars)) · 약 \(won.formatted())원"
    }

    /// 100만 토큰당 달러(Anthropic 가격표, 2026-11-03 기준). 모르는 모델은 비싼 쪽으로 넉넉히 센다.
    private static func price(for model: String) -> (input: Double, output: Double) {
        if model.hasPrefix("claude-haiku-5-5") { return (0.10, 0.50) }
        if model.hasPrefix("claude-opus-5-5") { return (4, 20) }
        if model.hasPrefix("claude-sonnet-5") { return (2, 10) }
        return (5, 25)
    }

    private static func load() -> [String: Month] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Month].self, from: data)
        else { return [:] }
        return all
    }

    private static func monthKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// 마지막에 고른 번역 언어와 말투. [번역]을 누르면 이것으로 바로 번역한다.
enum LastTranslation {
    private static let languageKey = "lastTranslationLanguage"
    private static let toneKey = "lastTranslationTone"

    static func remember(_ language: Language, _ tone: Tone) {
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        UserDefaults.standard.set(tone.rawValue, forKey: toneKey)
    }

    /// 이 글에 쓸 마지막 선택. 그 언어가 목록에 없으면(예: 영어 글인데 마지막이 영어) 목록 맨 위 언어에 같은 말투.
    static func choice(for targets: [Language]) -> (Language, Tone)? {
        guard let tone = UserDefaults.standard.string(forKey: toneKey).flatMap(Tone.init(rawValue:)) else { return nil }
        let last = UserDefaults.standard.string(forKey: languageKey).flatMap(Language.init(rawValue:))
        guard let language = last.flatMap({ targets.contains($0) ? $0 : nil }) ?? targets.first else { return nil }
        return (language, tone)
    }
}
