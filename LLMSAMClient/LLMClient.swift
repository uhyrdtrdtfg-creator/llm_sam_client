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

    func send(messages: [ChatMessage], firecrawlTool: FirecrawlToolConfiguration?) async throws -> String {
        guard let firecrawlTool else {
            return try await send(messages: messages)
        }

        switch configuration.provider {
        case .openAICompatible:
            return try await sendOpenAICompatibleWithFirecrawlTool(
                messages: messages,
                firecrawlTool: firecrawlTool
            )
        case .anthropic:
            return try await sendAnthropicWithFirecrawlTool(
                messages: messages,
                firecrawlTool: firecrawlTool
            )
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

    private func sendOpenAICompatibleWithFirecrawlTool(
        messages: [ChatMessage],
        firecrawlTool: FirecrawlToolConfiguration
    ) async throws -> String {
        var requestMessages = messages.map(OpenAIToolChatRequest.Message.init)
        let firstResponse = try await performOpenAIToolRequest(messages: requestMessages, includeTools: true)
        guard let firstMessage = firstResponse.choices.first?.message else {
            throw LLMClientError.emptyResponse
        }

        guard let toolCalls = firstMessage.toolCalls, !toolCalls.isEmpty else {
            return try resolvedOpenAIContent(firstMessage.content)
        }

        requestMessages.append(OpenAIToolChatRequest.Message(
            role: "assistant",
            content: firstMessage.content,
            toolCalls: toolCalls,
            toolCallID: nil,
            name: nil
        ))

        for toolCall in toolCalls {
            let result = try await executeFirecrawlToolCall(
                arguments: toolCall.function.arguments,
                firecrawlTool: firecrawlTool
            )
            requestMessages.append(OpenAIToolChatRequest.Message(
                role: "tool",
                content: result,
                toolCalls: nil,
                toolCallID: toolCall.id,
                name: toolCall.function.name
            ))
        }

        let finalResponse = try await performOpenAIToolRequest(messages: requestMessages, includeTools: true)
        guard let finalMessage = finalResponse.choices.first?.message else {
            throw LLMClientError.emptyResponse
        }
        return try resolvedOpenAIContent(finalMessage.content)
    }

    private func performOpenAIToolRequest(
        messages: [OpenAIToolChatRequest.Message],
        includeTools: Bool
    ) async throws -> OpenAIToolChatResponse {
        let endpoint = try endpoint(path: "chat/completions")
        let body = OpenAIToolChatRequest(
            model: configuration.model,
            messages: messages,
            maxTokens: configuration.maxTokens,
            tools: includeTools ? [.firecrawlSearch] : nil,
            toolChoice: includeTools ? "auto" : nil
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(request)
        return try JSONDecoder().decode(OpenAIToolChatResponse.self, from: data)
    }

    private func sendAnthropicWithFirecrawlTool(
        messages: [ChatMessage],
        firecrawlTool: FirecrawlToolConfiguration
    ) async throws -> String {
        let systemPrompt = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        var requestMessages = messages
            .filter { $0.role != .system }
            .map(AnthropicToolRequest.Message.init)

        let firstResponse = try await performAnthropicToolRequest(
            messages: requestMessages,
            systemPrompt: systemPrompt
        )
        let toolUses = firstResponse.content.compactMap(\.toolUse)
        guard !toolUses.isEmpty else {
            return try resolvedAnthropicContent(firstResponse.content)
        }

        requestMessages.append(AnthropicToolRequest.Message(
            role: "assistant",
            content: .parts(firstResponse.content.map(\.requestBlock))
        ))

        var toolResults = [AnthropicToolRequest.ContentPart]()
        for toolUse in toolUses {
            let result = try await executeFirecrawlToolCall(
                query: toolUse.input.query,
                firecrawlTool: firecrawlTool
            )
            toolResults.append(AnthropicToolRequest.ContentPart.toolResult(
                toolUseID: toolUse.id,
                content: result
            ))
        }
        requestMessages.append(AnthropicToolRequest.Message(
            role: "user",
            content: .parts(toolResults)
        ))

        let finalResponse = try await performAnthropicToolRequest(
            messages: requestMessages,
            systemPrompt: systemPrompt
        )
        return try resolvedAnthropicContent(finalResponse.content)
    }

    private func performAnthropicToolRequest(
        messages: [AnthropicToolRequest.Message],
        systemPrompt: String
    ) async throws -> AnthropicToolResponse {
        let endpoint = try endpoint(path: "messages")
        let body = AnthropicToolRequest(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: messages,
            tools: [.firecrawlSearch]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(request)
        return try JSONDecoder().decode(AnthropicToolResponse.self, from: data)
    }

    private func executeFirecrawlToolCall(
        arguments: String,
        firecrawlTool: FirecrawlToolConfiguration
    ) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FirecrawlToolArguments.self, from: data) else {
            throw LLMClientError.badResponse("模型发起了 Firecrawl tool call，但参数不是有效 JSON。")
        }
        return try await executeFirecrawlToolCall(query: decoded.query, firecrawlTool: firecrawlTool)
    }

    private func executeFirecrawlToolCall(
        query: String?,
        firecrawlTool: FirecrawlToolConfiguration
    ) async throws -> String {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMClientError.badResponse("模型发起了 Firecrawl tool call，但没有提供 query。")
        }

        let context = try await FirecrawlClient(
            apiKey: firecrawlTool.apiKey,
            limit: firecrawlTool.limit
        ).searchContext(for: query)

        return """
        Firecrawl 搜索结果：
        \(context)

        请基于以上网页结果回答。需要引用来源时，使用结果编号如 [1]、[2]，并保留相关链接。
        """
    }

    private func resolvedOpenAIContent(_ content: String?) throws -> String {
        let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return trimmed
    }

    private func resolvedAnthropicContent(_ content: [AnthropicToolResponse.Content]) throws -> String {
        let text = content
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LLMClientError.emptyResponse
        }
        return text
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

private struct OpenAIToolChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: Content?
        let toolCalls: [ToolCall]?
        let toolCallID: String?
        let name: String?

        init(message: ChatMessage) {
            role = message.role.rawValue
            toolCalls = nil
            toolCallID = nil
            name = nil
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

        init(
            role: String,
            content: String?,
            toolCalls: [ToolCall]?,
            toolCallID: String?,
            name: String?
        ) {
            self.role = role
            self.content = content.map(Content.text)
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
            case name
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

    struct ToolCall: Codable {
        struct Function: Codable {
            let name: String
            let arguments: String
        }

        let id: String
        let type: String
        let function: Function
    }

    struct Tool: Encodable {
        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: Parameters
        }

        struct Parameters: Encodable {
            struct QueryProperty: Encodable {
                let type = "string"
                let description = "Search query for current public web information."
            }

            let type = "object"
            let properties = ["query": QueryProperty()]
            let required = ["query"]
        }

        let type = "function"
        let function: Function

        static let firecrawlSearch = Tool(function: Function(
            name: "firecrawl_search",
            description: "Search the public web with Firecrawl and return markdown snippets with source URLs. Use only when the answer needs current or external web information.",
            parameters: Parameters()
        ))
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int
    let tools: [Tool]?
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct OpenAIToolChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [OpenAIToolChatRequest.ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
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

private struct AnthropicToolRequest: Encodable {
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

        init(role: String, content: Content) {
            self.role = role
            self.content = content
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
        case toolUse(id: String, name: String, input: FirecrawlToolArguments)
        case toolResult(toolUseID: String, content: String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case source
            case id
            case name
            case input
            case toolUseID = "tool_use_id"
            case content
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
            case .toolUse(let id, let name, let input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case .toolResult(let toolUseID, let content):
                try container.encode("tool_result", forKey: .type)
                try container.encode(toolUseID, forKey: .toolUseID)
                try container.encode(content, forKey: .content)
            }
        }
    }

    struct Tool: Encodable {
        struct InputSchema: Encodable {
            struct QueryProperty: Encodable {
                let type = "string"
                let description = "Search query for current public web information."
            }

            let type = "object"
            let properties = ["query": QueryProperty()]
            let required = ["query"]
        }

        let name: String
        let description: String
        let inputSchema: InputSchema

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case inputSchema = "input_schema"
        }

        static let firecrawlSearch = Tool(
            name: "firecrawl_search",
            description: "Search the public web with Firecrawl and return markdown snippets with source URLs. Use only when the answer needs current or external web information.",
            inputSchema: InputSchema()
        )
    }

    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]
    let tools: [Tool]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
    }
}

private struct AnthropicToolResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: FirecrawlToolArguments?

        var toolUse: ToolUse? {
            guard type == "tool_use", let id, let name else {
                return nil
            }
            return ToolUse(id: id, name: name, input: input ?? FirecrawlToolArguments(query: nil))
        }

        var requestBlock: AnthropicToolRequest.ContentPart {
            if let toolUse {
                return .toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input)
            }
            return .text(text ?? "")
        }
    }

    struct ToolUse {
        let id: String
        let name: String
        let input: FirecrawlToolArguments
    }

    let content: [Content]
}

private struct FirecrawlToolArguments: Codable {
    let query: String?
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
