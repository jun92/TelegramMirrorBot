import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Aria2Status: Codable, Sendable {
    public let gid: String
    public let status: String // active, waiting, paused, error, complete, removed
    public let totalLength: String
    public let completedLength: String
    public let downloadSpeed: String
    public let errorCode: String?
    public let errorMessage: String?
    public let files: [Aria2File]
    public let followedBy: [String]?
    
    public var totalSize: Int64 { Int64(totalLength) ?? 0 }
    public var completedSize: Int64 { Int64(completedLength) ?? 0 }
    public var speed: Int64 { Int64(downloadSpeed) ?? 0 }
    
    public var progress: Double {
        let total = totalSize
        guard total > 0 else { return 0.0 }
        return Double(completedSize) / Double(total)
    }
}

public struct Aria2File: Codable, Sendable {
    public let index: String
    public let path: String
    public let length: String
    public let completedLength: String
    public let selected: String
}

private struct RPCRequest<T: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: T
}

private struct RPCResponse<T: Decodable>: Decodable {
    let jsonrpc: String
    let id: String?
    let result: T?
    let error: RPCError?
}

public struct RPCError: Decodable, Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    
    public var description: String {
        return "RPC Error \(code): \(message)"
    }
}

public actor Aria2Client {
    private let rpcURL: URL
    private let secret: String?
    private let session: URLSession

    public init(rpcURL: URL, secret: String? = nil) {
        self.rpcURL = rpcURL
        self.secret = secret
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        self.session = URLSession(configuration: config)
    }
    
    private func sendRequest<P: Encodable, R: Decodable>(method: String, params: P) async throws -> R {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let rpcReq = RPCRequest(id: UUID().uuidString, method: method, params: params)
        request.httpBody = try JSONEncoder().encode(rpcReq)
        
        // Custom URLSession async support for Linux if needed,
        // but on Swift 5.5+ macOS/Linux, URLSession.shared.data(for:) is widely available.
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "Aria2Client", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP Request failed or status code is not 2xx"])
        }
        
        let rpcResp = try JSONDecoder().decode(RPCResponse<R>.self, from: data)
        if let error = rpcResp.error {
            throw error
        }
        
        guard let result = rpcResp.result else {
            throw NSError(domain: "Aria2Client", code: 2, userInfo: [NSLocalizedDescriptionKey: "No result or error returned from JSON-RPC"])
        }
        
        return result
    }
    
    // params helper
    private func buildParams(_ extraParams: [AnyEncodable]) -> [AnyEncodable] {
        var params: [AnyEncodable] = []
        if let secret = secret {
            params.append(AnyEncodable("token:\(secret)"))
        }
        params.append(contentsOf: extraParams)
        return params
    }
    
    /// Adds a magnet or torrent URI to aria2c.
    /// - Parameters:
    ///   - uri: The magnet or torrent file link.
    ///   - downloadDir: Optional custom download directory.
    /// - Returns: GID of the added download.
    public func addUri(_ uri: String, downloadDir: String? = nil) async throws -> String {
        var options: [String: String] = [:]
        if let dir = downloadDir {
            options["dir"] = dir
        }
        
        // params: [secret, [uri], options]
        let extra: [AnyEncodable] = [
            AnyEncodable([uri]),
            AnyEncodable(options)
        ]
        
        let result: String = try await sendRequest(method: "aria2.addUri", params: buildParams(extra))
        return result
    }
    
    /// Tells the status of the specified GID.
    /// - Parameter gid: The download GID.
    /// - Returns: Aria2Status containing status, speed, sizes, files etc.
    public func tellStatus(_ gid: String) async throws -> Aria2Status {
        let keys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "errorCode", "errorMessage", "files", "followedBy"]
        let extra: [AnyEncodable] = [
            AnyEncodable(gid),
            AnyEncodable(keys)
        ]
        
        return try await sendRequest(method: "aria2.tellStatus", params: buildParams(extra))
    }
    
    /// Removes (cancels) the download of the specified GID.
    /// - Parameter gid: The download GID.
    /// - Returns: The GID removed.
    public func remove(_ gid: String) async throws -> String {
        let extra: [AnyEncodable] = [AnyEncodable(gid)]
        return try await sendRequest(method: "aria2.remove", params: buildParams(extra))
    }
    
    /// Purges the finished/failed download results from memory.
    /// - Parameter gid: The download GID.
    /// - Returns: The result (usually "OK").
    public func purgeDownloadResult(_ gid: String) async throws -> String {
        let extra: [AnyEncodable] = [AnyEncodable(gid)]
        return try await sendRequest(method: "aria2.purgeDownloadResult", params: buildParams(extra))
    }
    
    /// Returns a list of active downloads.
    public func tellActive() async throws -> [Aria2Status] {
        let keys = ["gid", "status", "files"]
        let extra: [AnyEncodable] = [AnyEncodable(keys)]
        return try await sendRequest(method: "aria2.tellActive", params: buildParams(extra))
    }
    
    /// Returns a list of waiting or paused downloads.
    public func tellWaiting(offset: Int, num: Int) async throws -> [Aria2Status] {
        let keys = ["gid", "status", "files"]
        let extra: [AnyEncodable] = [
            AnyEncodable(offset),
            AnyEncodable(num),
            AnyEncodable(keys)
        ]
        return try await sendRequest(method: "aria2.tellWaiting", params: buildParams(extra))
    }
    
    /// Returns a list of stopped (completed or failed) downloads.
    public func tellStopped(offset: Int, num: Int) async throws -> [Aria2Status] {
        let keys = ["gid", "status", "files"]
        let extra: [AnyEncodable] = [
            AnyEncodable(offset),
            AnyEncodable(num),
            AnyEncodable(keys)
        ]
        return try await sendRequest(method: "aria2.tellStopped", params: buildParams(extra))
    }
    
    /// Changes global options dynamically.
    /// - Parameter options: Dictionary of option name to value.
    /// - Returns: "OK" on success.
    public func changeGlobalOption(_ options: [String: String]) async throws -> String {
        let extra: [AnyEncodable] = [AnyEncodable(options)]
        return try await sendRequest(method: "aria2.changeGlobalOption", params: buildParams(extra))
    }
}

// Helper struct to wrap heterogeneous array elements for JSON-RPC parameters.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void
    
    init<T: Encodable>(_ value: T) {
        self.encodeClosure = { encoder in
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
