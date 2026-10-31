import Foundation
import Testing
@testable import TrayletApp

@Suite("Translation AI transport")
struct TranslationAITests {
    @Test func fixedTextDiagnosticHasSmallResponseBudget() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"choices":[{"message":{"content":"你好。"}}]}"#)
        let request = TranslationAIRequest(id: UUID(), action: .modelTest, settings: .init(endpoint: "https://example.invalid/v1", model: "chosen", credential: ""), content: "Hello.", source: "en", target: "zh-Hans")
        _ = try await TranslationOpenAIClient(transport: transport).perform(request)
        let sent = try #require(await transport.requests.first)
        let body = try #require(sent.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(object["max_tokens"] as? Int == 64)
    }
    @Test func requestContainsOnlyConfirmedTextAndDirection() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"choices":[{"message":{"content":"你好"}}]}"#)
        let request = TranslationAIRequest(id: UUID(), action: .translate, settings: .init(endpoint: "https://example.invalid/v1/", model: "chosen", credential: "unit-secret"), content: "Hello", source: "en", target: "zh-Hans")
        let result = try await TranslationOpenAIClient(transport: transport).perform(request)
        #expect(result == .text("你好"))
        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == request.destination)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer unit-secret")
        let body = try #require(sent.httpBody)
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[1] == ["role": "user", "content": "Hello"])
        #expect(messages[0]["content"] == request.instruction)
    }
    @Test func metadataGetHasNoBodyAndNormalizesModelList() async throws {
        let transport = TranslationStubHTTP(status: 200, body: #"{"data":[{"id":"z"},{"id":"a"},{"id":"z"},{"id":""}]}"#)
        let request = TranslationAIRequest(id: UUID(), action: .models, settings: .init(endpoint: "http://127.0.0.1:1234/v1", model: "", credential: ""), content: "", source: "auto", target: "zh-Hans")
        #expect(try await TranslationOpenAIClient(transport: transport).perform(request) == .models(["a", "z"]))
        let sent = try #require(await transport.requests.first)
        #expect(sent.httpBody == nil)
        #expect(sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test(arguments: ["http://example.invalid/v1", "https://user:password@example.invalid/v1", "https://example.invalid/v1?key=secret", "https://example.invalid/v1#secret", "file:///tmp/model", "http://127.0.0.1.evil.invalid/v1"])
    func rejectsUnsafeEndpoints(endpoint: String) {
        #expect(throws: TranslationAIFailure.invalidEndpoint) { try TranslationAISettings(endpoint: endpoint, model: "m", credential: "").url(for: .translate) }
    }
    @Test(arguments: [(302, TranslationAIFailure.redirected), (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .server)])
    func mapsHTTPFailuresWithoutEchoingBody(status: Int, expected: TranslationAIFailure) async {
        let client = TranslationOpenAIClient(transport: TranslationStubHTTP(status: status, body: "body with private key and user text"))
        let request = TranslationAIRequest(id: UUID(), action: .connection, settings: .init(endpoint: "https://example.invalid/v1", model: "", credential: "secret"), content: "", source: "auto", target: "zh-Hans")
        await #expect(throws: expected) { try await client.perform(request) }
    }
    @Test func invalidResponseIsNotReportedAsSuccess() async {
        let request = TranslationAIRequest(id: UUID(), action: .connection, settings: .init(endpoint: "https://example.invalid/v1", model: "", credential: ""), content: "", source: "auto", target: "zh-Hans")
        let client = TranslationOpenAIClient(transport: TranslationStubHTTP(status: 200, body: "not json"))
        await #expect(throws: TranslationAIFailure.malformed) { try await client.perform(request) }
        #expect(TranslationAIFailure.safeMessage(URLError(.timedOut)) == "请求超时，请检查服务后重试。")
        #expect(!TranslationAIFailure.safeMessage(NSError(domain: "secret-domain", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-body"])).contains("secret"))
    }
    @Test func redirectDelegateDeclinesForwarding() async throws {
        let transport = TranslationURLTransport()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://example.invalid/v1/models")!
        let task = session.dataTask(with: original) // Never resumed; no network request.
        let redirect = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.invalid"])!
        let followed = await withCheckedContinuation { continuation in
            transport.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { continuation.resume(returning: $0) }
        }
        #expect(followed == nil)
    }
}
actor TranslationStubHTTP: TranslationHTTPTransport {
    let status: Int
    let body: String
    private(set) var requests: [URLRequest] = []
    init(status: Int, body: String) { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
