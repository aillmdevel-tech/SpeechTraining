import Foundation

struct AnswerChoice: Codable, Equatable {
    let language: ReplyLanguage
    let length: ReplyLength
}

struct AnswerVariant: Codable {
    let choice: AnswerChoice
    let question: Segment
    let segments: [Segment]
}

struct QuestionTurn: Identifiable, Codable {
    var id = UUID()
    let mode: TrainerMode
    var variants: [AnswerVariant]
    var displayed: AnswerChoice

    var answer: AnswerVariant? {
        variants.first(where: { $0.choice == displayed }) ?? variants.last
    }
}

struct QuestionThread: Identifiable, Codable {
    let id: UUID
    var turns: [QuestionTurn]

    var title: String { turns.first?.variants.first?.question.text ?? "Новый вопрос" }
}

struct ThreadHistory: Codable {
    var threads: [QuestionThread] = []
    var activeID: UUID?
}

struct ThreadItem: Decodable {
    let question: Segment
    let segments: [Segment]
}

struct ThreadReply: Decodable {
    let items: [ThreadItem]
    let incomplete: Bool
}

struct PriorReply: Encodable {
    let question: String
    let answer: String
}
