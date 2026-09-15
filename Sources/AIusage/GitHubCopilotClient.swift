import Foundation

actor GitHubCopilotClient {
    private let clientID: String
    private let session: URLSession
    private let apiBaseURL = URL(string: "https://api.github.com")!
    private let loginBaseURL = URL(string: "https://github.com/login")!

    init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    func requestDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        let url = loginBaseURL.appendingPathComponent("device/code")
        let response: DeviceCodeResponse = try await postForm(url: url, values: ["client_id": clientID])
        guard let verificationURI = URL(string: response.verificationURI) else {
            throw GitHubCopilotError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURI: verificationURI,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            pollingInterval: TimeInterval(max(1, response.interval ?? 5))
        )
    }

    func pollForCredentials(using authorization: GitHubDeviceAuthorization) async throws -> GitHubCredentials {
        var interval = authorization.pollingInterval
        while Date() < authorization.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let url = loginBaseURL.appendingPathComponent("oauth/access_token")
            let response: AccessTokenResponse = try await postForm(url: url, values: [
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            if let accessToken = response.accessToken {
                return response.credentials(accessToken: accessToken)
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw GitHubCopilotError.deviceCodeExpired
            case "access_denied":
                throw GitHubCopilotError.accessDenied
            default:
                throw GitHubCopilotError.remote(response.errorDescription ?? response.error ?? "Unknown error")
            }
        }
        throw GitHubCopilotError.deviceCodeExpired
    }

    func refresh(_ credentials: GitHubCredentials) async throws -> GitHubCredentials {
        guard credentials.needsRefresh else { return credentials }
        guard let refreshToken = credentials.refreshToken else { throw GitHubCopilotError.unauthorized }

        let url = loginBaseURL.appendingPathComponent("oauth/access_token")
        let response: AccessTokenResponse = try await postForm(url: url, values: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        guard let accessToken = response.accessToken else {
            throw GitHubCopilotError.remote(response.errorDescription ?? response.error ?? "Unknown error")
        }
        let refreshed = response.credentials(accessToken: accessToken)
        return GitHubCredentials(
            accessToken: refreshed.accessToken,
            tokenType: refreshed.tokenType ?? credentials.tokenType,
            scope: refreshed.scope ?? credentials.scope,
            expiresAt: refreshed.expiresAt,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken,
            refreshTokenExpiresAt: refreshed.refreshTokenExpiresAt ?? credentials.refreshTokenExpiresAt
        )
    }

    func fetchSnapshot(credentials: GitHubCredentials, now: Date = Date()) async throws -> (CopilotUsageSnapshot, GitHubCredentials) {
        let activeCredentials = try await refresh(credentials)
        let account = try await fetchAccount(accessToken: activeCredentials.accessToken)
        async let premiumRequests = fetchBillingReport(
            pathSuffix: "premium_request/usage",
            login: account.login,
            accessToken: activeCredentials.accessToken,
            now: now
        )
        async let aiCredits = fetchBillingReport(
            pathSuffix: "ai_credit/usage",
            login: account.login,
            accessToken: activeCredentials.accessToken,
            now: now
        )

        let snapshot = CopilotUsageSnapshot(
            account: account,
            premiumRequests: try await premiumRequests,
            aiCredits: try await aiCredits,
            fetchedAt: now
        )
        return (snapshot, activeCredentials)
    }

    private func fetchAccount(accessToken: String) async throws -> GitHubAccount {
        try await get(path: "/user", accessToken: accessToken)
    }

    private func fetchBillingReport(
        pathSuffix: String,
        login: String,
        accessToken: String,
        now: Date
    ) async throws -> GitHubBillingUsageReport? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let login = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login
        return try await getOptional(
            path: "/users/\(login)/settings/billing/\(pathSuffix)?year=\(year)&month=\(month)",
            accessToken: accessToken,
            unavailableStatuses: [403, 404]
        )
    }

    private func get<T: Decodable>(path: String, accessToken: String) async throws -> T {
        let (data, response) = try await request(path: path, accessToken: accessToken)
        guard response.statusCode == 200 else { throw error(for: response.statusCode, data: data) }
        do {
            return try JSONDecoder.github.decode(T.self, from: data)
        } catch {
            throw GitHubCopilotError.invalidResponse
        }
    }

    private func getOptional<T: Decodable>(
        path: String,
        accessToken: String,
        unavailableStatuses: Set<Int>
    ) async throws -> T? {
        let (data, response) = try await request(path: path, accessToken: accessToken)
        if unavailableStatuses.contains(response.statusCode) {
            if response.statusCode == 403, response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw GitHubCopilotError.remote(L10n.string("error.githubRateLimited"))
            }
            return nil
        }
        guard response.statusCode == 200 else { throw error(for: response.statusCode, data: data) }
        do {
            return try JSONDecoder.github.decode(T.self, from: data)
        } catch {
            throw GitHubCopilotError.invalidResponse
        }
    }

    private func request(path: String, accessToken: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { throw GitHubCopilotError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AIusageMB/1.2.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw GitHubCopilotError.invalidResponse }
        return (data, httpResponse)
    }

    private func postForm<T: Decodable>(url: URL, values: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("AIusageMB/1.2.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = values
            .sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubCopilotError.invalidResponse
        }
        do {
            return try JSONDecoder.github.decode(T.self, from: data)
        } catch {
            throw GitHubCopilotError.invalidResponse
        }
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func error(for statusCode: Int, data: Data) -> GitHubCopilotError {
        if statusCode == 401 { return .unauthorized }
        let message = (try? JSONDecoder().decode(GitHubErrorResponse.self, from: data).message)
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        return .remote(message)
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode, userCode, expiresIn, interval
        case verificationURI = "verificationUri"
    }
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let error: String?
    let errorDescription: String?

    func credentials(accessToken: String, now: Date = Date()) -> GitHubCredentials {
        GitHubCredentials(
            accessToken: accessToken,
            tokenType: tokenType,
            scope: scope,
            expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }
}

private struct GitHubErrorResponse: Decodable {
    let message: String
}

enum GitHubCopilotError: LocalizedError, Equatable {
    case missingClientID
    case invalidResponse
    case unauthorized
    case deviceCodeExpired
    case accessDenied
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return L10n.string("error.githubClientID")
        case .invalidResponse: return L10n.string("error.githubInvalidResponse")
        case .unauthorized: return L10n.string("error.githubUnauthorized")
        case .deviceCodeExpired: return L10n.string("error.githubCodeExpired")
        case .accessDenied: return L10n.string("error.githubAccessDenied")
        case .remote(let message): return L10n.string("error.githubRemote", message)
        }
    }
}
