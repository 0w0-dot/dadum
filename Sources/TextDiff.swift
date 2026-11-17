import SwiftUI

/// 원문이 고친 글로 어떻게 바뀌었는지 낱말 단위로 늘어놓는다.
/// 띄어쓰기가 바뀐 곳도 낱말이 달라지므로 함께 잡힌다.
enum TextDiff {
    struct Piece: Equatable {
        enum Kind {
            case same
            case removed
            case added
        }

        let kind: Kind
        let text: String
    }

    static func pieces(from original: String, to corrected: String) -> [Piece] {
        let old = words(in: original)
        let new = words(in: corrected)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in new.map(\.word).difference(from: old.map(\.word)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }

        var pieces: [Piece] = []
        let leading = corrected.prefix { $0.isWhitespace }
        if !leading.isEmpty { pieces.append(Piece(kind: .same, text: String(leading))) }

        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                // 지운 낱말이 이어지면 한 덩어리로 긋는다.
                var run: [String] = []
                while i < old.count, removed.contains(i) {
                    run.append(old[i].word)
                    i += 1
                }
                pieces.append(Piece(kind: .removed, text: run.joined(separator: " ")))
                pieces.append(Piece(kind: .same, text: " "))
            } else if j < new.count, added.contains(j) {
                var run = ""
                while j < new.count, added.contains(j) {
                    run += new[j].word
                    if j + 1 < new.count, added.contains(j + 1) { run += new[j].trailing }
                    j += 1
                }
                pieces.append(Piece(kind: .added, text: run))
                pieces.append(Piece(kind: .same, text: new[j - 1].trailing))
            } else if i < old.count, j < new.count {
                pieces.append(Piece(kind: .same, text: new[j].word + new[j].trailing))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return merged(pieces)
    }

    /// 지운 낱말은 흐리게 긋고, 새 낱말은 강조 색 굵은 글씨로.
    static func rendered(_ pieces: [Piece]) -> AttributedString {
        var result = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .same:
                break
            case .removed:
                part.foregroundColor = Color.secondary
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = Color.accentColor
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result += part
        }
        return result
    }

    // MARK: -

    private static func words(in text: String) -> [(word: String, trailing: String)] {
        let ranges = text.ranges(of: #/\S+/#)
        return ranges.enumerated().map { index, range in
            let end = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
            return (String(text[range]), String(text[range.upperBound..<end]))
        }
    }

    /// 같은 종류가 이어진 조각을 합친다.
    private static func merged(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces where !piece.text.isEmpty {
            if let last = result.last, last.kind == piece.kind {
                result[result.count - 1] = Piece(kind: piece.kind, text: last.text + piece.text)
            } else {
                result.append(piece)
            }
        }
        return result
    }
}

extension [TextDiff.Piece] {
    var hasChanges: Bool { contains { $0.kind != .same } }
}
