import Foundation
import TrayletCore

struct OCRAIRequest: Equatable, Sendable {
    let settings: TranslationAISettings
    let imageData: Data
    let prompt: String
}

protocol OCRAIRecognizing: Sendable {
    func recognize(_ request: OCRAIRequest) async throws -> String
}

struct OCROpenAIClient: OCRAIRecognizing {
    static let maximumImageBytes = 20 * 1024 * 1024
    let transport: any TranslationHTTPTransport

    init(transport: any TranslationHTTPTransport = TranslationURLTransport()) {
        self.transport = transport
    }

    func recognize(_ operation: OCRAIRequest) async throws -> String {
        let url = try operation.settings.url(for: .translate)
        guard !operation.imageData.isEmpty, operation.imageData.count <= Self.maximumImageBytes else {
            throw TranslationAIFailure.oversized
        }

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !operation.settings.credential.isEmpty {
            request.setValue("Bearer " + operation.settings.credential, forHTTPHeaderField: "Authorization")
        }

        let dataURI = "data:image/png;base64," + operation.imageData.base64EncodedString()
        let userContent: [[String: Any]] = [
            ["type": "text", "text": "Please recognize the content in this image."],
            ["type": "image_url", "image_url": ["url": dataURI]]
        ]
        let body: [String: Any] = [
            "model": operation.settings.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": operation.prompt],
                ["role": "user", "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200...299: break
        case 300...399: throw TranslationAIFailure.redirected
        case 401, 403: throw TranslationAIFailure.unauthorized
        case 429: throw TranslationAIFailure.rateLimited
        default: throw TranslationAIFailure.server
        }

        guard data.count <= TranslationURLTransport.maximumResponseBytes else {
            throw TranslationAIFailure.oversized
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw TranslationAIFailure.malformed
        }

        let extracted = extractText(from: message["content"])
        guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationAIFailure.malformed
        }
        return extracted
    }

    private func extractText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
