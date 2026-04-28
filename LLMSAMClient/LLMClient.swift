import Foundation

enum LLMClientError: LocalizedError {
    case invalidBaseURL
    case badResponse(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "地址前缀无效。"
        case .badResponse(let message):
            message
        case .emptyResponse:
            "模型没有返回内容。"
        }
    }
}

struct LLMClient {
    var configuration: LLMConfiguration

    func send(messages: [ChatMessage]) async throws -> String {
        switch configuration.provider {
        case .openAICompatible:
            try await sendOpenAICompatible(messages: messages)
        case .anthropic:
            try await sendAnthropic(messages: messages)
        }
    }

    private func sendOpenAICompatible(messages: [ChatMessage]) async throws -> String {
        let endpoint = try endpoint(path: "chat/completions")
        let requestMessages = messages.map(OpenAIChatRequest.Message.init)
        let body = OpenAIChatRequest(
            model: configuration.model,
            messages: requestMessages,
            maxTokens: configuration.maxTokens
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(request)
        let response = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return content
    }

    private func sendAnthropic(messages: [ChatMessage]) async throws -> String {
        let endpoint = try endpoint(path: "messages")
        let requestMessages = messages
            .filter { $0.role != .system }
            .map(AnthropicRequest.Message.init)
        let systemPrompt = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let body = AnthropicRequest(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: requestMessages
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(request)
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = response.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return content
    }

    private func endpoint(path: String) throws -> URL {
        let trimmed = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmed) else {
            throw LLMClientError.invalidBaseURL
        }
        let currentPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([currentPath, path].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = components.url else {
            throw LLMClientError.invalidBaseURL
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.badResponse("网络响应无效。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = decodeErrorMessage(from: data)
            throw LLMClientError.badResponse("请求失败（HTTP \(httpResponse.statusCode)）：\(detail)")
        }
        return data
    }

    private func decodeErrorMessage(from data: Data) -> String {
        if let providerError = try? JSONDecoder().decode(ProviderErrorResponse.self, from: data) {
            return providerError.resolvedMessage
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "无错误详情。"
    }
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: Content

        init(message: ChatMessage) {
            role = message.role.rawValue
            if message.attachments.isEmpty {
                content = .text(message.content)
            } else {
                var parts = [ContentPart]()
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(.text(trimmed))
                }
                parts.append(contentsOf: message.attachments.map(ContentPart.image))
                content = .parts(parts)
            }
        }
    }

    enum Content: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .parts(let parts):
                var container = encoder.singleValueContainer()
                try container.encode(parts)
            }
        }
    }

    enum ContentPart: Encodable {
        case text(String)
        case image(ImageAttachment)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        enum ImageURLCodingKeys: String, CodingKey {
            case url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let attachment):
                try container.encode("image_url", forKey: .type)
                var imageContainer = container.nestedContainer(keyedBy: ImageURLCodingKeys.self, forKey: .imageURL)
                try imageContainer.encode(attachment.dataURL, forKey: .url)
            }
        }
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: Content

        init(message: ChatMessage) {
            role = message.role.rawValue
            if message.attachments.isEmpty {
                content = .text(message.content)
            } else {
                var parts = [ContentPart]()
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(.text(trimmed))
                }
                parts.append(contentsOf: message.attachments.map(ContentPart.image))
                content = .parts(parts)
            }
        }
    }

    enum Content: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .parts(let parts):
                var container = encoder.singleValueContainer()
                try container.encode(parts)
            }
        }
    }

    enum ContentPart: Encodable {
        case text(String)
        case image(ImageAttachment)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case source
        }

        enum SourceCodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let attachment):
                try container.encode("image", forKey: .type)
                var sourceContainer = container.nestedContainer(keyedBy: SourceCodingKeys.self, forKey: .source)
                try sourceContainer.encode("base64", forKey: .type)
                try sourceContainer.encode(attachment.mediaType, forKey: .mediaType)
                try sourceContainer.encode(attachment.base64Data, forKey: .data)
            }
        }
    }

    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }

    let content: [Content]
}

private struct ProviderErrorResponse: Decodable {
    struct ProviderError: Decodable {
        let message: String?
        let type: String?
    }

    let error: ProviderError?
    let message: String?

    var resolvedMessage: String {
        error?.message ?? message ?? error?.type ?? "无错误详情。"
    }
}

private extension ImageAttachment {
    var base64Data: String {
        data.base64EncodedString()
    }

    var dataURL: String {
        "data:\(mediaType);base64,\(base64Data)"
    }
}
