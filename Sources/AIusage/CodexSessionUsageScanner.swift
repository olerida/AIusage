import Foundation

actor CodexSessionUsageScanner {
    private struct Totals {
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cachedInputTokens: Int64 = 0
        var cacheWriteInputTokens: Int64 = 0
    }

    private let homeDirectory: URL
    private let lookbackInterval: TimeInterval
    private let turnContextMarker = Data(#""turn_context""#.utf8)
    private let tokenCountMarker = Data(#""token_count""#.utf8)

    init(homeDirectory: URL, lookbackDays: Int = 30) {
        self.homeDirectory = homeDirectory
        lookbackInterval = TimeInterval(max(1, lookbackDays) * 24 * 60 * 60)
    }

    func scan(now: Date = Date()) -> [CodexModelUsage] {
        let cutoff = now.addingTimeInterval(-lookbackInterval)
        var totals: [String: Totals] = [:]

        for fileURL in recentSessionFiles(since: cutoff) {
            scan(fileURL, into: &totals)
        }

        return totals.map { model, value in
            CodexModelUsage(
                model: model,
                inputTokens: value.inputTokens,
                outputTokens: value.outputTokens,
                cachedInputTokens: value.cachedInputTokens,
                cacheWriteInputTokens: value.cacheWriteInputTokens
            )
        }
        .filter { $0.totalTokens > 0 }
        .sorted { lhs, rhs in
            lhs.totalTokens == rhs.totalTokens
                ? lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                : lhs.totalTokens > rhs.totalTokens
        }
    }

    private func recentSessionFiles(since cutoff: Date) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var files: [URL] = []

        for directoryName in ["sessions", "archived_sessions"] {
            let directory = homeDirectory.appendingPathComponent(directoryName, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= cutoff else { continue }
                files.append(fileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    private func scan(_ fileURL: URL, into totals: inout [String: Totals]) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return }
        var currentModel = "codex"

        for rawLine in data.split(separator: 0x0A) {
            let line = Data(rawLine)
            guard line.range(of: turnContextMarker) != nil || line.range(of: tokenCountMarker) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            if entry["type"] as? String == "turn_context" {
                let payload = entry["payload"] as? [String: Any]
                currentModel = modelName(payload?["model"] ?? payload?["model_slug"], fallback: currentModel)
                continue
            }

            var payload = (entry["payload"] as? [String: Any]) ?? entry
            if entry["type"] as? String == "response_item",
               let nestedPayload = payload["payload"] as? [String: Any] {
                payload = nestedPayload
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any] else { continue }

            let cachedRead = tokenValue(usage["cached_input_tokens"])
            let cachedWrite = tokenValue(usage["cache_write_input_tokens"])
            let rawInput = tokenValue(usage["input_tokens"])
            let input = max(0, rawInput - cachedRead - cachedWrite)
            let output = tokenValue(usage["output_tokens"])
            guard input > 0 || output > 0 || cachedRead > 0 || cachedWrite > 0 else { continue }

            var modelTotals = totals[currentModel] ?? Totals()
            modelTotals.inputTokens += input
            modelTotals.outputTokens += output
            modelTotals.cachedInputTokens += cachedRead
            modelTotals.cacheWriteInputTokens += cachedWrite
            totals[currentModel] = modelTotals
        }
    }

    private func modelName(_ value: Any?, fallback: String) -> String {
        guard let value = value as? String else { return fallback }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func tokenValue(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        if let string = value as? String, let number = Int64(string) { return max(0, number) }
        return 0
    }
}
