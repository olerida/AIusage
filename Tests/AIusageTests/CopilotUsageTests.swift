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

        XCTAssertEqual(report.totalQuantity, 14)
        XCTAssertEqual(report.totalAmount, 0.56, accuracy: 0.0001)
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
            CopilotModelUsage(model: "gpt-5", quantity: 10),
            CopilotModelUsage(model: "claude-sonnet", quantity: 4)
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            switch request.url?.path {
            case "/user":
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
        XCTAssertEqual(snapshot.modelUsage, [CopilotModelUsage(model: "GPT-5", quantity: 7)])
        XCTAssertEqual(returnedCredentials, credentials)
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
