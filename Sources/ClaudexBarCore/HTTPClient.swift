import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
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
        return HTTPResponse(data: data, statusCode: http.statusCode)
    }
}
