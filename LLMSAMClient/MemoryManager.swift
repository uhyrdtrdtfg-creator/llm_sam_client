import Foundation

enum MemoryManager {
    static func buildSystemPrompt(basePrompt: String, memory: String) -> String {
        let trimmedBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedBase.isEmpty, trimmedMemory.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return trimmedBase
        case (true, false):
            return memorySection(trimmedMemory)
        case (false, false):
            return "\(trimmedBase)\n\n\(memorySection(trimmedMemory))"
        }
    }

    static func generateUpdatedMemory(
        configuration: LLMConfiguration,
        existingMemory: String,
        userMessage: String,
        assistantReply: String
    ) async throws -> String {
        let prompt = """
        你是这个本地聊天客户端的记忆整理器。请根据用户刚才的问题和助手回复，维护一份长期记忆。

        目标：
        - 只记录未来对话有用的信息：用户背景、长期偏好、项目上下文、常用技术栈、行文风格、明确要求。
        - 不记录一次性问题、临时搜索结果、敏感凭据、API Key、密码、令牌、个人隐私细节。
        - 如果现有记忆已经覆盖，不要重复。
        - 输出必须是中文 Markdown，控制在 1200 字以内。
        - 用这些小节：用户偏好、项目上下文、行文风格、注意事项。

        现有记忆：
        \(existingMemory.isEmpty ? "（无）" : existingMemory)

        刚才用户消息：
        \(userMessage)

        刚才助手回复：
        \(assistantReply)

        请输出更新后的完整记忆，不要解释。
        """

        var memoryConfiguration = configuration
        memoryConfiguration.maxTokens = min(configuration.maxTokens, 1200)
        memoryConfiguration.systemPrompt = "你只负责整理长期记忆。输出简洁、可编辑、无寒暄。"

        return try await LLMClient(configuration: memoryConfiguration).send(messages: [
            ChatMessage(role: .system, content: memoryConfiguration.systemPrompt),
            ChatMessage(role: .user, content: prompt)
        ])
    }

    private static func memorySection(_ memory: String) -> String {
        """
        以下是需要长期遵循的用户记忆和上下文。优先使用这些信息来保持连续性；如果用户本轮明确修改或否定其中内容，以用户最新消息为准。

        \(memory)
        """
    }
}
