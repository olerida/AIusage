import Foundation
import XCTest
@testable import AIusage

final class CodexSessionUsageScannerTests: XCTestCase {
    func testAggregatesRecentSessionsByModel() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexSessionUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archived, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try writeJSONL(
            to: sessions.appendingPathComponent("recent.jsonl"),
            lines: [
                "not-json",
                #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                tokenCount(input: 100, cached: 40, cacheWrite: 10, output: 20),
                tokenCount(input: 30, cached: 5, cacheWrite: 0, output: 10),
                #"{"type":"turn_context","payload":{"model_slug":"gpt-5.4"}}"#,
                responseItemTokenCount(input: 50, cached: 20, cacheWrite: 5, output: 5)
            ],
            modifiedAt: now,
            fileManager: fileManager
        )
        try writeJSONL(
            to: archived.appendingPathComponent("old.jsonl"),
            lines: [
                #"{"type":"turn_context","payload":{"model":"ignored-model"}}"#,
                tokenCount(input: 999, cached: 0, cacheWrite: 0, output: 1)
            ],
            modifiedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            fileManager: fileManager
        )

        let usage = await CodexSessionUsageScanner(homeDirectory: root).scan(now: now)

        XCTAssertEqual(usage, [
            CodexModelUsage(
                model: "gpt-5.6-sol",
                inputTokens: 75,
                outputTokens: 30,
                cachedInputTokens: 45,
                cacheWriteInputTokens: 10
            ),
            CodexModelUsage(
                model: "gpt-5.4",
                inputTokens: 25,
                outputTokens: 5,
                cachedInputTokens: 20,
                cacheWriteInputTokens: 5
            )
        ])
    }

    func testMissingSessionDirectoriesReturnNoUsage() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingCodexHome-\(UUID().uuidString)", isDirectory: true)

        let usage = await CodexSessionUsageScanner(homeDirectory: root).scan()

        XCTAssertTrue(usage.isEmpty)
    }

    func testUsageSnapshotDecodesWithoutModelUsage() throws {
        let data = Data(
            #"{"account":null,"windows":[],"resets":[],"availableResetCount":0,"tokenUsage":null,"fetchedAt":0}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        XCTAssertNil(snapshot.modelUsage)
    }

    private func tokenCount(input: Int, cached: Int, cacheWrite: Int, output: Int) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output)}}}}"#
    }

    private func responseItemTokenCount(input: Int, cached: Int, cacheWrite: Int, output: Int) -> String {
        #"{"type":"response_item","payload":{"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output)}}}}}"#
    }

    private func writeJSONL(
        to url: URL,
        lines: [String],
        modifiedAt: Date,
        fileManager: FileManager
    ) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}
