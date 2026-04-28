import Foundation

enum LLMProvider: String, CaseIterable, Identifiable {
    case openAICompatible = "GPT / OpenAI Compatible"
    case anthropic = "Claude / Anthropic"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible:
            "https://api.openai.com/v1"
        case .anthropic:
            "https://api.anthropic.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible:
            "gpt-4.1-mini"
        case .anthropic:
            "claude-3-5-sonnet-latest"
        }
    }
}

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

struct ImageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let data: Data
    let mediaType: String

    init(id: UUID = UUID(), data: Data, mediaType: String) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    var content: String
    var attachments: [ImageAttachment]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        attachments: [ImageAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

struct LLMConfiguration: Equatable {
    var provider: LLMProvider
    var apiKey: String
    var baseURL: String
    var model: String
    var maxTokens: Int
    var systemPrompt: String

    var isReady: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && maxTokens > 0
    }
}
