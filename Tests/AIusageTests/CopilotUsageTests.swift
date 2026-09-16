import XCTest
@testable import AIusage

final class CopilotUsageTests: XCTestCase {
    override func tearDown() {
        GitHubURLProtocol.handler = nil
        super.tearDown()
    }

    func testDecodesGitHubAccountURLs() throws {
        let data = Data(
            #"{"login":"olerida","name":"Òscar","avatar_url":"https://avatars.githubusercontent.com/u/1","html_url":"https://github.com/olerida"}"#.utf8
        )

        let account = try JSONDecoder.github.decode(GitHubAccount.self, from: data)

        XCTAssertEqual(account.login, "olerida")
        XCTAssertEqual(account.avatarURL?.host, "avatars.githubusercontent.com")
        XCTAssertEqual(account.htmlURL?.absoluteString, "https://github.com/olerida")
    }

    func testDecodesGitHubBillingReportAndAggregatesTotals() throws {
        let data = Data(
            #"""
            {
              "timePeriod": {"year": 2026, "month": 9},
              "user": "olerida",
              "usageItems": [
                {
                  "product": "copilot",
                  "sku": "premium_interactions",
                  "model": "gpt-5",
                  "unitType": "requests",
                  "grossQuantity": 12,
                  "discountQuantity": 2,
                  "netQuantity": 10,
                  "netAmount": 0.40
                },
                {
                  "product": "copilot",
                  "sku": "premium_interactions",
                  "model": "claude-sonnet",
                  "unitType": "requests",
                  "grossQuantity": 4,
                  "netQuantity": 4,
                  "netAmount": 0.16
                }
              ]
            }
            """#.utf8
        )

        let report = try JSONDecoder.github.decode(GitHubBillingUsageReport.self, from: data)

        XCTAssertEqual(report.totalQuantity, 16)
        XCTAssertEqual(report.totalAmount, 0.56, accuracy: 0.0001)
    }

    func testDecodesCopilotPlanQuotaAndReset() throws {
        let data = Data(
            #"{"copilot_plan":"individual_max","access_type_sku":"max_monthly_subscriber_quota","quota_reset_date":"2026-10-01","quota_reset_date_utc":"2026-10-01T00:00:00.000Z","quota_snapshots":{"premium_interactions":{"entitlement":20000,"quota_remaining":12741.6,"percent_remaining":63.7,"credits_used":7258,"unlimited":false}}}"#.utf8
        )

        let entitlement = try JSONDecoder.github.decode(GitHubCopilotEntitlement.self, from: data)

        XCTAssertEqual(entitlement.planDisplayName, "Copilot Max")
        XCTAssertEqual(entitlement.premiumQuota?.total, 20_000)
        XCTAssertEqual(entitlement.premiumQuota?.used, 7_258)
        XCTAssertEqual(entitlement.premiumQuota?.usedPercent ?? -1, 36.3, accuracy: 0.0001)
        XCTAssertEqual(
            entitlement.resetAt,
            ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")
        )
    }

    func testModelBreakdownUsesPremiumRequestsWithoutDoubleCountingCredits() {
        let premium = report(items: [
            item(model: "gpt-5", quantity: 8),
            item(model: "gpt-5", quantity: 2),
            item(model: "claude-sonnet", quantity: 4)
        ])
        let credits = report(items: [item(model: "gpt-5", quantity: 30)])
        let snapshot = CopilotUsageSnapshot(
            account: GitHubAccount(login: "olerida", name: nil, avatarURL: nil, htmlURL: nil),
            premiumRequests: premium,
            aiCredits: credits,
            fetchedAt: Date()
        )

        XCTAssertEqual(snapshot.modelUsage, [
            CopilotModelUsage(model: "gpt-5", quantity: 10, unitType: "requests"),
            CopilotModelUsage(model: "claude-sonnet", quantity: 4, unitType: "requests")
        ])
        XCTAssertEqual(snapshot.totalNetAmount, 0)
    }

    func testUnavailableReportsProduceNoMetrics() {
        let snapshot = CopilotUsageSnapshot(
            account: GitHubAccount(login: "olerida", name: nil, avatarURL: nil, htmlURL: nil),
            premiumRequests: nil,
            aiCredits: nil,
            fetchedAt: Date()
        )

        XCTAssertTrue(snapshot.modelUsage.isEmpty)
    }

    func testCachedSnapshotWithoutEntitlementStillDecodes() throws {
        let data = Data(
            #"{"account":{"login":"olerida"},"fetchedAt":"2026-09-16T07:00:00Z"}"#.utf8
        )

        let snapshot = try JSONDecoder.github.decode(CopilotUsageSnapshot.self, from: data)

        XCTAssertEqual(snapshot.account.login, "olerida")
        XCTAssertNil(snapshot.entitlement)
    }

    func testGitHubCredentialCacheReadsKeychainOnlyOnce() throws {
        let credentials = GitHubCredentials(
            accessToken: "token",
            tokenType: "bearer",
            scope: nil,
            expiresAt: nil,
            refreshToken: nil,
            refreshTokenExpiresAt: nil
        )
        var reads = 0
        var cache = GitHubCredentialMemoryCache()

        XCTAssertEqual(try cache.load {
            reads += 1
            return credentials
        }, credentials)
        XCTAssertEqual(try cache.load {
            reads += 1
            return nil
        }, credentials)
        XCTAssertEqual(reads, 1)
    }

    func testGitHubCredentialCacheDoesNotRepeatFailedKeychainAccess() {
        enum TestError: Error { case denied }
        var reads = 0
        var cache = GitHubCredentialMemoryCache()

        XCTAssertThrowsError(try cache.load {
            reads += 1
            throw TestError.denied
        })
        XCTAssertThrowsError(try cache.load {
            reads += 1
            return nil
        })
        XCTAssertEqual(reads, 1)
    }

    func testGitHubCredentialCacheCanBeUpdatedAndClearedWithoutKeychainRead() throws {
        let credentials = GitHubCredentials(
            accessToken: "updated-token",
            tokenType: "bearer",
            scope: nil,
            expiresAt: nil,
            refreshToken: nil,
            refreshTokenExpiresAt: nil
        )
        var reads = 0
        var cache = GitHubCredentialMemoryCache()

        cache.store(credentials)
        XCTAssertEqual(try cache.load {
            reads += 1
            return nil
        }, credentials)
        cache.clear()
        XCTAssertNil(try cache.load {
            reads += 1
            return credentials
        })
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testCopilotMenuBarTogglesMatchCodexBehavior() {
        let previousCredits = AppSettings.showCopilotCreditsInMenuBar
        let previousPercentage = AppSettings.showCopilotUsagePercentageInMenuBar
        defer {
            AppSettings.showCopilotCreditsInMenuBar = previousCredits
            AppSettings.showCopilotUsagePercentageInMenuBar = previousPercentage
        }

        let entitlement = GitHubCopilotEntitlement(
            copilotPlan: "individual_max",
            accessTypeSKU: "max_monthly_subscriber_quota",
            quotaResetDate: "2026-10-01",
            quotaResetDateUTC: "2026-10-01T00:00:00.000Z",
            quotaSnapshots: [
                "premium_interactions": .init(
                    entitlement: 20_000,
                    remaining: 12_741,
                    quotaRemaining: 12_741.6,
                    percentRemaining: 63.7,
                    creditsUsed: 7_258,
                    unlimited: false
                )
            ]
        )
        let store = UsageStore(
            previewAgent: .githubCopilot,
            state: .ready,
            copilotSnapshot: CopilotUsageSnapshot(
                account: GitHubAccount(login: "olerida", name: nil, avatarURL: nil, htmlURL: nil),
                premiumRequests: nil,
                aiCredits: nil,
                entitlement: entitlement,
                fetchedAt: Date()
            )
        )

        store.setShowCopilotCreditsInMenuBar(true)
        store.setShowCopilotUsagePercentageInMenuBar(false)
        XCTAssertEqual(store.statusText.filter(\.isNumber), "7258")

        store.setShowCopilotCreditsInMenuBar(false)
        store.setShowCopilotUsagePercentageInMenuBar(true)
        XCTAssertEqual(store.statusText, "36%")

        store.setShowCopilotCreditsInMenuBar(true)
        XCTAssertTrue(store.statusText.hasSuffix(" · 36%"))

        store.setShowCopilotCreditsInMenuBar(false)
        store.setShowCopilotUsagePercentageInMenuBar(false)
        XCTAssertEqual(store.statusText, "")
    }

    func testDeviceFlowSendsOnlyThePublicClientID() async throws {
        GitHubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(GitHubURLProtocol.bodyString(for: request), "client_id=public-client-id")
            return GitHubURLProtocol.response(
                for: request,
                status: 200,
                json: #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
            )
        }

        let authorization = try await GitHubCopilotClient(
            clientID: "public-client-id",
            session: makeGitHubSession()
        ).requestDeviceAuthorization()

        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURI.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(authorization.pollingInterval, 5)
    }

    func testFetchSnapshotUsesPersonalBillingRoutesAndOmitsUnavailableReport() async throws {
        GitHubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
            switch request.url?.path {
            case "/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
                return GitHubURLProtocol.response(
                    for: request,
                    status: 200,
                    json: #"{"login":"olerida","name":"Òscar","html_url":"https://github.com/olerida"}"#
                )
            case "/users/olerida/settings/billing/premium_request/usage":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
                XCTAssertEqual(query["year"] ?? nil, "2026")
                XCTAssertEqual(query["month"] ?? nil, "9")
                return GitHubURLProtocol.response(
                    for: request,
                    status: 200,
                    json: #"{"timePeriod":{"year":2026,"month":9},"user":"olerida","usageItems":[{"product":"Copilot","sku":"Copilot Premium Request","model":"GPT-5","unitType":"requests","netQuantity":7,"netAmount":0.28}]}"#
                )
            case "/users/olerida/settings/billing/ai_credit/usage":
                return GitHubURLProtocol.response(for: request, status: 404, json: #"{"message":"Not Found"}"#)
            case "/copilot_internal/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2025-05-01")
                return GitHubURLProtocol.response(
                    for: request,
                    status: 200,
                    json: #"{"copilot_plan":"individual_max","access_type_sku":"max_monthly_subscriber_quota","quota_reset_date_utc":"2026-10-01T00:00:00.000Z","quota_snapshots":{"premium_interactions":{"entitlement":20000,"percent_remaining":63.7,"credits_used":7258}}}"#
                )
            default:
                XCTFail("Unexpected GitHub route: \(request.url?.absoluteString ?? "nil")")
                return GitHubURLProtocol.response(for: request, status: 500, json: #"{"message":"Unexpected"}"#)
            }
        }

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-09T10:00:00Z"))
        let credentials = GitHubCredentials(
            accessToken: "user-token",
            tokenType: "bearer",
            scope: "",
            expiresAt: nil,
            refreshToken: nil,
            refreshTokenExpiresAt: nil
        )
        let (snapshot, returnedCredentials) = try await GitHubCopilotClient(
            clientID: "public-client-id",
            session: makeGitHubSession()
        ).fetchSnapshot(credentials: credentials, now: now)

        XCTAssertEqual(snapshot.account.login, "olerida")
        XCTAssertEqual(snapshot.premiumRequests?.totalQuantity, 7)
        XCTAssertNil(snapshot.aiCredits)
        XCTAssertEqual(snapshot.modelUsage, [
            CopilotModelUsage(model: "GPT-5", quantity: 7, unitType: "requests")
        ])
        XCTAssertEqual(snapshot.entitlement?.planDisplayName, "Copilot Max")
        XCTAssertEqual(snapshot.entitlement?.premiumQuota?.usedPercent ?? -1, 36.3, accuracy: 0.0001)
        XCTAssertEqual(returnedCredentials, credentials)
    }

    func testCoveredAICreditsRemainVisibleAndSupplyModelBreakdown() {
        let coveredUsage = GitHubBillingUsageReport.Item(
            product: "copilot",
            sku: "copilot_ai_credit",
            model: "GPT-5",
            unitType: "ai-credits",
            grossQuantity: 100,
            grossAmount: 1,
            discountQuantity: 100,
            discountAmount: 1,
            netQuantity: 0,
            netAmount: 0
        )
        let snapshot = CopilotUsageSnapshot(
            account: GitHubAccount(login: "olerida", name: nil, avatarURL: nil, htmlURL: nil),
            premiumRequests: report(items: []),
            aiCredits: report(items: [coveredUsage]),
            fetchedAt: Date()
        )

        XCTAssertEqual(snapshot.aiCredits?.totalQuantity, 100)
        XCTAssertEqual(snapshot.totalGrossAmount, 1)
        XCTAssertEqual(snapshot.totalNetAmount, 0)
        XCTAssertEqual(snapshot.modelUsage, [
            CopilotModelUsage(model: "GPT-5", quantity: 100, unitType: "ai-credits")
        ])
    }

    private func report(items: [GitHubBillingUsageReport.Item]) -> GitHubBillingUsageReport {
        GitHubBillingUsageReport(timePeriod: nil, user: "olerida", usageItems: items)
    }

    private func item(model: String, quantity: Double) -> GitHubBillingUsageReport.Item {
        GitHubBillingUsageReport.Item(
            product: "copilot",
            sku: "premium_interactions",
            model: model,
            unitType: "requests",
            grossQuantity: quantity,
            grossAmount: nil,
            discountQuantity: nil,
            discountAmount: nil,
            netQuantity: quantity,
            netAmount: nil
        )
    }

    private func makeGitHubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class GitHubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(for request: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    static func bodyString(for request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
