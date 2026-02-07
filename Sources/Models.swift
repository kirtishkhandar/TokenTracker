import Foundation

// MARK: - Usage Record

struct UsageRecord: Identifiable {
    let id: Int
    let timestamp: Date
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
        // "claude-sonnet-4-20250514" → "sonnet-4"
        let parts = model.split(separator: "-")
        if parts.count >= 3,
           let familyIdx = parts.firstIndex(where: {
               ["haiku", "sonnet", "opus"].contains($0.lowercased())
           }) {
            let family = parts[familyIdx]
            let version = familyIdx + 1 < parts.count
                ? "-\(parts[familyIdx + 1])" : ""
            return "\(family)\(version)"
        }
        return model
    }
}

// MARK: - Token Pricing

/// Estimated pricing per million tokens.
/// These are approximations — update as Anthropic changes pricing.
struct TokenPricing {
    struct ModelPrice {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheCreationPerMillion: Double
        let cacheReadPerMillion: Double
    }

    /// Pricing table (per million tokens, USD).
    /// Last updated: 2025 pricing. Update as needed.
    static let prices: [String: ModelPrice] = [
        // Claude 4 / 4.5 family
        "claude-opus-4": ModelPrice(
            inputPerMillion: 15.0, outputPerMillion: 75.0,
            cacheCreationPerMillion: 18.75, cacheReadPerMillion: 1.50),
        "claude-sonnet-4": ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30),
        "claude-haiku-4": ModelPrice(
            inputPerMillion: 0.80, outputPerMillion: 4.0,
            cacheCreationPerMillion: 1.0, cacheReadPerMillion: 0.08),

        // Claude 3.5 family
        "claude-3-5-sonnet": ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30),
        "claude-3-5-haiku": ModelPrice(
            inputPerMillion: 0.80, outputPerMillion: 4.0,
            cacheCreationPerMillion: 1.0, cacheReadPerMillion: 0.08),

        // Claude 3 family
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

    /// Look up pricing for a model string.
    /// Matches by prefix: "claude-sonnet-4-20250514" matches "claude-sonnet-4".
    static func priceFor(model: String) -> ModelPrice {
        // Try exact match first
        if let p = prices[model] { return p }

        // Try prefix match (longest prefix wins)
        let sorted = prices.keys.sorted { $0.count > $1.count }
        for key in sorted {
            if model.hasPrefix(key) { return prices[key]! }
        }

        // Fallback: sonnet-tier pricing
        return ModelPrice(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30)
    }

    static func cost(model: String, inputTokens: Int, outputTokens: Int,
                     cacheCreationTokens: Int = 0,
                     cacheReadTokens: Int = 0) -> Double {
        let p = priceFor(model: model)
        let input = Double(inputTokens) / 1_000_000 * p.inputPerMillion
        let output = Double(outputTokens) / 1_000_000 * p.outputPerMillion
        let cacheCreate = Double(cacheCreationTokens) / 1_000_000
            * p.cacheCreationPerMillion
        let cacheRead = Double(cacheReadTokens) / 1_000_000
            * p.cacheReadPerMillion
        return input + output + cacheCreate + cacheRead
    }
}

// MARK: - Summary Structures

struct ModelSummary: Identifiable {
    let model: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double

    var id: String { model }
    var totalTokens: Int { inputTokens + outputTokens }
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
