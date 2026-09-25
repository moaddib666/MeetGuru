import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport that keeps WebDAV verbs across redirects and can skip TLS verification.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let verifySSL: Bool
    private let credential: URLCredential?

    public init(verifySSL: Bool, username: String?, password: String?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        self.verifySSL = verifySSL
        if let username, let password {
            credential = URLCredential(user: username, password: password, persistence: .forSession)
        } else {
            credential = nil
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = TaskDelegate(verifySSL: verifySSL, credential: credential, original: request)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw CalDAVError.badResponse("Non-HTTP response")
        }
        return (data, http)
    }

    private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let verifySSL: Bool
        let credential: URLCredential?
        let original: URLRequest

        init(verifySSL: Bool, credential: URLCredential?, original: URLRequest) {
            self.verifySSL = verifySSL
            self.credential = credential
            self.original = original
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?)
        {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                if !verifySSL, let trust = challenge.protectionSpace.serverTrust {
                    return (.useCredential, URLCredential(trust: trust))
                }
                return (.performDefaultHandling, nil)
            case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
                if let credential, challenge.previousFailureCount == 0 {
                    return (.useCredential, credential)
                }
                return (.rejectProtectionSpace, nil)
            default:
                return (.performDefaultHandling, nil)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url else { return request }
            var redirected = original
            redirected.url = url
            if url.host?.lowercased() != original.url?.host?.lowercased() {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            return redirected
        }
    }
}
