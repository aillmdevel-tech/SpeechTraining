import Foundation

struct TurnBoundary: Equatable {
    let spoken: String
    let opening: String
}

struct LiveTurns {
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?…]+[»”"'’)\]]*(?=\s|$)"#)
    private var consumed = 0
    private(set) var current = ""
    private(set) var alreadyChecked: TurnBoundary?

    mutating func update(_ text: String) {
        current = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var draft: String { parts.dropFirst(consumed).joined(separator: " ") }

    var candidate: TurnBoundary? {
        let remaining = Array(parts.dropFirst(consumed))
        guard remaining.count >= 2 else { return nil }
        for index in 1..<remaining.count {
            let spoken = remaining[..<index].joined(separator: " ")
            let opening = remaining[index...].joined(separator: " ")
            if spoken.split(whereSeparator: \.isWhitespace).count >= 4,
               opening.split(whereSeparator: \.isWhitespace).count >= 4 {
                return TurnBoundary(spoken: spoken, opening: opening)
            }
        }
        return nil
    }

    mutating func checked(_ boundary: TurnBoundary) {
        alreadyChecked = boundary
    }

    mutating func split(at boundary: TurnBoundary) -> String? {
        guard candidate?.spoken == boundary.spoken else { return nil }
        consumed += Self.sentences(boundary.spoken).count
        alreadyChecked = nil
        return boundary.spoken
    }

    mutating func finish(_ text: String) -> String {
        update(text)
        let final = draft
        self = LiveTurns()
        return final
    }

    private var parts: [String] { Self.sentences(current) }

    private static func sentences(_ text: String) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        for match in sentenceEnd.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let boundary = Range(match.range, in: text)?.upperBound else { continue }
            pieces.append(String(text[start..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = boundary
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}

struct LiveChatItem: Identifiable, Codable {
    var id = UUID()
    let text: String
    var segments: [Segment] = []
    let mode: TrainerMode
}
