import Foundation
import JavaScriptCore

/// Some sites answer an https request with a redirect to plain http
/// (fanfox.net does). iOS refuses plain http, and so do we: the redirect is
/// followed on https instead.
final class RedirectUpgrader: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let url = request.url, url.scheme?.lowercased() == "http", let upgraded = SourceRuntime.secure(url) {
            next.url = upgraded
        }
        completionHandler(next)
    }
}

struct SourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs ONE extension inside its own JavaScript context.
///
/// Security model: the extension is untrusted third-party code. A fresh
/// JSContext has no file, network or timer APIs at all. The only things the
/// extension can reach are the functions on the `__host` object created below
/// (the "bridge"), and those only do: HTTPS requests, this source's own
/// cookies, this source's own settings file, timers and logging.
///
/// Threading: everything that touches the context runs on `queue` (serial).
/// Network callbacks hop back onto `queue` before calling into JavaScript.
/// That queue is what makes sharing an instance between threads safe, hence
/// `@unchecked Sendable` (the compiler cannot see the queue discipline).
final class SourceRuntime: @unchecked Sendable {
    let sourceId: String

    private let queue: DispatchQueue
    private let session: URLSession
    private let stateURL: URL
    private var context: JSContext!
    private var loadError: String?
    private var lastException: String?
    private var timers: [Int: JSValue] = [:]
    private var nextTimer = 1
    private var state: [String: String] = [:]

    /// A finished GET response, kept for a few seconds (see `fetch`).
    private struct Recent {
        let time: Date
        let status: Int
        let headers: [String: String]
        let data: Data
        let binary: Bool
    }
    private var recent: [String: Recent] = [:]
    private static let recentLifetime: TimeInterval = 5

    private let counterLock = NSLock()
    private var requests = 0
    /// Number of network requests this source has made. Shown while a slow
    /// source is working, so the wait does not look like a freeze.
    var requestCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return requests
    }

    init(sourceId: String, bundleURL: URL, stateURL: URL) {
        self.sourceId = sourceId
        self.stateURL = stateURL
        self.queue = DispatchQueue(label: "kumo.source.\(sourceId)")

        // Each source gets its own URLSession with its own cookie jar, so one
        // source can never see another source's cookies.
        // (In-memory for now; persistence comes with the verification flow.)
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: RedirectUpgrader(), delegateQueue: nil)

        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            state = saved
        }
        // Loading a bundle parses several hundred KB of JavaScript, so do it
        // off the main thread. Calls made meanwhile simply wait in the queue.
        queue.async { self.setUp(bundleURL: bundleURL) }
    }

    // MARK: - Setup

    private func setUp(bundleURL: URL) {
        let started = Date()
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            loadError = "Could not create a JavaScript context"
            return
        }
        context = ctx
        ctx.name = "source:\(sourceId)"
        let id = sourceId
        ctx.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown JavaScript error"
            self?.lastException = message
            Log.error("[\(id)] JS exception: \(message)")
        }

        installBridge(in: ctx)

        guard let preludeURL = Bundle.main.url(forResource: "prelude", withExtension: "js"),
              let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
            loadError = "prelude.js is missing from the app"
            return
        }
        lastException = nil
        ctx.evaluateScript(prelude, withSourceURL: preludeURL)
        if let e = lastException { loadError = "Runtime failed to start: \(e)"; return }

        guard let code = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            loadError = "The source file could not be read. Remove the source and install it again."
            return
        }
        ctx.evaluateScript(code, withSourceURL: bundleURL)
        if let e = lastException { loadError = "The source failed to load: \(e)"; return }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.info("[\(id)] loaded \(code.utf8.count / 1024) KB in \(ms) ms")
    }

    private func installBridge(in ctx: JSContext) {
        guard let host = JSValue(newObjectIn: ctx) else { return }
        let id = sourceId

        let log: @convention(block) (String, String) -> Void = { level, message in
            Log.shared.add(level, "[\(id)] \(message)")
        }
        host.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)

        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in
            guard let self = self else { return 0 }
            let timer = self.nextTimer
            self.nextTimer += 1
            self.timers[timer] = fn
            let delay = ms.isFinite ? Int(max(0, min(ms, 600_000))) : 0
            self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let fn = self?.timers.removeValue(forKey: timer) else { return }
                fn.call(withArguments: [])
            }
            return timer
        }
        host.setObject(unsafeBitCast(setTimeout, to: AnyObject.self), forKeyedSubscript: "setTimeout" as NSString)

        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] timer in
            self?.timers.removeValue(forKey: timer)
        }
        host.setObject(unsafeBitCast(clearTimeout, to: AnyObject.self), forKeyedSubscript: "clearTimeout" as NSString)

        let userAgent: @convention(block) () -> String = { AppEnvironment.userAgent }
        host.setObject(unsafeBitCast(userAgent, to: AnyObject.self), forKeyedSubscript: "userAgent" as NSString)

        let fetch: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] request, resolve, reject in
            self?.fetch(request, resolve: resolve, reject: reject)
        }
        host.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)

        let cookiesGet: @convention(block) () -> [[String: Any]] = { [weak self] in
            let cookies = self?.session.configuration.httpCookieStorage?.cookies ?? []
            return cookies.map { c in
                var domain = c.domain
                if domain.hasPrefix(".") { domain.removeFirst() }
                let expires: Any = c.expiresDate.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()
                return ["name": c.name, "value": c.value, "domain": domain, "path": c.path, "expires": expires]
            }
        }
        host.setObject(unsafeBitCast(cookiesGet, to: AnyObject.self), forKeyedSubscript: "cookiesGet" as NSString)

        let cookieSet: @convention(block) (JSValue) -> Void = { [weak self] cookie in
            guard let name = cookie.forProperty("name")?.toString(),
                  let value = cookie.forProperty("value")?.toString(),
                  let domain = cookie.forProperty("domain")?.toString() else { return }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain,
                .path: cookie.forProperty("path")?.toString() ?? "/",
                .secure: "TRUE"
            ]
            if let expires = cookie.forProperty("expires"), expires.isNumber {
                props[.expires] = Date(timeIntervalSince1970: expires.toDouble() / 1000)
            }
            if let made = HTTPCookie(properties: props) {
                self?.session.configuration.httpCookieStorage?.setCookie(made)
            }
        }
        host.setObject(unsafeBitCast(cookieSet, to: AnyObject.self), forKeyedSubscript: "cookieSet" as NSString)

        let cookieRemove: @convention(block) (JSValue) -> Void = { [weak self] cookie in
            guard let storage = self?.session.configuration.httpCookieStorage,
                  let name = cookie.forProperty("name")?.toString(),
                  let domain = cookie.forProperty("domain")?.toString() else { return }
            for c in storage.cookies ?? [] where c.name == name && c.domain.hasSuffix(domain) {
                storage.deleteCookie(c)
            }
        }
        host.setObject(unsafeBitCast(cookieRemove, to: AnyObject.self), forKeyedSubscript: "cookieRemove" as NSString)

        let stateGet: @convention(block) (String) -> Any = { [weak self] key in
            guard let self = self, let value = self.state[key] else { return NSNull() }
            return value
        }
        host.setObject(unsafeBitCast(stateGet, to: AnyObject.self), forKeyedSubscript: "stateGet" as NSString)

        let stateSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, json in
            guard let self = self else { return }
            if json.isString { self.state[key] = json.toString() } else { self.state.removeValue(forKey: key) }
            if let data = try? JSONEncoder().encode(self.state) {
                try? data.write(to: self.stateURL, options: .atomic)
            }
        }
        host.setObject(unsafeBitCast(stateSet, to: AnyObject.self), forKeyedSubscript: "stateSet" as NSString)

        let event: @convention(block) (String, JSValue) -> Void = { name, payload in
            let detail = payload.isObject ? (payload.toDictionary().map { "\($0)" } ?? "") : ""
            Log.warn("[\(id)] event \(name) \(detail)")
        }
        host.setObject(unsafeBitCast(event, to: AnyObject.self), forKeyedSubscript: "event" as NSString)

        ctx.setObject(host, forKeyedSubscript: "__host" as NSString)
    }

    // MARK: - Network bridge

    /// URL(string:) on iOS 15 rejects characters such as `[` and `]` that
    /// sites commonly use in query strings, so escape only what is illegal.
    private static let urlAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'()*+,-./:;=?@_~")
        set.formUnion(.alphanumerics)
        return set
    }()

    private static func lenientURL(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        guard let escaped = string.addingPercentEncoding(withAllowedCharacters: urlAllowed) else { return nil }
        return URL(string: escaped)
    }

    /// Returns the https form of an address, or nil if it is neither http nor https.
    static func secure(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http":
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.scheme = "https"
            return parts.url
        default: return nil
        }
    }

    private func fetch(_ req: JSValue, resolve: JSValue, reject: JSValue) {
        guard let urlString = req.forProperty("url")?.toString(),
              let parsed = SourceRuntime.lenientURL(urlString) else {
            reject.call(withArguments: ["Invalid URL"])
            return
        }
        // HTTPS only. A plain http:// address is upgraded to https:// (never
        // the other way round); anything else is refused.
        guard let url = SourceRuntime.secure(parsed) else {
            reject.call(withArguments: ["Blocked non-HTTPS request to \(urlString)"])
            return
        }
        var request = URLRequest(url: url)
        if let method = req.forProperty("method"), method.isString { request.httpMethod = method.toString() }
        let timeout = req.forProperty("timeoutMs")?.toDouble() ?? 20_000
        request.timeoutInterval = max(1, min(120, (timeout.isFinite ? timeout : 20_000) / 1000))
        if let headers = req.forProperty("headers"), headers.isObject, let dict = headers.toDictionary() {
            for (key, value) in dict { request.setValue("\(value)", forHTTPHeaderField: "\(key)") }
        }
        if let body = req.forProperty("body") {
            if body.isString {
                request.httpBody = body.toString().data(using: .utf8)
            } else if body.isObject, let bytes = data(fromTypedArray: body) {
                request.httpBody = bytes
            }
        }

        // Identical GET requests made within a few seconds are answered from
        // memory. Some sources ask for the very same address several times in
        // a row (MangaFox does, for every page); this saves a third of its
        // requests and is kinder to the site.
        var recentKey: String?
        if request.httpMethod == "GET", request.httpBody == nil {
            let headerText = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            let key = url.absoluteString + "|" + headerText
            recentKey = key
            if let hit = recent[key], Date().timeIntervalSince(hit.time) < SourceRuntime.recentLifetime,
               let ctx = context, let result = makeResult(hit, in: ctx) {
                resolve.call(withArguments: [result])
                return
            }
        }
        counterLock.lock()
        requests += 1
        counterLock.unlock()

        let host = url.host ?? ""
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    // TLS and connection problems end up here, with iOS's own wording.
                    let ns = error as NSError
                    reject.call(withArguments: ["\(error.localizedDescription) [\(ns.domain) \(ns.code)] (\(host))"])
                    return
                }
                guard let http = response as? HTTPURLResponse, let ctx = self.context else {
                    reject.call(withArguments: ["No HTTP response from \(host)"])
                    return
                }
                let data = data ?? Data()
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
                let type = headers["content-type"] ?? ""
                // Images stay bytes only; decoding megabytes of binary as text wastes memory.
                let binary = type.hasPrefix("image/") || type.contains("octet-stream")
                let answer = Recent(time: Date(), status: http.statusCode, headers: headers, data: data, binary: binary)
                // Only small successful text answers are remembered.
                if let key = recentKey, !binary, http.statusCode == 200, data.count < 300_000 {
                    let now = Date()
                    self.recent = self.recent.filter { now.timeIntervalSince($0.value.time) < SourceRuntime.recentLifetime }
                    self.recent[key] = answer
                }
                guard let result = self.makeResult(answer, in: ctx) else { return }
                resolve.call(withArguments: [result])
            }
        }
        task.resume()
    }

    /// Builds the object handed back to JavaScript for one response.
    private func makeResult(_ answer: Recent, in ctx: JSContext) -> JSValue? {
        guard let result = JSValue(newObjectIn: ctx) else { return nil }
        result.setObject(answer.status, forKeyedSubscript: "status" as NSString)
        result.setObject(answer.headers, forKeyedSubscript: "headers" as NSString)
        result.setObject(answer.binary ? "" : String(decoding: answer.data, as: UTF8.self), forKeyedSubscript: "text" as NSString)
        result.setObject(makeArrayBuffer(answer.data, in: ctx), forKeyedSubscript: "bytes" as NSString)
        return result
    }

    /// Copies `data` into a JavaScript ArrayBuffer. JavaScriptCore frees the
    /// memory itself when the buffer is garbage collected.
    private func makeArrayBuffer(_ data: Data, in ctx: JSContext) -> JSValue {
        let count = data.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
        if count > 0 { data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count) }
        let ref = JSObjectMakeArrayBufferWithBytesNoCopy(ctx.jsGlobalContextRef, pointer, count, { bytes, _ in
            bytes?.deallocate()
        }, nil, nil)
        return JSValue(jsValueRef: ref, in: ctx)
    }

    /// Reads the bytes of a Uint8Array / ArrayBuffer coming from JavaScript.
    private func data(fromTypedArray value: JSValue) -> Data? {
        guard let ctx = context else { return nil }
        let c = ctx.jsGlobalContextRef
        let type = JSValueGetTypedArrayType(c, value.jsValueRef, nil)
        guard type != kJSTypedArrayTypeNone, let object = JSValueToObject(c, value.jsValueRef, nil) else { return nil }
        if type == kJSTypedArrayTypeArrayBuffer {
            let length = JSObjectGetArrayBufferByteLength(c, object, nil)
            guard length > 0, let pointer = JSObjectGetArrayBufferBytesPtr(c, object, nil) else { return Data() }
            return Data(bytes: pointer, count: length)
        }
        let length = JSObjectGetTypedArrayByteLength(c, object, nil)
        let offset = JSObjectGetTypedArrayByteOffset(c, object, nil)
        guard length > 0, let pointer = JSObjectGetTypedArrayBytesPtr(c, object, nil) else { return Data() }
        return Data(bytes: pointer + offset, count: length)
    }

    // MARK: - Calling the source

    /// Resumes a continuation exactly once, whichever of
    /// success / failure / timeout happens first.
    private final class Once<T> {
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func finish(_ result: Result<T, Error>) {
            guard let c = continuation else { return }
            continuation = nil
            c.resume(with: result)
        }
    }

    /// Calls a method of the source and returns its result as JSON data.
    /// `onSection` receives each home section as it arrives.
    /// `timeout` is how long to wait before giving up, in seconds.
    func callRaw(_ method: String, _ args: [Any] = [], timeout: Int = 90, onSection: ((Data) -> Void)? = nil) async throws -> Data {
        let id = sourceId
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                let once = Once(continuation)
                if let e = self.loadError { once.finish(.failure(SourceError(message: e))); return }
                guard let ctx = self.context, let pb = ctx.objectForKeyedSubscript("__pb"), pb.isObject else {
                    once.finish(.failure(SourceError(message: "The source runtime is not available")))
                    return
                }
                let resolve: @convention(block) (String) -> Void = { json in
                    once.finish(.success(Data(json.utf8)))
                }
                let reject: @convention(block) (String) -> Void = { message in
                    Log.error("[\(id)] \(method) failed: \(message)")
                    once.finish(.failure(SourceError(message: message)))
                }
                let section: @convention(block) (String) -> Void = { json in
                    onSection?(Data(json.utf8))
                }
                let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("[]".utf8)
                let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
                pb.invokeMethod("call", withArguments: [
                    id, method, argsJSON,
                    unsafeBitCast(resolve, to: AnyObject.self),
                    unsafeBitCast(reject, to: AnyObject.self),
                    unsafeBitCast(section, to: AnyObject.self)
                ])
                self.queue.asyncAfter(deadline: .now() + .seconds(timeout)) {
                    once.finish(.failure(SourceError(message: "\(method) did not finish within \(timeout) seconds")))
                }
            }
        }
    }

    /// Calls a method and decodes the JSON result.
    func call<T: Decodable>(_ type: T.Type, _ method: String, _ args: [Any] = [], timeout: Int = 90) async throws -> T {
        let data = try await callRaw(method, args, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.error("[\(sourceId)] \(method) returned data in an unexpected shape: \(error)")
            throw SourceError(message: "\(method) returned data the app could not read. Details are in the Log tab.")
        }
    }

    /// Downloads one image THROUGH the source's request manager, so its
    /// interceptors run (referer header, un-scrambling, decryption).
    func imageData(url: String) async throws -> Data {
        let id = sourceId
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                let once = Once(continuation)
                if let e = self.loadError { once.finish(.failure(SourceError(message: e))); return }
                guard let ctx = self.context, let pb = ctx.objectForKeyedSubscript("__pb"), pb.isObject else {
                    once.finish(.failure(SourceError(message: "The source runtime is not available")))
                    return
                }
                let resolve: @convention(block) (JSValue) -> Void = { [weak self] result in
                    let status = Int(result.forProperty("status")?.toInt32() ?? 0)
                    guard status == 200 else {
                        once.finish(.failure(SourceError(message: "Image request returned HTTP \(status)")))
                        return
                    }
                    guard let bytes = result.forProperty("bytes"),
                          let data = self?.data(fromTypedArray: bytes), !data.isEmpty else {
                        once.finish(.failure(SourceError(message: "Image response was empty")))
                        return
                    }
                    once.finish(.success(data))
                }
                let reject: @convention(block) (String) -> Void = { message in
                    Log.error("[\(id)] image failed: \(message)")
                    once.finish(.failure(SourceError(message: message)))
                }
                pb.invokeMethod("image", withArguments: [
                    id, url,
                    unsafeBitCast(resolve, to: AnyObject.self),
                    unsafeBitCast(reject, to: AnyObject.self)
                ])
                self.queue.asyncAfter(deadline: .now() + 60) {
                    once.finish(.failure(SourceError(message: "Image did not load within 60 seconds")))
                }
            }
        }
    }
}
