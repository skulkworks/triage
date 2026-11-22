import Foundation

nonisolated enum GitHubError: LocalizedError, Sendable {
    case noToken
    case http(Int, String)
    case graphQL([String])
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noToken: "Not signed in to GitHub."
        case .http(let code, let message): "GitHub returned \(code): \(message)"
        case .graphQL(let messages): messages.joined(separator: "\n")
        case .decoding(let message): "Couldn't read GitHub's reply: \(message)"
        }
    }
}

/// The result of a conditional notifications poll.
nonisolated enum NotificationsPoll: Sendable {
    case notModified(pollInterval: Int)
    /// `complete` is false when the page cap stopped pagination early.
    case updated([GHNotification], lastModified: String?, pollInterval: Int, complete: Bool)
}

nonisolated struct RateLimit: Sendable {
    var remaining: Int
    var limit: Int
    var reset: Date
}

/// A thin REST + GraphQL client. No caching of its own: the store decides what to fetch.
nonisolated final class GitHubClient: Sendable {
    let token: String
    private let session: URLSession
    private let api = URL(string: "https://api.github.com")!

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "GitHub-Triage-macOS",
        ]
        session = URLSession(configuration: config)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func request(_ url: URL, method: String = "GET", accept: String? = nil, body: Data? = nil,
                         headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.http(0, "No response") }
        if http.statusCode >= 400 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError.http(http.statusCode, message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return (data, http)
    }

    // MARK: Notifications

    /// The whole inbox (read and unread, not done). `ifModifiedSince` makes an unchanged poll free.
    /// Without `is_done=false`, `all=true` also returns threads already marked done.
    func notifications(ifModifiedSince: String?, maxPages: Int = 40) async throws -> NotificationsPoll {
        var url: URL? = URL(string: "https://api.github.com/notifications?all=true&is_done=false&per_page=50")
        var all: [GHNotification] = []
        var lastModified: String?
        var interval = 60
        var page = 0
        while let next = url, page < maxPages {
            var headers: [String: String] = [:]
            if page == 0, let ifModifiedSince { headers["If-Modified-Since"] = ifModifiedSince }
            let (data, response) = try await session.data(for: request(next, headers: headers))
            guard let http = response as? HTTPURLResponse else { throw GitHubError.http(0, "No response") }
            interval = Int(http.value(forHTTPHeaderField: "X-Poll-Interval") ?? "") ?? interval
            if http.statusCode == 304 { return .notModified(pollInterval: interval) }
            if http.statusCode >= 400 {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                throw GitHubError.http(http.statusCode, message ?? "")
            }
            if page == 0 { lastModified = http.value(forHTTPHeaderField: "Last-Modified") }
            do {
                all += try Self.decoder.decode([GHNotification].self, from: data)
            } catch {
                throw GitHubError.decoding(String(describing: error))
            }
            url = Self.nextLink(http.value(forHTTPHeaderField: "Link"))
            page += 1
        }
        return .updated(all, lastModified: lastModified, pollInterval: interval, complete: url == nil)
    }

    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let bits = part.split(separator: ";")
            guard bits.count >= 2, bits[1].contains("rel=\"next\"") else { continue }
            let raw = bits[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }

    func markRead(thread id: String) async throws {
        _ = try await send(request(api.appending(path: "notifications/threads/\(id)"), method: "PATCH"))
    }

    /// GitHub's "Done": the thread leaves the inbox until something new happens on it.
    func markDone(thread id: String) async throws {
        _ = try await send(request(api.appending(path: "notifications/threads/\(id)"), method: "DELETE"))
    }

    /// Stop notifications for the thread (GitHub's "Unsubscribe").
    func unsubscribe(thread id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ignored": true])
        _ = try await send(request(api.appending(path: "notifications/threads/\(id)/subscription"), method: "PUT", body: body))
    }

    func markAllRead(before date: Date) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["last_read_at": ISO8601DateFormatter().string(from: date), "read": true])
        _ = try await send(request(api.appending(path: "notifications"), method: "PUT", body: body))
    }

    // MARK: REST objects

    func release(apiURL: String) async throws -> GHRelease {
        guard let url = URL(string: apiURL) else { throw GitHubError.http(0, "Bad URL") }
        let (data, _) = try await send(request(url, accept: "application/vnd.github.html+json"))
        return try Self.decoder.decode(GHRelease.self, from: data)
    }

    func rateLimit() async throws -> RateLimit {
        let (data, _) = try await send(request(api.appending(path: "rate_limit")))
        nonisolated struct R: Decodable { nonisolated struct C: Decodable { var limit: Int; var remaining: Int; var reset: Double }; var resources: [String: C] }
        let r = try JSONDecoder().decode(R.self, from: data)
        let core = r.resources["core"]
        return RateLimit(remaining: core?.remaining ?? 0, limit: core?.limit ?? 0, reset: Date(timeIntervalSince1970: core?.reset ?? 0))
    }

    // MARK: GraphQL

    func graphQL<T: Decodable & Sendable>(_ query: String, variables: [String: Any?] = [:], as: T.Type = T.self,
                                         allowPartial: Bool = false) async throws -> T {
        var vars: [String: Any] = [:]
        for (k, v) in variables { vars[k] = v ?? NSNull() }
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": vars])
        let (data, _) = try await send(request(api.appending(path: "graphql"), method: "POST", body: body))
        let decoded: GQLResponse<T>
        do {
            decoded = try Self.decoder.decode(GQLResponse<T>.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        if let errors = decoded.errors, !errors.isEmpty, !(allowPartial && decoded.data != nil) {
            throw GitHubError.graphQL(errors.map(\.message))
        }
        guard let value = decoded.data else { throw GitHubError.graphQL(["Empty response"]) }
        return value
    }

    /// For mutations, where only success matters.
    func mutate(_ query: String, variables: [String: Any?]) async throws {
        nonisolated struct Ignored: Decodable, Sendable {}
        _ = try await graphQL(query, variables: variables, as: Ignored.self)
    }
}
