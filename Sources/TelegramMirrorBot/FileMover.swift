import Foundation

public actor FileMover {
    public init() {}
    
    private final class ProgressTracker: @unchecked Sendable {
        private let totalSize: Int64
        private let lock = NSLock()
        private var bytesCopied: Int64 = 0
        private let progressHandler: @Sendable (Double, Int64, Int64) async -> Void
        private var lastReportTime = Date()
        
        init(totalSize: Int64, progressHandler: @escaping @Sendable (Double, Int64, Int64) async -> Void) {
            self.totalSize = totalSize
            self.progressHandler = progressHandler
        }
        
        func incrementAndReport(by bytes: Int) async {
            let (fraction, currentBytes, total, shouldReport): (Double, Int64, Int64, Bool) = lock.withLock {
                self.bytesCopied += Int64(bytes)
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastReportTime)
                let isEOF = self.bytesCopied == self.totalSize
                let shouldReport = elapsed >= 3.0 || isEOF
                if shouldReport {
                    self.lastReportTime = now
                }
                let fraction = Double(self.bytesCopied) / Double(self.totalSize)
                return (fraction, self.bytesCopied, self.totalSize, shouldReport)
            }
            
            if shouldReport {
                await progressHandler(fraction, currentBytes, total)
            }
        }
        
        func reportFinal() async {
            let total = lock.withLock { self.totalSize }
            await progressHandler(1.0, total, total)
        }
        
        func reportEmpty() async {
            await progressHandler(1.0, 0, 0)
        }
    }
    
    /// Recursively calculates the size of a file or directory.
    public func calculateSize(at url: URL) throws -> Int64 {
        let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        
        if resourceValues.isRegularFile == true {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (fileAttributes[.size] as? Int64) ?? 0
        } else if resourceValues.isDirectory == true {
            var totalSize: Int64 = 0
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else {
                return 0
            }
            
            for case let fileURL as URL in enumerator {
                let rValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if rValues.isRegularFile == true {
                    totalSize += Int64(rValues.fileSize ?? 0)
                }
            }
            return totalSize
        }
        return 0
    }
    
    /// Resolves the actual file URL on the file system by checking NFC, NFD, and fuzzy name matching in parent directory.
    private func resolveActualURL(for url: URL) -> URL? {
        let fileManager = FileManager.default
        let path = url.path
        
        // 1. Direct check
        if fileManager.fileExists(atPath: path) {
            return url
        }
        
        // 2. NFC check (precomposed)
        let nfcPath = path.precomposedStringWithCanonicalMapping
        if fileManager.fileExists(atPath: nfcPath) {
            return URL(fileURLWithPath: nfcPath)
        }
        
        // 3. NFD check (decomposed)
        let nfdPath = path.decomposedStringWithCanonicalMapping
        if fileManager.fileExists(atPath: nfdPath) {
            return URL(fileURLWithPath: nfdPath)
        }
        
        // 4. Fuzzy match in parent directory
        let parentDir = url.deletingLastPathComponent()
        let targetName = url.lastPathComponent
        
        // Check if parent directory exists
        guard fileManager.fileExists(atPath: parentDir.path) else {
            return nil
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil, options: [])
            for itemURL in contents {
                let itemName = itemURL.lastPathComponent
                
                // Compare using canonical matching
                if itemName.precomposedStringWithCanonicalMapping == targetName.precomposedStringWithCanonicalMapping ||
                   itemName.decomposedStringWithCanonicalMapping == targetName.decomposedStringWithCanonicalMapping ||
                   itemName.localizedStandardCompare(targetName) == .orderedSame {
                    return itemURL
                }
            }
        } catch {
            print("Warning: Failed to list parent directory \(parentDir.path): \(error)")
        }
        
        return nil
    }
    
    private func copyFile(from src: URL, to dest: URL, tracker: ProgressTracker) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        guard let inputStream = InputStream(url: src) else {
            throw NSError(domain: "FileMover", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to open input stream for \(src.path)"])
        }
        guard let outputStream = OutputStream(url: dest, append: false) else {
            throw NSError(domain: "FileMover", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to open output stream for \(dest.path)"])
        }
        
        inputStream.open()
        outputStream.open()
        
        defer {
            inputStream.close()
            outputStream.close()
        }
        
        let bufferSize = 4 * 1024 * 1024 // 4MB Buffer
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        while inputStream.hasBytesAvailable {
            try Task.checkCancellation()
            
            let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                if let error = inputStream.streamError {
                    throw error
                }
                throw NSError(domain: "FileMover", code: 4, userInfo: [NSLocalizedDescriptionKey: "Stream read error"])
            }
            if bytesRead == 0 {
                break // EOF
            }
            
            var bytesWritten = 0
            while bytesWritten < bytesRead {
                let written = outputStream.write(Array(buffer[bytesWritten..<bytesRead]), maxLength: bytesRead - bytesWritten)
                if written < 0 {
                    if let error = outputStream.streamError {
                        throw error
                    }
                    throw NSError(domain: "FileMover", code: 5, userInfo: [NSLocalizedDescriptionKey: "Stream write error"])
                }
                bytesWritten += written
            }
            
            await tracker.incrementAndReport(by: bytesRead)
        }
    }
    
    /// Moves a file or directory from source to destination by copying block-by-block (to report progress) and then deleting the source.
    /// - Parameters:
    ///   - source: Source file or directory URL.
    ///   - destination: Target file or directory URL.
    ///   - progressHandler: Callback for reporting progress: (progressFraction: Double, copiedBytes: Int64, totalBytes: Int64).
    public func move(
        from source: URL,
        to destination: URL,
        progressHandler: @escaping @Sendable (Double, Int64, Int64) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        
        // Resolve actual path handling NFC/NFD discrepancies
        let resolvedSource = resolveActualURL(for: source) ?? source
        
        // Normalize target destination path to NFC (precomposed) for standardized path storage
        let normalizedDestPath = destination.path.precomposedStringWithCanonicalMapping
        let resolvedDestination = URL(fileURLWithPath: normalizedDestPath)
        
        guard fileManager.fileExists(atPath: resolvedSource.path) else {
            throw NSError(domain: "FileMover", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source path does not exist: \(resolvedSource.path)"])
        }
        
        let totalSize = try calculateSize(at: resolvedSource)
        let tracker = ProgressTracker(totalSize: totalSize, progressHandler: progressHandler)
        
        guard totalSize > 0 else {
            // Empty folder or 0-byte file: move instantly using FileManager
            if fileManager.fileExists(atPath: resolvedDestination.path) {
                try fileManager.removeItem(at: resolvedDestination)
            }
            try fileManager.createDirectory(at: resolvedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: resolvedSource, to: resolvedDestination)
            await tracker.reportEmpty()
            return
        }
        
        // Target directory preparation
        try fileManager.createDirectory(at: resolvedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        let resourceValues = try resolvedSource.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        
        if resourceValues.isRegularFile == true {
            try await copyFile(from: resolvedSource, to: resolvedDestination, tracker: tracker)
        } else if resourceValues.isDirectory == true {
            // Create destination root directory
            try fileManager.createDirectory(at: resolvedDestination, withIntermediateDirectories: true)
            
            guard let enumerator = fileManager.enumerator(at: resolvedSource, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
                throw NSError(domain: "FileMover", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create directory enumerator"])
            }
            
            while let srcFileURL = enumerator.nextObject() as? URL {
                let rValues = try srcFileURL.resourceValues(forKeys: [.isRegularFileKey] as Set<URLResourceKey>)
                if rValues.isRegularFile == true {
                    // Compute destination file path
                    let relativePath = String(srcFileURL.path.dropFirst(resolvedSource.path.count))
                    let destFileURL = resolvedDestination.appendingPathComponent(relativePath)
                    try await copyFile(from: srcFileURL, to: destFileURL, tracker: tracker)
                }
            }
        }
        
        // Report final progress
        await tracker.reportFinal()
        
        // Remove source after successful copy
        try fileManager.removeItem(at: resolvedSource)
    }
}
