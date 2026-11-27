import Foundation
import Testing
@testable import TrayletApp

@Suite("OCR AI Client") struct OCRAITests {
    @Test func sendsMultimodalImageURLAndParsesTextResponse() async throws {
        let transport = FakeOCRHTTPTransport { request in
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "gpt-4o")
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            let userContent = try #require(messages[1]["content"] as? [[String: Any]])
            let imagePart = try #require(userContent.last?["image_url"] as? [String: Any])
            let url = try #require(imagePart["url"] as? String)
            #expect(url.hasPrefix("data:image/png;base64,"))
            let responseJSON = ["choices": [["message": ["content": "Recognized Table"]]]]
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let http = HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, http)
        }
        let client = OCROpenAIClient(transport: transport)
        let settings = TranslationAISettings(endpoint: "https://api.openai.com/v1", model: "gpt-4o", credential: "sk-test")
        let result = try await client.recognize(OCRAIRequest(
            settings: settings,
            imageData: Data([137, 80, 78, 71]),
            prompt: OCRAIPreset.markdown.systemPrompt
        ))
        #expect(result == "Recognized Table")
    }

    @Test func mapsUnauthorizedAndRateLimitedStatusCodes() async throws {
        let unauthorizedTransport = FakeOCRHTTPTransport { request in
            let http = HTTPURLResponse(url: try #require(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), http)
        }
        let client = OCROpenAIClient(transport: unauthorizedTransport)
        let settings = TranslationAISettings(endpoint: "https://api.openai.com/v1", model: "gpt-4o", credential: "bad")
        await #expect(throws: TranslationAIFailure.unauthorized) {
            try await client.recognize(OCRAIRequest(settings: settings, imageData: Data([1, 2, 3]), prompt: "p"))
        }

        let rateLimitTransport = FakeOCRHTTPTransport { request in
            let http = HTTPURLResponse(url: try #require(request.url), statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (Data(), http)
        }
        let client2 = OCROpenAIClient(transport: rateLimitTransport)
        await #expect(throws: TranslationAIFailure.rateLimited) {
            try await client2.recognize(OCRAIRequest(settings: settings, imageData: Data([1, 2, 3]), prompt: "p"))
        }
    }
}

private final class FakeOCRHTTPTransport: TranslationHTTPTransport, @unchecked Sendable {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}
