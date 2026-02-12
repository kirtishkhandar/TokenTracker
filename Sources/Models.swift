import Foundation

// MARK: - Usage Record

struct UsageRecord: Identifiable {
    let id: Int
    let timestamp: Date
    let provider: String
    let model: String
    let endpoint: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let statusCode: Int
    let requestId: String
    let stopReason: String
    let caller: String
    let error: String
    let apiKeyHint: String

    var totalTokens: Int { inputTokens + outputTokens }

    var estimatedCost: Double {
        TokenPricing.cost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationInputTokens,
            cacheReadTokens: cacheReadInputTokens
        )
    }

    var isError: Bool { !error.isEmpty }

    var shortModel: String {
        model.shortModelName
    }
}

// MARK: - Token Pricing

/// Estimated pricing per million tokens.
/// These are approximations — update as providers change pricing.
struct TokenPricing {
    struct ModelPrice {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheCreationPerMillion: Double
        let cacheReadPerMillion: Double
    }

    static let prices: [String: ModelPrice] = [
        "claude-opus-4": ModelPrice(
            inputPerMillion: 15.0, outputPerMillion: 75.0,
            cacheCreationPerMillion: 18.75, cacheReadPerMillion: 1.50),
        "claude-sonnet-4": ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30),
        "claude-haiku-4": ModelPrice(
            inputPerMillion: 0.80, outputPerMillion: 4.0,
            cacheCreationPerMillion: 1.0, cacheReadPerMillion: 0.08),
        "claude-3-5-sonnet": ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30),
        "claude-3-opus": ModelPrice(
            inputPerMillion: 15.0, outputPerMillion: 75.0,
            cacheCreationPerMillion: 18.75, cacheReadPerMillion: 1.50),
        "claude-3-sonnet": ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30),
        "claude-3-haiku": ModelPrice(
            inputPerMillion: 0.25, outputPerMillion: 1.25,
            cacheCreationPerMillion: 0.30, cacheReadPerMillion: 0.03),
    ]

    static func priceFor(model: String) -> ModelPrice {
        // Try exact match first
        if let p = prices[model] { return p }

        // Try prefix match (longest prefix wins)
        let sorted = prices.keys.sorted { $0.count > $1.count }
        for key in sorted {
            if model.hasPrefix(key) { return prices[key]! }
        }

        // Fallback
        return prices["claude-3-sonnet"]!
    }

    static func cost(model: String, inputTokens: Int, outputTokens: Int,
                     cacheCreationTokens: Int = 0,
                     cacheReadTokens: Int = 0) -> Double {
        let p = priceFor(model: model)
        let input = Double(inputTokens) / 1_000_000 * p.inputPerMillion
        let output = Double(outputTokens) / 1_000_000 * p.outputPerMillion
        let cacheCreate = Double(cacheCreationTokens) / 1_000_000 * p.cacheCreationPerMillion
        let cacheRead = Double(cacheReadTokens) / 1_000_000 * p.cacheReadPerMillion
        return input + output + cacheCreate + cacheRead
    }
}

// MARK: - Summary Structures

struct ModelSummary: Identifiable {
    let model: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int

    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens }

    var estimatedCost: Double {
        TokenPricing.cost(
            model: model,
            inputTokens: inputTokens, outputTokens: outputTokens)
    }
}

struct ApiKeySummary: Identifiable {
    let apiKeyHint: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double

    var id: String { apiKeyHint }
    var totalTokens: Int { inputTokens + outputTokens }

    var displayName: String {
        apiKeyHint.isEmpty ? "Unknown" : apiKeyHint
    }
}

struct DailySummary: Identifiable {
    let date: Date
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double

    var id: Date { date }
    var totalTokens: Int { inputTokens + outputTokens }

    var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}
