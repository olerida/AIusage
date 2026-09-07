import AppKit
import Foundation

enum AppServerError: LocalizedError {
    case executableNotFound
    case notRunning
    case processExited
    case malformedMessage
    case requestTimedOut
    case remote(code: Int?, message: String)
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: return L10n.string("error.codexNotFound")
        case .notRunning: return L10n.string("error.serverNotRunning")
        case .processExited: return L10n.string("error.processExited")
        case .malformedMessage: return L10n.string("error.malformedMessage")
        case .requestTimedOut: return L10n.string("error.requestTimedOut")
        case .remote(_, let message): return message
        case .loginFailed(let message): return message
        }
    }
}

@MainActor
final class CodexAppServerClient {
    typealias RateLimitNotificationHandler = (JSONValue) -> Void

    private let executableURL: URL
    private let codexHome: URL
    private var process: Process?
    private var inputPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var loginContinuation: CheckedContinuation<Void, Error>?
    private var loginID: String?

    var onRateLimitNotification: RateLimitNotificationHandler?

    init(executableURL: URL, codexHome: URL = AppSettings.codexHomeDirectory) {
        self.executableURL = executableURL
        self.codexHome = codexHome
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() async throws {
        guard !isRunning else { return }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProcessExit()
            }
        }

        try process.run()
        self.process = process
        self.inputPipe = inputPipe

        readerTask = Task { [weak self, outputPipe] in
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    self?.receive(line: line)
                }
            } catch {
                self?.handleProcessExit()
            }
        }

        let clientInfo: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("aiusage"),
                "title": .string("AIusage"),
                "version": .string("1.0.0")
            ])
        ])
        _ = try await request(method: "initialize", params: clientInfo)
        try send(RPCRequest(method: "initialized", id: nil, params: .object([:])))
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        loginContinuation?.resume(throwing: AppServerError.processExited)
        loginContinuation = nil
        loginID = nil

        let error = AppServerError.processExited
        pending.values.forEach { $0.resume(throwing: error) }
        pending.removeAll()

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        inputPipe = nil
    }

    func readAccount() async throws -> AccountReadResponse {
        let result = try await request(method: "account/read", params: .object(["refreshToken": .bool(false)]))
        return try decode(AccountReadResponse.self, from: result)
    }

    func readRateLimits() async throws -> RateLimitsResponse {
        let result = try await request(method: "account/rateLimits/read", params: nil)
        return try decode(RateLimitsResponse.self, from: result)
    }

    func readTokenUsage() async throws -> AccountTokenUsage {
        let result = try await request(method: "account/usage/read", params: nil)
        return try decode(AccountTokenUsage.self, from: result)
    }

    func login() async throws {
        let params: JSONValue = .object([
            "type": .string("chatgpt"),
            "useHostedLoginSuccessPage": .bool(true),
            "appBrand": .string("codex")
        ])
        let result = try await request(method: "account/login/start", params: params)
        let login = try decode(LoginStartResponse.self, from: result)
        guard let authURLString = login.authUrl, let authURL = URL(string: authURLString) else {
            throw AppServerError.loginFailed(L10n.string("error.loginURLMissing"))
        }

        loginID = login.loginId
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loginContinuation = continuation
            if !NSWorkspace.shared.open(authURL) {
                loginContinuation = nil
                continuation.resume(throwing: AppServerError.loginFailed(L10n.string("error.browserOpen")))
            }
        }
    }

    func logout() async throws {
        _ = try await request(method: "account/logout", params: nil)
    }

    private func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard isRunning else { throw AppServerError.notRunning }
        let id = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(RPCRequest(method: method, id: id, params: params))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let timedOut = self.pending.removeValue(forKey: id) else { return }
                timedOut.resume(throwing: AppServerError.requestTimedOut)
            }
        }
    }

    private func send(_ request: RPCRequest) throws {
        guard let inputPipe else { throw AppServerError.notRunning }
        let encoder = JSONEncoder()
        let data = try encoder.encode(request) + Data([0x0A])
        inputPipe.fileHandleForWriting.write(data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return }
        do {
            let message = try JSONDecoder().decode(RPCMessage.self, from: data)
            if let id = message.id, let continuation = pending.removeValue(forKey: id) {
                if let error = message.error {
                    continuation.resume(throwing: AppServerError.remote(code: error.code, message: error.message ?? L10n.string("error.unknownCodex")))
                } else {
                    continuation.resume(returning: message.result ?? .null)
                }
                return
            }

            guard let method = message.method else { return }
            switch method {
            case "account/rateLimits/updated":
                if let params = message.params { onRateLimitNotification?(params) }
            case "account/login/completed":
                guard let params = message.params,
                      let completed = try? decode(LoginCompletedParams.self, from: params),
                      loginID == nil || completed.loginId == nil || completed.loginId == loginID else { return }
                guard let continuation = loginContinuation else { return }
                loginContinuation = nil
                loginID = nil
                if completed.success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppServerError.loginFailed(completed.error ?? L10n.string("error.loginFailed")))
                }
            default:
                break
            }
        } catch {
            // Ignore unrelated or future notifications. Pending requests still have their own timeout/restart path.
        }
    }

    private func handleProcessExit() {
        guard process != nil else { return }
        let error = AppServerError.processExited
        pending.values.forEach { $0.resume(throwing: error) }
        pending.removeAll()
        process = nil
        inputPipe = nil
    }
}

enum CodexExecutableResolver {
    static func resolve(customPath: String?) -> URL? {
        var candidates: [String] = []
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((customPath as NSString).expandingTildeInPath)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ])

        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
