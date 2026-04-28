import Foundation

enum FirecrawlError: LocalizedError {
    case missingAPIKey
    case emptyQuery
    case requestFailed(String)
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请先在配置页填写 Firecrawl API Key。"
        case .emptyQuery:
            "搜索关键词为空。"
        case .requestFailed(let message):
            "Firecrawl 搜索失败：\(message)"
        case .noResults:
            "Firecrawl 没有返回可用搜索结果。"
        }
    }
}

struct FirecrawlClient {
    let apiKey: String
    let limit: Int

    func searchContext(for query: String) async throws -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FirecrawlError.missingAPIKey
        }
        guard !trimmedQuery.isEmpty else {
            throw FirecrawlError.emptyQuery
        }

        var request = URLRequest(url: URL(string: "https://api.firecrawl.dev/v2/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(FirecrawlSearchRequest(
            query: trimmedQuery,
            limit: max(1, min(limit, 10)),
            sources: ["web"],
            scrapeOptions: FirecrawlSearchRequest.ScrapeOptions(formats: ["markdown"])
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FirecrawlError.requestFailed("网络响应无效。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "无错误详情。"
            throw FirecrawlError.requestFailed("HTTP \(httpResponse.statusCode)：\(detail)")
        }

        let decoded = try JSONDecoder().decode(FirecrawlSearchResponse.self, from: data)
        guard decoded.success else {
            throw FirecrawlError.requestFailed(decoded.warning ?? "接口返回 success=false。")
        }

        let results = decoded.allWebResults
        guard !results.isEmpty else {
            throw FirecrawlError.noResults
        }

        return SearchContextFormatter.format(results: results, maxCharactersPerResult: 1800)
    }
}

struct FirecrawlToolConfiguration {
    let apiKey: String
    let limit: Int
}

private struct FirecrawlSearchRequest: Encodable {
    struct ScrapeOptions: Encodable {
        let formats: [String]
    }

    let query: String
    let limit: Int
    let sources: [String]
    let scrapeOptions: ScrapeOptions
}

private struct FirecrawlSearchResponse: Decodable {
    struct DataPayload: Decodable {
        let web: [FirecrawlWebResult]?
    }

    let success: Bool
    let data: DataPayload?
    let warning: String?

    var allWebResults: [FirecrawlWebResult] {
        data?.web ?? []
    }
}

private struct FirecrawlWebResult: Decodable {
    let title: String?
    let description: String?
    let url: String?
    let markdown: String?
}

private enum SearchContextFormatter {
    static func format(results: [FirecrawlWebResult], maxCharactersPerResult: Int) -> String {
        results.enumerated().map { index, result in
            let title = nonEmpty(result.title) ?? "Untitled"
            let url = nonEmpty(result.url) ?? "No URL"
            let description = nonEmpty(result.description)
            let markdown = nonEmpty(result.markdown)
            let body = markdown ?? description ?? ""
            let clippedBody = String(body.prefix(maxCharactersPerResult))

            return """
            [\(index + 1)] \(title)
            URL: \(url)
            摘要:
            \(clippedBody)
            """
        }
        .joined(separator: "\n\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
