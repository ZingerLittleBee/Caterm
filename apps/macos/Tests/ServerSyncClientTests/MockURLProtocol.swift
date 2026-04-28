import Foundation

/// URLProtocol subclass that lets tests inject responses + assert on requests.
/// Install via `URLSessionConfiguration.protocolClasses = [MockURLProtocol.self]`.
final class MockURLProtocol: URLProtocol {
	typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
	static var handler: Handler?
	static var capturedRequests: [URLRequest] = []
	static var capturedBodies: [Data] = []

	static func reset() {
		handler = nil
		capturedRequests = []
		capturedBodies = []
	}

	override class func canInit(with _: URLRequest) -> Bool { true }
	override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
	override func stopLoading() {}

	override func startLoading() {
		Self.capturedRequests.append(request)
		// URLProtocol drops the httpBody on the wrapper; bodyStream is the
		// canonical place to find it after URLSession copies it through.
		if let stream = request.httpBodyStream {
			stream.open()
			defer { stream.close() }
			var data = Data()
			let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
			defer { buf.deallocate() }
			while stream.hasBytesAvailable {
				let n = stream.read(buf, maxLength: 4096)
				if n <= 0 { break }
				data.append(buf, count: n)
			}
			Self.capturedBodies.append(data)
		} else if let body = request.httpBody {
			Self.capturedBodies.append(body)
		} else {
			Self.capturedBodies.append(Data())
		}

		guard let handler = Self.handler else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
			return
		}
		do {
			let (resp, data) = try handler(request)
			client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}
}
