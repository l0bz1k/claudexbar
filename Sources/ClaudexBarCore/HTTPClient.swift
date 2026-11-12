import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    /// The server's `Retry-After`, in seconds from now, when it sent one.
    public let retryAfter: TimeInterval?

    public init(data: Data, statusCode: Int, retryAfter: TimeInterval? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

public enum RetryAfter {
    /// `Retry-After` is either delay-seconds ("120") or an HTTP date.
    public static func parse(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// The last 429's `Retry-After`, kept by a provider for the app to read.
public final class RetryAfterMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval?

    public init() {}

    public func set(_ value: TimeInterval?) { lock.withLock { self.value = value } }
    public var current: TimeInterval? { lock.withLock { value } }
}

public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}

extension URLSession {
    /// The one session every ClaudexBar network call goes through.
    ///
    /// Ephemeral, with no URL cache: every request here carries a bearer token
    /// and returns live, per-account usage data, so there is nothing worth
    /// caching and plenty worth *not* writing to disk. (`URLSession.shared`
    /// persists responses to an on-disk SQLite `Cache.db`; once that file got
    /// corrupted it produced three error lines in the log on every single poll,
    /// indefinitely.)
    public static let claudexbar: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .claudexbar) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network
        }
        return HTTPResponse(data: data, statusCode: http.statusCode,
                            retryAfter: RetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After")))
    }
}
