import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var selectedSection: AppSection = .chat

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch selectedSection {
                    case .chat:
                        ChatView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CompactTabBar(selection: $selectedSection)
            }
        }
    }
}

private enum AppTheme {
    static let background = Color(red: 0.965, green: 0.972, blue: 0.982)
    static let surface = Color.white
    static let mutedSurface = Color(red: 0.929, green: 0.941, blue: 0.956)
    static let ink = Color(red: 0.075, green: 0.087, blue: 0.112)
    static let secondaryInk = Color(red: 0.455, green: 0.486, blue: 0.545)
    static let blue = Color(red: 0.055, green: 0.435, blue: 0.925)
    static let teal = Color(red: 0.000, green: 0.620, blue: 0.565)
    static let amber = Color(red: 0.925, green: 0.565, blue: 0.125)
    static let line = Color.black.opacity(0.075)
}

private enum AppSection: String, CaseIterable, Identifiable {
    case chat = "对话"
    case settings = "配置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right.fill"
        case .settings:
            "slider.horizontal.3"
        }
    }
}

private struct CompactTabBar: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 15, weight: .semibold))
                        Text(section.rawValue)
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(selection == section ? AppTheme.blue : AppTheme.secondaryInk)
                    .background(selection == section ? AppTheme.blue.opacity(0.11) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AppTheme.surface)
        .overlay(alignment: .top) {
            AppTheme.line.frame(height: 1)
        }
    }
}

@MainActor
private final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var pendingAttachments: [ImageAttachment] = []
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published var activityMessage = "正在生成回复"

    private let configurationStore = ConfigurationStore.shared

    var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty) && !isSending
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        let configuration = configurationStore.configuration
        guard configuration.isReady else {
            errorMessage = "请先在配置页填写 API Key、地址前缀和模型。"
            return
        }
        guard !configurationStore.webSearchEnabled || !configurationStore.firecrawlAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "已开启联网搜索，请先在配置页填写 Firecrawl API Key。"
            return
        }

        inputText = ""
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        errorMessage = nil
        let userMessage = ChatMessage(role: .user, content: text, attachments: attachments)
        messages.append(userMessage)
        isSending = true
        activityMessage = configurationStore.webSearchEnabled ? "正在等待模型决定是否联网" : "正在生成回复"

        Task {
            do {
                let outboundMessages = messagesForRequest(visibleMessages: messages)
                let firecrawlTool = configurationStore.webSearchEnabled
                    ? FirecrawlToolConfiguration(
                        apiKey: configurationStore.firecrawlAPIKey,
                        limit: configurationStore.firecrawlResultLimit
                    )
                    : nil
                activityMessage = "正在生成回复"
                let reply = try await LLMClient(configuration: configuration).send(
                    messages: outboundMessages,
                    firecrawlTool: firecrawlTool
                )
                messages.append(ChatMessage(role: .assistant, content: reply))
                updateMemoryIfNeeded(
                    configuration: configuration,
                    userMessage: text,
                    assistantReply: reply
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    func addImages(from items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var imported = [ImageAttachment]()
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let imageData = ImageProcessor.normalizedJPEGData(from: data) else {
                    continue
                }
                imported.append(ImageAttachment(data: imageData, mediaType: "image/jpeg"))
            }

            if imported.isEmpty {
                errorMessage = "没有读到可用图片。"
            } else {
                pendingAttachments.append(contentsOf: imported)
                errorMessage = nil
            }
        }
    }

    func removePendingAttachment(_ attachment: ImageAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func clear() {
        messages.removeAll()
        errorMessage = nil
    }

    private func messagesForRequest(visibleMessages: [ChatMessage]) -> [ChatMessage] {
        var outboundMessages = visibleMessages
        let systemPrompt = MemoryManager.buildSystemPrompt(
            basePrompt: configurationStore.baseSystemPrompt,
            memory: configurationStore.memoryPrompt
        )
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outboundMessages.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }
        return outboundMessages
    }

    private func updateMemoryIfNeeded(configuration: LLMConfiguration, userMessage: String, assistantReply: String) {
        guard configurationStore.memoryAutoUpdateEnabled else {
            return
        }

        Task {
            do {
                let updatedMemory = try await MemoryManager.generateUpdatedMemory(
                    configuration: configuration,
                    existingMemory: configurationStore.memoryPrompt,
                    userMessage: userMessage,
                    assistantReply: assistantReply
                )
                configurationStore.memoryPrompt = updatedMemory
            } catch {
                errorMessage = "记忆更新失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(canClear: !viewModel.messages.isEmpty && !viewModel.isSending) {
                viewModel.clear()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            EmptyChatView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 96)
                        }

                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.isSending {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .scaleEffect(0.9)
                                Text(viewModel.activityMessage)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.secondaryInk)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .id("typing")
                        }
                    }
                    .padding(.vertical, 14)
                }
                .background(AppTheme.background)
                .onChange(of: viewModel.messages) { _, messages in
                    if let id = messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.isSending) { _, isSending in
                    if isSending {
                        withAnimation {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08))
            }

            ComposerView(
                text: $viewModel.inputText,
                attachments: $viewModel.pendingAttachments,
                canSend: viewModel.canSend,
                addImages: viewModel.addImages,
                removeAttachment: viewModel.removePendingAttachment
            ) {
                viewModel.send()
            }
        }
        .background(AppTheme.background)
    }
}

private struct ChatHeader: View {
    @ObservedObject private var store = ConfigurationStore.shared

    let canClear: Bool
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [AppTheme.blue, AppTheme.teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("LLM Client")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    ProviderPill(provider: store.provider)
                }

                Text(store.model.isEmpty ? "未配置模型" : store.model)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.secondaryInk)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button(action: clear) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(canClear ? AppTheme.secondaryInk : AppTheme.secondaryInk.opacity(0.35))
                    .background(AppTheme.mutedSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canClear)
            .accessibilityLabel("清空对话")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AppTheme.surface)
        .overlay(alignment: .bottom) {
            AppTheme.line.frame(height: 1)
        }
    }
}

private struct ProviderPill: View {
    let provider: LLMProvider

    var body: some View {
        Text(provider.shortName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(provider.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(provider.tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [AppTheme.blue.opacity(0.14), AppTheme.teal.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppTheme.blue)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 8) {
                Text("配置模型后开始对话")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text("支持 GPT 兼容接口、Claude、图片输入和 Markdown 回复。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            HStack(spacing: 8) {
                CapabilityChip(title: "GPT", color: AppTheme.teal)
                CapabilityChip(title: "Claude", color: AppTheme.amber)
                CapabilityChip(title: "Images", color: AppTheme.blue)
            }
        }
    }
}

private struct CapabilityChip: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 48)
            } else {
                Avatar(symbol: "sparkles", color: AppTheme.teal)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments, removable: false)
                }

                if !message.content.isEmpty {
                    if isUser {
                        Text(message.content)
                            .textSelection(.enabled)
                    } else {
                        MarkdownText(markdown: message.content)
                    }
                }
            }
            .font(.body)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .foregroundStyle(isUser ? .white : AppTheme.ink)
            .background(isUser ? AppTheme.blue : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if !isUser {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                }
            }
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)

            if isUser {
                Avatar(symbol: "person.fill", color: AppTheme.blue)
            } else {
                Spacer(minLength: 48)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct Avatar: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 26, height: 26)
            .background(color.opacity(0.12))
            .clipShape(Circle())
    }
}

private struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [ImageAttachment]
    @State private var selectedPhotos: [PhotosPickerItem] = []

    let canSend: Bool
    let addImages: ([PhotosPickerItem]) -> Void
    let removeAttachment: (ImageAttachment) -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !attachments.isEmpty {
                AttachmentGrid(attachments: attachments, removable: true, remove: removeAttachment)
            }

            HStack(alignment: .bottom, spacing: 9) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(AppTheme.blue)
                        .background(AppTheme.blue.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加图片")

                TextField("输入消息", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppTheme.mutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(canSend ? .white : AppTheme.secondaryInk.opacity(0.45))
                        .background(canSend ? AppTheme.ink : AppTheme.mutedSurface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        .overlay(alignment: .top) {
            AppTheme.line.frame(height: 1)
        }
        .onChange(of: selectedPhotos) { _, newItems in
            addImages(newItems)
            selectedPhotos.removeAll()
        }
    }
}

private struct AttachmentGrid: View {
    let attachments: [ImageAttachment]
    let removable: Bool
    var remove: (ImageAttachment) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 80), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                ZStack(alignment: .topTrailing) {
                    if let image = UIImage(data: attachment.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppTheme.mutedSurface)
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "photo").foregroundStyle(AppTheme.secondaryInk))
                    }

                    if removable {
                        Button {
                            remove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除图片")
                    }
                }
            }
        }
    }
}

private struct MarkdownText: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    InlineMarkdownText(block.content)
                        .font(headingFont(for: level))
                        .foregroundStyle(AppTheme.ink)
                case .paragraph:
                    InlineMarkdownText(block.content)
                        .font(.body)
                        .foregroundStyle(AppTheme.ink)
                case .listItem:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .font(.body.weight(.bold))
                            .foregroundStyle(AppTheme.secondaryInk)
                        InlineMarkdownText(block.content)
                            .font(.body)
                            .foregroundStyle(AppTheme.ink)
                    }
                case .quote:
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppTheme.teal.opacity(0.55))
                            .frame(width: 3)
                        InlineMarkdownText(block.content)
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                    .padding(.vertical, 2)
                case .code(let language):
                    CodeBlockView(code: block.content, language: language)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            .title3.weight(.bold)
        case 2:
            .headline.weight(.bold)
        default:
            .subheadline.weight(.bold)
        }
    }
}

private struct InlineMarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(markdown)
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(AppTheme.mutedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case paragraph
        case listItem
        case quote
        case code(String?)
    }

    let id = UUID()
    let kind: Kind
    let content: String
}

private enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks = [MarkdownBlock]()
        var paragraph = [String]()
        var codeLines = [String]()
        var codeLanguage: String?
        var isInCodeBlock = false

        func flushParagraph() {
            let content = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph, content: content))
            }
            paragraph.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(MarkdownBlock(kind: .code(codeLanguage), content: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLanguage = nil
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(heading.level), content: heading.content))
                continue
            }

            if let listContent = listItem(from: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .listItem, content: listContent))
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                let content = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .quote, content: content))
                continue
            }

            paragraph.append(rawLine)
        }

        if isInCodeBlock {
            blocks.append(MarkdownBlock(kind: .code(codeLanguage), content: codeLines.joined(separator: "\n")))
        }
        flushParagraph()

        return blocks.isEmpty ? [MarkdownBlock(kind: .paragraph, content: markdown)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, content: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else {
            return nil
        }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func listItem(from line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }

        guard let dotIndex = line.firstIndex(of: ".") else {
            return nil
        }
        let prefix = line[..<dotIndex]
        let afterDot = line[line.index(after: dotIndex)...]
        guard prefix.allSatisfy(\.isNumber), afterDot.hasPrefix(" ") else {
            return nil
        }
        return String(afterDot.dropFirst())
    }
}

private enum ImageProcessor {
    static func normalizedJPEGData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }

        let resized = image.resizedToFit(maxDimension: 1600)
        return resized.jpegData(compressionQuality: 0.82)
    }
}

private extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else {
            return self
        }

        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct SettingsView: View {
    @StateObject private var store = ConfigurationStore.shared
    @State private var modelTestState: ModelTestState = .idle

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()

            ScrollView {
                VStack(spacing: 18) {
                    SettingsSection(title: "供应商") {
                        ProviderSelector(selection: $store.provider)

                        AppTheme.line.frame(height: 1)

                        LabeledInput(
                            title: "模型",
                            placeholder: "model name",
                            text: $store.model,
                            keyboardType: .default,
                            secure: false
                        )
                    }

                    SettingsSection(title: "接口") {
                        LabeledInput(
                            title: "地址前缀",
                            placeholder: store.provider.defaultBaseURL,
                            text: $store.baseURL,
                            keyboardType: .URL,
                            secure: false
                        )

                        AppTheme.line.frame(height: 1)

                        LabeledInput(
                            title: "API Key",
                            placeholder: "sk-...",
                            text: $store.apiKey,
                            keyboardType: .default,
                            secure: true
                        )
                    } footer: {
                        Text("客户端会自动拼接 \(store.provider.endpointHint)。")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SettingsSection(title: "生成") {
                        TokenStepper(value: $store.maxTokens)
                    }

                    SettingsSection(title: "模型测试") {
                        ModelTestPanel(store: store, state: $modelTestState)
                    }

                    SettingsSection(title: "联网搜索") {
                        WebSearchToggle(isOn: $store.webSearchEnabled)

                        AppTheme.line.frame(height: 1)

                        LabeledInput(
                            title: "Firecrawl API Key",
                            placeholder: "fc-...",
                            text: $store.firecrawlAPIKey,
                            keyboardType: .default,
                            secure: true
                        )

                        AppTheme.line.frame(height: 1)

                        ResultLimitStepper(value: $store.firecrawlResultLimit)
                    } footer: {
                        Text("开启后，Firecrawl 会作为模型工具注册；只有模型发起 tool call 时，客户端才调用 /v2/search。")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SettingsSection(title: "记忆与系统提示") {
                        MemoryToggle(isOn: $store.memoryAutoUpdateEnabled)

                        AppTheme.line.frame(height: 1)

                        PromptEditor(
                            title: "基础系统提示",
                            placeholder: "例如：你是一个直接、务实的中文技术助手。",
                            text: $store.baseSystemPrompt,
                            minHeight: 92
                        )

                        AppTheme.line.frame(height: 1)

                        PromptEditor(
                            title: "自动记忆",
                            placeholder: "自动总结的用户偏好、项目上下文和行文风格会保存在这里，也可以手动编辑。",
                            text: $store.memoryPrompt,
                            minHeight: 170
                        )
                    } footer: {
                        Text("开启后，每次助手回复完成会再调用一次当前模型更新记忆。记忆会作为系统提示随下一轮对话发送。")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        store.applyDefaultsForSelectedProvider()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("恢复当前供应商默认值")
                            Spacer()
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.blue)
                        .padding(16)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(AppTheme.background)
            .onChange(of: store.provider) { _, provider in
                store.providerDidChange(provider)
            }
        }
    }
}

private struct SettingsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.ink)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("配置")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                Text("模型、地址前缀和密钥只保存在本机")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AppTheme.surface)
        .overlay(alignment: .bottom) {
            AppTheme.line.frame(height: 1)
        }
    }
}

private struct SettingsSection<Content: View, Footer: View>: View {
    let title: String
    let content: Content
    let footer: Footer

    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(AppTheme.secondaryInk)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            }

            footer
                .padding(.horizontal, 4)
        }
    }
}

private extension SettingsSection where Footer == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
    }
}

private struct ProviderSelector: View {
    @Binding var selection: LLMProvider

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LLMProvider.allCases) { provider in
                Button {
                    selection = provider
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: provider.icon)
                                .font(.system(size: 13, weight: .bold))
                            Text(provider.shortName)
                                .font(.callout.weight(.bold))
                        }
                        Text(provider == .openAICompatible ? "Chat Completions" : "Messages API")
                            .font(.caption2)
                            .foregroundStyle(selection == provider ? .white.opacity(0.78) : AppTheme.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .foregroundStyle(selection == provider ? .white : AppTheme.ink)
                    .background(selection == provider ? provider.tint : AppTheme.mutedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LabeledInput: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let secure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryInk)

            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.body)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(AppTheme.ink)
        }
        .padding(.vertical, 7)
    }
}

private struct TokenStepper: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("最大输出")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("\(value) tokens")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Spacer()

            StepperButton(symbol: "minus") {
                value = max(64, value - 64)
            }

            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 58)

            StepperButton(symbol: "plus") {
                value = min(8192, value + 64)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct WebSearchToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("允许模型调用 Firecrawl")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(isOn ? "按需 tool call，不预先搜索" : "模型只使用自身上下文")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 7)
    }
}

private enum ModelTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var message: String? {
        switch self {
        case .idle, .testing:
            nil
        case .success(let message), .failure(let message):
            message
        }
    }
}

private struct ModelTestPanel: View {
    @ObservedObject var store: ConfigurationStore
    @Binding var state: ModelTestState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("测试当前模型")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("只发送一条轻量测试消息，不触发 Firecrawl 或记忆总结")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }

                Spacer()

                Button {
                    testModel()
                } label: {
                    HStack(spacing: 6) {
                        if state == .testing {
                            ProgressView()
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(state == .testing ? "测试中" : "测试")
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(store.configuration.isReady ? AppTheme.ink : AppTheme.secondaryInk.opacity(0.35))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state == .testing || !store.configuration.isReady)
            }

            if let message = state.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(isSuccess ? AppTheme.teal : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
    }

    private var isSuccess: Bool {
        if case .success = state {
            return true
        }
        return false
    }

    private func testModel() {
        let configuration = store.configuration
        guard configuration.isReady else {
            state = .failure("请先填写 API Key、地址前缀和模型。")
            return
        }

        state = .testing
        Task {
            do {
                let reply = try await LLMClient(configuration: configuration).send(messages: [
                    ChatMessage(role: .system, content: "你正在进行连通性测试。请只用一句中文简短回复，不要调用任何工具。"),
                    ChatMessage(role: .user, content: "请回复：模型连接正常。")
                ])
                state = .success("测试成功：\(reply)")
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }
}

private struct MemoryToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("自动总结长期记忆")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(isOn ? "回复后自动更新记忆" : "只使用手动编辑的系统提示")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 7)
    }
}

private struct PromptEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryInk)

            TextEditor(text: $text)
                .font(.callout)
                .foregroundStyle(AppTheme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(AppTheme.mutedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryInk.opacity(0.55))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 7)
    }
}

private struct ResultLimitStepper: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("搜索结果数")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("建议 3-5 条，越多越慢也越耗 Firecrawl credits")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }

            Spacer()

            StepperButton(symbol: "minus") {
                value = max(1, value - 1)
            }

            Text("\(value)")
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 26)

            StepperButton(symbol: "plus") {
                value = min(10, value + 1)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct StepperButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(AppTheme.ink)
                .background(AppTheme.mutedSurface)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private extension LLMProvider {
    var shortName: String {
        switch self {
        case .openAICompatible:
            "GPT"
        case .anthropic:
            "Claude"
        }
    }

    var icon: String {
        switch self {
        case .openAICompatible:
            "bolt.fill"
        case .anthropic:
            "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .openAICompatible:
            AppTheme.teal
        case .anthropic:
            AppTheme.amber
        }
    }

    var endpointHint: String {
        switch self {
        case .openAICompatible:
            "/chat/completions"
        case .anthropic:
            "/messages"
        }
    }
}

@MainActor
private final class ConfigurationStore: ObservableObject {
    static let shared = ConfigurationStore()

    private let defaults = UserDefaults.standard
    private let providerDefaultsKey = "selectedProvider"

    @Published var provider: LLMProvider = .openAICompatible {
        didSet {
            defaults.set(provider.rawValue, forKey: providerDefaultsKey)
        }
    }

    @Published var baseURL: String = LLMProvider.openAICompatible.defaultBaseURL {
        didSet {
            defaults.set(baseURL, forKey: storageKey("baseURL"))
        }
    }

    @Published var model: String = LLMProvider.openAICompatible.defaultModel {
        didSet {
            defaults.set(model, forKey: storageKey("model"))
        }
    }

    @Published var maxTokens: Int = 1024 {
        didSet {
            defaults.set(maxTokens, forKey: storageKey("maxTokens"))
        }
    }

    @Published var apiKey: String = "" {
        didSet {
            KeychainStore.save(apiKey, account: provider.rawValue)
        }
    }

    @Published var webSearchEnabled: Bool = false {
        didSet {
            defaults.set(webSearchEnabled, forKey: "firecrawl.webSearchEnabled")
        }
    }

    @Published var firecrawlResultLimit: Int = 3 {
        didSet {
            defaults.set(firecrawlResultLimit, forKey: "firecrawl.resultLimit")
        }
    }

    @Published var firecrawlAPIKey: String = "" {
        didSet {
            KeychainStore.save(firecrawlAPIKey, account: "firecrawl")
        }
    }

    @Published var memoryAutoUpdateEnabled: Bool = false {
        didSet {
            defaults.set(memoryAutoUpdateEnabled, forKey: storageKey("memoryAutoUpdateEnabled"))
        }
    }

    @Published var baseSystemPrompt: String = "" {
        didSet {
            defaults.set(baseSystemPrompt, forKey: storageKey("baseSystemPrompt"))
        }
    }

    @Published var memoryPrompt: String = "" {
        didSet {
            defaults.set(memoryPrompt, forKey: storageKey("memoryPrompt"))
        }
    }

    var configuration: LLMConfiguration {
        LLMConfiguration(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: MemoryManager.buildSystemPrompt(basePrompt: baseSystemPrompt, memory: memoryPrompt)
        )
    }

    private init() {
        let initialProvider = LLMProvider(rawValue: defaults.string(forKey: providerDefaultsKey) ?? "") ?? .openAICompatible
        provider = initialProvider
        baseURL = defaults.string(forKey: storageKey("baseURL", provider: initialProvider)) ?? initialProvider.defaultBaseURL
        model = defaults.string(forKey: storageKey("model", provider: initialProvider)) ?? initialProvider.defaultModel
        maxTokens = storedMaxTokens(for: initialProvider)
        apiKey = KeychainStore.read(initialProvider.rawValue)
        webSearchEnabled = defaults.bool(forKey: "firecrawl.webSearchEnabled")
        firecrawlResultLimit = max(1, defaults.integer(forKey: "firecrawl.resultLimit"))
        if firecrawlResultLimit == 1 && defaults.object(forKey: "firecrawl.resultLimit") == nil {
            firecrawlResultLimit = 3
        }
        firecrawlAPIKey = KeychainStore.read("firecrawl")
        memoryAutoUpdateEnabled = defaults.bool(forKey: storageKey("memoryAutoUpdateEnabled", provider: initialProvider))
        baseSystemPrompt = defaults.string(forKey: storageKey("baseSystemPrompt", provider: initialProvider)) ?? ""
        memoryPrompt = defaults.string(forKey: storageKey("memoryPrompt", provider: initialProvider)) ?? ""
    }

    func providerDidChange(_ newProvider: LLMProvider) {
        apiKey = KeychainStore.read(newProvider.rawValue)
        baseURL = defaults.string(forKey: storageKey("baseURL", provider: newProvider)) ?? newProvider.defaultBaseURL
        model = defaults.string(forKey: storageKey("model", provider: newProvider)) ?? newProvider.defaultModel
        maxTokens = storedMaxTokens(for: newProvider)
        memoryAutoUpdateEnabled = defaults.bool(forKey: storageKey("memoryAutoUpdateEnabled", provider: newProvider))
        baseSystemPrompt = defaults.string(forKey: storageKey("baseSystemPrompt", provider: newProvider)) ?? ""
        memoryPrompt = defaults.string(forKey: storageKey("memoryPrompt", provider: newProvider)) ?? ""
    }

    func applyDefaultsForSelectedProvider() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
        maxTokens = 1024
    }

    private func storageKey(_ name: String, provider targetProvider: LLMProvider? = nil) -> String {
        "configuration.\((targetProvider ?? provider).rawValue).\(name)"
    }

    private func storedMaxTokens(for provider: LLMProvider) -> Int {
        let value = defaults.integer(forKey: storageKey("maxTokens", provider: provider))
        return value == 0 ? 1024 : value
    }
}
