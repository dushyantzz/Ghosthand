import Foundation

// MARK: - LayaClient
//
// HTTP client for the LOCAL Laya server's `POST /v1/systemone` endpoint. Laya's server
// speaks the Jev-compatible wire protocol, so this mirrors the Windows Jev client's
// retry/error behaviour, re-pointed at loopback.

/// Client abstraction used by `LayaDecisionModel` so callers and tests can substitute a fake.
public protocol LayaClientProtocol: AnyObject {
    /// Sends the request to the Laya server and returns its decoded response.
    func decide(_ request: LayaRequest) async throws -> LayaResponse
}

public final class LayaClient: LayaClientProtocol, @unchecked Sendable {
    private let options: LayaOptions
    private let session: URLSession

    /// Creates a client for the configured Laya server, reusing the given URL session.
    public init(options: LayaOptions, session: URLSession = .shared) {
        self.options = options
        self.session = session
    }

    // MARK: Decide

    /// Encodes the request, POSTs it to `/v1/systemone`, and decodes the response.
    public func decide(_ request: LayaRequest) async throws -> LayaResponse {
        guard let url = endpointURL(path: "/v1/systemone") else {
            throw LayaError.proto("Invalid Laya base URL '\(options.baseUrl)'")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body: Data
        do {
            body = try encoder.encode(request)
        } catch {
            throw LayaError.proto("Failed to encode Laya request: \(error.localizedDescription)")
        }

        let data = try await send(url: url, method: "POST", body: body, timeout: options.timeoutSeconds)

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(LayaResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            throw LayaError.proto("Failed to decode Laya response: \(error.localizedDescription) — body: \(snippet)")
        }
    }

    // MARK: Health

    /// Best-effort liveness probe. Returns nil when the server is not reachable.
    public func health(timeout: TimeInterval = 3) async -> LayaHealth? {
        guard let url = endpointURL(path: "/health") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONDecoder().decode(LayaHealth.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: Transport

    /// Builds the absolute endpoint URL by appending the path to the configured base URL.
    private func endpointURL(path: String) -> URL? {
        let base = options.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isBlank else { return nil }
        return URL(string: base + path)
    }

    /// Performs a request with retry and backoff, mapping transport and HTTP failures to `LayaError`.
    private func send(url: URL, method: String, body: Data?, timeout: Int) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = TimeInterval(timeout)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey = options.apiKey, !apiKey.isBlank {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                GhostLog.shared.warning("Laya network failure on attempt \(attempt): \(error.localizedDescription)")
                if attempt <= options.maxRetries {
                    try await backoff(attempt)
                    continue
                }
                let hint = "is the local Laya server running? (start it with macos/Scripts/start-laya.sh)"
                throw LayaError.serverUnavailable("\(error.localizedDescription) — \(hint)")
            }

            guard let http = response as? HTTPURLResponse else {
                throw LayaError.proto("Laya returned a non-HTTP response")
            }

            if (200..<300).contains(http.statusCode) {
                return data
            }

            let detail = Self.detail(from: data)

            if http.statusCode == 401 || http.statusCode == 403 {
                throw LayaError.auth(detail.isEmpty ? "invalid or missing bearer token" : detail, statusCode: http.statusCode)
            }

            if (400..<500).contains(http.statusCode) && http.statusCode != 429 {
                throw LayaError.proto("Laya rejected the request (HTTP \(http.statusCode)): \(detail)")
            }

            // 429 / 5xx are transient.
            if attempt <= options.maxRetries {
                GhostLog.shared.warning("Laya transient error HTTP \(http.statusCode); retrying \(attempt)/\(options.maxRetries)")
                try await backoff(attempt)
                continue
            }
            throw LayaError.transient(detail, statusCode: http.statusCode)
        }
    }

    /// Sleeps for an exponentially increasing delay with jitter before the next retry.
    private func backoff(_ attempt: Int) async throws {
        let baseMs = Int(pow(2.0, Double(attempt - 1)) * 500)
        let jitter = Int.random(in: 0..<250)
        try await Task.sleep(nanoseconds: UInt64(baseMs + jitter) * 1_000_000)
    }

    /// Extracts the server's `detail` error text, falling back to a short body snippet.
    private static func detail(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] {
            return String(describing: detail)
        }
        return String(data: data.prefix(400), encoding: .utf8) ?? ""
    }
}
