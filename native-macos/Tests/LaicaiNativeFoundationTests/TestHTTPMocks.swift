import XCTest
@testable import LaicaiNativeFoundation
@testable import LaicaiNativeDomain

@MainActor
extension LaicaiNativeFoundationTestCase {
    func makeStubbedSession(body: Data, statusCode: Int = 200) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        MockURLProtocol.errorProvider = nil
        return URLSession(configuration: configuration)
    }

    func makeStubbedSession(
        responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = responder
        MockURLProtocol.errorProvider = nil
        return URLSession(configuration: configuration)
    }

    func makeStubbedSession(
        responder: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.responseProvider = nil
        MockURLProtocol.errorProvider = responder
        return URLSession(configuration: configuration)
    }
}

final class MockURLProtocol: URLProtocol {
    static var responseProvider: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var errorProvider: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let provider = Self.errorProvider {
            do {
                let (response, data) = try provider(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = provider(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
