import Foundation

public struct MirrorTask: Sendable {
    public enum Phase: String, Sendable {
        case pending
        case downloading
        case moving
        case completed
        case failed
        case cancelled
    }
    
    public let gid: String // Temporary UUID for pending, actual GID for downloading
    public let uri: String // Original magnet / link
    public let chatId: Int64
    public var messageId: Int // Changed to var to allow updating if fallback message is sent
    public var phase: Phase
    public var lastStatusText: String
    public var errorCount: Int = 0 // Track sequential failures
}

public actor MirrorDaemon {
    private let aria2: Aria2Client
    private let bot: TelegramBot
    private let mover: FileMover
    
    private let downloadDir: String
    private let destinationDir: String
    private let updateInterval: TimeInterval
    private let maxConcurrentDownloads: Int
    private let allowedChatId: Int64? // Optional restriction to a single Telegram Chat ID
    
    private var activeTasks: [String: MirrorTask] = [:]
    private var pendingQueue: [String] = [] // Queue of temporary task UUIDs
    private var isRunning: Bool = false
    
    public init(
        aria2: Aria2Client,
        bot: TelegramBot,
        downloadDir: String,
        destinationDir: String,
        updateInterval: TimeInterval = 3.0,
        maxConcurrentDownloads: Int = 3,
        allowedChatId: Int64? = nil
    ) {
        self.aria2 = aria2
        self.bot = bot
        self.mover = FileMover()
        self.downloadDir = downloadDir
        self.destinationDir = destinationDir
        self.updateInterval = updateInterval
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.allowedChatId = allowedChatId
    }
    
    /// Starts the daemon loop. This method blocks.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        
        // Clean up any lingering zombie tasks in aria2c session on startup
        await clearAllAria2Tasks()
        
        // Sync concurrent download limit to aria2 RPC option dynamically
        do {
            let options = ["max-concurrent-downloads": String(maxConcurrentDownloads)]
            _ = try await aria2.changeGlobalOption(options)
            print("Successfully synced max-concurrent-downloads (\(maxConcurrentDownloads)) to aria2 daemon.")
        } catch {
            print("Warning: Failed to sync max-concurrent-downloads option to aria2: \(error)")
        }
        
        print("Telegram Mirror Bot Daemon started.")
        print("Temp Download Dir: \(downloadDir)")
        print("Destination Dir: \(destinationDir)")
        
        // Start concurrent loops
        await withTaskGroup(of: Void.self) { group in
            // Loop 1: Poll Telegram Updates
            group.addTask {
                await self.pollTelegramUpdatesLoop()
            }
            // Loop 2: Monitor Downloads and Moving Processes
            group.addTask {
                await self.monitorDownloadsLoop()
            }
        }
    }
    
    // MARK: - Telegram Polling Loop
    
    private func pollTelegramUpdatesLoop() async {
        while isRunning {
            do {
                let updates = try await bot.getUpdates()
                for update in updates {
                    await handleUpdate(update)
                }
            } catch {
                print("Error polling Telegram updates: \(error)")
                try? await Task.sleep(nanoseconds: 5_000_000_000) // Sleep 5s on error
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // Small sleep between polls
        }
    }
    
    private func handleUpdate(_ update: TelegramUpdate) async {
        // Handle incoming messages
        if let message = update.message, let text = message.text {
            let chatId = message.chat.id
            
            // Check authorization if configured
            if let allowed = allowedChatId, allowed != chatId {
                print("Unauthorized access attempt from Chat ID: \(chatId)")
                return
            }
            
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("/start") {
                let welcome = """
                👋 Hello! This is the <b>Telegram Mirror Bot</b>.
                
                Send a magnet link or a torrent file URL to start downloading immediately.
                Progress will be updated in real-time, and completed files will be automatically moved to the destination directory.
                
                💡 <b>Available Commands:</b>
                /start - Start the bot and show help instructions
                /info - View current download progress, queue, and disk space details
                /init, /reset, /clear - Initialize the server (stop all active downloads and purge temp files)
                """
                let keyboard = ReplyKeyboardMarkup(keyboard: [
                    [KeyboardButton(text: "/info"), KeyboardButton(text: "/clear")]
                ])
                try? await bot.sendMessageWithReplyKeyboard(chatId: chatId, text: welcome, replyMarkup: keyboard)
                return
            }
            
            if trimmed.hasPrefix("/info") {
                await handleInfoCommand(chatId: chatId)
                return
            }
            
            if trimmed.hasPrefix("/init") || trimmed.hasPrefix("/reset") || trimmed.hasPrefix("/clear") {
                await handleResetCommand(chatId: chatId)
                return
            }
            
            // Validate if it's a magnet link or an HTTP(S) torrent link
            let isMagnet = trimmed.lowercased().hasPrefix("magnet:?")
            let isHttp = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            if isMagnet || isHttp {
                await handleNewDownloadRequest(uri: trimmed, chatId: chatId)
            } else {
                try? await bot.sendMessage(chatId: chatId, text: "❌ Please enter a valid magnet link or file download URL.")
            }
        }
        
        // Handle inline button callbacks (Cancellation)
        if let callback = update.callbackQuery, let data = callback.data {
            let queryId = callback.id
            if data.hasPrefix("cancel:") {
                let gid = String(data.dropFirst("cancel:".count))
                await handleCancelRequest(gid: gid, callbackQueryId: queryId)
            }
        }
    }
    
    private func handleNewDownloadRequest(uri: String, chatId: Int64) async {
        do {
            let downloadingCount = activeTasks.values.filter { $0.phase == .downloading }.count
            
            if downloadingCount < maxConcurrentDownloads {
                let initialMsg = try await bot.sendMessage(chatId: chatId, text: "⏳ Adding download request to aria2c daemon...")
                
                let gid = try await aria2.addUri(uri, downloadDir: downloadDir)
                
                // Check status immediately to get file name
                let status = try await aria2.tellStatus(gid)
                let fileName = getFileName(from: status)
                
                let startingText = """
                📥 <b>Download started:</b>
                
                📁 <b>File Name:</b> \(fileName.htmlEscaped)
                """
                
                let markup = InlineKeyboardMarkup(inlineKeyboard: [
                    [InlineKeyboardButton(text: "❌ Cancel", callbackData: "cancel:\(gid)")]
                ])
                
                try? await bot.editMessageText(chatId: chatId, messageId: initialMsg.messageId, text: startingText, replyMarkup: markup)
                
                activeTasks[gid] = MirrorTask(
                    gid: gid,
                    uri: uri,
                    chatId: chatId,
                    messageId: initialMsg.messageId,
                    phase: .downloading,
                    lastStatusText: startingText
                )
                print("Successfully added download task. GID: \(gid), File: \(fileName)")
            } else {
                let initialMsg = try await bot.sendMessage(chatId: chatId, text: "⏳ Adding to queue...")
                let tempId = "pending_" + UUID().uuidString
                let queuePos = pendingQueue.count + 1
                
                let nameLabel: String
                if uri.lowercased().hasPrefix("magnet:?") {
                    if let range = uri.range(of: "dn=") {
                        let sub = uri[range.upperBound...]
                        let rawName = sub.split(separator: "&").first ?? "Magnet Link"
                        nameLabel = String(rawName).removingPercentEncoding ?? "Magnet Link"
                    } else {
                        nameLabel = "Magnet Link"
                    }
                } else if let url = URL(string: uri) {
                    nameLabel = url.lastPathComponent
                } else {
                    nameLabel = "Unknown File"
                }
                
                let pendingText = """
                ⏳ <b>Download Pending...</b>
                
                📁 <b>File Name:</b> \(nameLabel.htmlEscaped)
                📋 <b>Queue Position:</b> #\(queuePos) in queue
                """
                
                let markup = InlineKeyboardMarkup(inlineKeyboard: [
                    [InlineKeyboardButton(text: "❌ Cancel", callbackData: "cancel:\(tempId)")]
                ])
                
                try? await bot.editMessageText(chatId: chatId, messageId: initialMsg.messageId, text: pendingText, replyMarkup: markup)
                
                activeTasks[tempId] = MirrorTask(
                    gid: tempId,
                    uri: uri,
                    chatId: chatId,
                    messageId: initialMsg.messageId,
                    phase: .pending,
                    lastStatusText: pendingText
                )
                pendingQueue.append(tempId)
                print("Download slot limit reached. Added task to pending queue. TempID: \(tempId), File: \(nameLabel)")
            }
            
        } catch {
            print("Failed to add download: \(error)")
            try? await bot.sendMessage(chatId: chatId, text: "❌ Failed to add download: \(error.localizedDescription)")
        }
    }
    
    private func handleCancelRequest(gid: String, callbackQueryId: String) async {
        guard var task = activeTasks[gid] else {
            try? await bot.answerCallbackQuery(callbackQueryId: callbackQueryId, text: "This task is already completed or cancelled.")
            return
        }
        
        if task.phase == .pending {
            // Remove from pendingQueue and activeTasks
            pendingQueue.removeAll { $0 == gid }
            activeTasks.removeValue(forKey: gid)
            
            let cancelledText = "❌ Cancelled while pending."
            _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: cancelledText, replyMarkup: nil)
            
            // Recalculate queue positions
            await updatePendingTasksQueuePositions()
            
            try? await bot.answerCallbackQuery(callbackQueryId: callbackQueryId, text: "Successfully cancelled from the queue.")
            print("Pending task cancelled by user. TempID: \(gid)")
            return
        }
        
        if task.phase == .downloading {
            await cleanupDownloadResources(gid: gid)
        }
        
        task.phase = .cancelled
        activeTasks[gid] = task
        
        let cancelledText = "❌ Download cancelled by user."
        _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: cancelledText, replyMarkup: nil)
        
        activeTasks.removeValue(forKey: gid)
        
        try? await bot.answerCallbackQuery(callbackQueryId: callbackQueryId, text: "Successfully cancelled.")
        print("Task cancelled by user. GID: \(gid)")
    }
    
    // MARK: - Monitoring & Moving Loop
    
    private func monitorDownloadsLoop() async {
        while isRunning {
            // 1. Promote pending tasks if slots are available
            await promotePendingTasks()
            
            // 2. Monitor active downloading tasks
            let tasks = activeTasks
            await withTaskGroup(of: Void.self) { group in
                for (_, task) in tasks {
                    if task.phase == .downloading {
                        group.addTask {
                            await self.updateDownloadProgress(task: task)
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(updateInterval * 1_000_000_000))
        }
    }
    
    private func promotePendingTasks() async {
        var downloadingCount = activeTasks.values.filter { $0.phase == .downloading }.count
        
        while downloadingCount < maxConcurrentDownloads && !pendingQueue.isEmpty {
            let tempId = pendingQueue.removeFirst()
            guard let task = activeTasks[tempId] else { continue }
            
            print("Promoting task \(tempId) from pending queue to active download.")
            
            do {
                // Remove Cancel button from the old pending message
                _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: "⏳ <b>Download Pending... (Started)</b>", replyMarkup: nil)
                
                let gid = try await aria2.addUri(task.uri, downloadDir: downloadDir)
                
                let status = try await aria2.tellStatus(gid)
                let fileName = getFileName(from: status)
                
                let startingText = """
                📥 <b>Download started:</b>
                
                📁 <b>File Name:</b> \(fileName.htmlEscaped)
                """
                
                let markup = InlineKeyboardMarkup(inlineKeyboard: [
                    [InlineKeyboardButton(text: "❌ Cancel", callbackData: "cancel:\(gid)")]
                ])
                
                let newMsgId: Int
                if let newMsg = try? await bot.sendMessage(chatId: task.chatId, text: startingText, replyMarkup: markup) {
                    newMsgId = newMsg.messageId
                } else {
                    newMsgId = task.messageId
                }
                
                let newTask = MirrorTask(
                    gid: gid,
                    uri: task.uri,
                    chatId: task.chatId,
                    messageId: newMsgId,
                    phase: .downloading,
                    lastStatusText: startingText
                )
                
                activeTasks.removeValue(forKey: tempId)
                activeTasks[gid] = newTask
                
                downloadingCount += 1
            } catch {
                print("Failed to promote task \(tempId): \(error)")
                let failText = "❌ Failed to start download from queue: \(error.localizedDescription)"
                _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: failText, replyMarkup: nil)
                activeTasks.removeValue(forKey: tempId)
            }
        }
        
        await updatePendingTasksQueuePositions()
    }
    
    private func updatePendingTasksQueuePositions() async {
        for (index, tempId) in pendingQueue.enumerated() {
            guard var task = activeTasks[tempId] else { continue }
            let queuePos = index + 1
            
            let nameLabel: String
            if task.uri.lowercased().hasPrefix("magnet:?") {
                if let range = task.uri.range(of: "dn=") {
                    let sub = task.uri[range.upperBound...]
                    let rawName = sub.split(separator: "&").first ?? "Magnet Link"
                    nameLabel = String(rawName).removingPercentEncoding ?? "Magnet Link"
                } else {
                    nameLabel = "Magnet Link"
                }
            } else if let url = URL(string: task.uri) {
                nameLabel = url.lastPathComponent
            } else {
                nameLabel = "Unknown File"
            }
            
            let pendingText = """
            ⏳ <b>Download Pending...</b>
            
            📁 <b>File Name:</b> \(nameLabel.htmlEscaped)
            📋 <b>Queue Position:</b> #\(queuePos) in queue
            """
            
            if pendingText != task.lastStatusText {
                let markup = InlineKeyboardMarkup(inlineKeyboard: [
                    [InlineKeyboardButton(text: "❌ Cancel", callbackData: "cancel:\(tempId)")]
                ])
                let newMsgId = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: pendingText, replyMarkup: markup)
                
                task.messageId = newMsgId
                task.lastStatusText = pendingText
                activeTasks[tempId] = task
            }
        }
    }
    
    private func updateDownloadProgress(task: MirrorTask) async {
        do {
            let status = try await aria2.tellStatus(task.gid)
            let state = status.status
            
            if state == "active" || state == "waiting" {
                let fileName = getFileName(from: status)
                let progress = status.progress
                let percent = String(format: "%.1f", progress * 100.0)
                print("Task \(task.gid) (\(fileName)) downloading: \(percent)%")
                
                if task.errorCount > 0 {
                    var updated = task
                    updated.errorCount = 0
                    activeTasks[task.gid] = updated
                }
                
            } else if state == "complete" {
                // Check if this is a metadata (torrent file) download completion that is followed by the actual file download.
                if let followedBy = status.followedBy, !followedBy.isEmpty, let newGid = followedBy.first {
                    print("Metadata download complete for GID: \(task.gid). Switching to actual download GID: \(newGid)")
                    
                    // CRITICAL: Replace mapping synchronously BEFORE any await calls to prevent duplicate re-entrant monitoring
                    let tempTask = MirrorTask(
                        gid: newGid,
                        uri: task.uri,
                        chatId: task.chatId,
                        messageId: task.messageId, // Temporarily map to old message ID
                        phase: .downloading,
                        lastStatusText: "📥 <b>Metadata parsed, starting actual download...</b>"
                    )
                    activeTasks.removeValue(forKey: task.gid)
                    activeTasks[newGid] = tempTask
                    
                    let targetChatId = task.chatId
                    let oldMsgId = task.messageId
                    let oldGid = task.gid
                    
                    // Perform async Telegram updates and Aria2 purging in a non-blocking background task
                    Task {
                        // Remove keyboard from the old message
                        _ = await self.safeEditMessage(chatId: targetChatId, messageId: oldMsgId, text: "📥 <b>Metadata parsed</b>", replyMarkup: nil)
                        
                        let newStatus = (try? await self.aria2.tellStatus(newGid)) ?? status
                        let fileName = self.getFileName(from: newStatus)
                        
                        let newText = """
                        📥 <b>Download started (Metadata parsed):</b>
                        
                        📁 <b>File Name:</b> \(fileName.htmlEscaped)
                        """
                        
                        let markup = InlineKeyboardMarkup(inlineKeyboard: [
                            [InlineKeyboardButton(text: "❌ Cancel", callbackData: "cancel:\(newGid)")]
                        ])
                        
                        let newMsgId: Int
                        if let newMsg = try? await self.bot.sendMessage(chatId: targetChatId, text: newText, replyMarkup: markup) {
                            newMsgId = newMsg.messageId
                        } else {
                            newMsgId = oldMsgId
                        }
                        
                        // Update task message ID and status text on the actor context safely
                        self.updateTaskAfterMetadataParsed(newGid: newGid, newMsgId: newMsgId, newText: newText)
                        
                        // Clean up metadata result in aria2 (async)
                        try? await self.aria2.purgeDownloadResult(oldGid)
                    }
                } else {
                    // Remove keyboard from the old message
                    _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: "📥 <b>Download started</b>", replyMarkup: nil)
                    
                    // CRITICAL: Update phase synchronously BEFORE calling the async handleDownloadComplete
                    var movingTask = task
                    movingTask.phase = .moving
                    activeTasks[task.gid] = movingTask
                    
                    // Hand-off to file moving phase in a non-blocking background task
                    Task {
                        await self.handleDownloadComplete(task: movingTask, status: status)
                    }
                }
                
            } else if state == "error" {
                let errMsg = status.errorMessage ?? "Unknown error"
                let errCode = status.errorCode ?? "-1"
                print("Aria2 download error for GID \(task.gid): (code \(errCode)) \(errMsg)")
                
                let text = "❌ An error occurred during download: (\(errCode)) \(errMsg.htmlEscaped)"
                _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: text, replyMarkup: nil)
                
                await cleanupDownloadResources(gid: task.gid, status: status)
                activeTasks.removeValue(forKey: task.gid)
            }
        } catch {
            print("Error updating status for GID \(task.gid): \(error)")
            var updated = task
            updated.errorCount += 1
            if updated.errorCount >= 5 {
                print("Task \(task.gid) failed consecutively 5 times. Pruning task to free slots.")
                let failText = "❌ Continuous query failures, forcing task termination: \(error.localizedDescription.htmlEscaped)"
                _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: failText, replyMarkup: nil)
                
                await cleanupDownloadResources(gid: task.gid)
                activeTasks.removeValue(forKey: task.gid)
            } else {
                activeTasks[task.gid] = updated
            }
        }
    }
    
    private func handleDownloadComplete(task: MirrorTask, status: Aria2Status) async {
        var updated = task
        updated.phase = .moving
        activeTasks[task.gid] = updated
        
        // Find the absolute local path of the completed download.
        // If there are multiple files, aria2c puts them in a folder or has paths.
        // We find the common prefix or the parent directory of the first file.
        guard let firstFile = status.files.first, !firstFile.path.isEmpty else {
            let failText = "❌ Completed file could not be found locally."
            _ = await safeEditMessage(chatId: task.chatId, messageId: task.messageId, text: failText, replyMarkup: nil)
            try? await aria2.purgeDownloadResult(task.gid)
            activeTasks.removeValue(forKey: task.gid)
            return
        }
        
        let sourcePath = firstFile.path
        let sourceURL = URL(fileURLWithPath: sourcePath)
        
        // Determine if it was a single file download or a multi-file folder download.
        // If the path contains the custom downloadDir and has subfolders, we want to locate
        // the top-most component that is inside our downloadDir.
        let resolvedSourceURL: URL
        let fileName: String
        
        let downloadDirURL = URL(fileURLWithPath: downloadDir).standardized
        let sourceStandardized = sourceURL.standardized
        
        let normalizedSourcePath = sourceStandardized.path.precomposedStringWithCanonicalMapping
        let normalizedDownloadDirPath = downloadDirURL.path.precomposedStringWithCanonicalMapping
        
        if normalizedSourcePath.hasPrefix(normalizedDownloadDirPath) {
            // Find the immediate child of downloadDirURL that contains the files
            let relativePath = String(normalizedSourcePath.dropFirst(normalizedDownloadDirPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = relativePath.split(separator: "/")
            if let firstComponent = components.first {
                resolvedSourceURL = downloadDirURL.appendingPathComponent(String(firstComponent))
                fileName = String(firstComponent)
            } else {
                resolvedSourceURL = sourceStandardized
                fileName = sourceStandardized.lastPathComponent
            }
        } else {
            resolvedSourceURL = sourceStandardized
            fileName = sourceStandardized.lastPathComponent
        }
        
        let targetURL = URL(fileURLWithPath: destinationDir).appendingPathComponent(fileName)
        
        print("Starting file move from \(resolvedSourceURL.path) to \(targetURL.path)")
        
        // 1. Send NEW message: Download Complete
        let downloadCompleteText = """
        📥 <b>Download complete:</b>
        
        📁 <b>File Name:</b> \(fileName.htmlEscaped)
        💾 <b>Total Size:</b> \(formatSize(status.totalSize))
        """
        _ = try? await bot.sendMessage(chatId: task.chatId, text: downloadCompleteText)
        
        // 2. Send NEW message: File Move Started
        let movingStartText = """
        🚚 <b>Moving file...</b>
        
        📁 <b>File Name:</b> \(fileName.htmlEscaped)
        """
        let newMsgId: Int
        if let newMsg = try? await bot.sendMessage(chatId: task.chatId, text: movingStartText) {
            newMsgId = newMsg.messageId
        } else {
            newMsgId = task.messageId
        }
        updated.messageId = newMsgId
        activeTasks[task.gid] = updated
        
        // We need to keep a reference to self or variables for task safety.
        let targetChatId = task.chatId
        let targetGid = task.gid
        
        // Start copying process
        do {
            try await mover.move(from: resolvedSourceURL, to: targetURL) { progress, copiedBytes, totalBytes in
                // No-op: Do not update progress on Telegram
            }
            
            // Completed successfully!
            let successText = """
            ✅ <b>Download & Move Complete!</b>
            
            📁 <b>File Name:</b> \(fileName.htmlEscaped)
            💾 <b>Total Size:</b> \(formatSize(status.totalSize))
            📍 <b>Save Path:</b> \(targetURL.path.htmlEscaped)
            """
            
            _ = try? await bot.sendMessage(chatId: targetChatId, text: successText)
            try? await aria2.purgeDownloadResult(targetGid)
            activeTasks.removeValue(forKey: targetGid)
            print("Task completed successfully. GID: \(targetGid)")
            
        } catch {
            print("Error moving file: \(error)")
            let failText = "❌ Error occurred while moving file: \(error.localizedDescription.htmlEscaped)"
            _ = try? await bot.sendMessage(chatId: targetChatId, text: failText)
            try? await aria2.purgeDownloadResult(targetGid)
            activeTasks.removeValue(forKey: targetGid)
        }
    }
    
    // MARK: - Format & Helper Utilities
    
    nonisolated private func getFileName(from status: Aria2Status) -> String {
        // Look at the files in the status. Often the first path holds the file/directory name
        if let file = status.files.first, !file.path.isEmpty {
            let fileURL = URL(fileURLWithPath: file.path)
            
            // If the path is under downloadDir, we find if there is a multi-file folder
            let downloadDirURL = URL(fileURLWithPath: downloadDir).standardized
            let fileURLStandardized = fileURL.standardized
            
            if fileURLStandardized.path.hasPrefix(downloadDirURL.path) {
                let relativePath = String(fileURLStandardized.path.dropFirst(downloadDirURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let components = relativePath.split(separator: "/")
                if let firstComponent = components.first {
                    return String(firstComponent)
                }
            }
            return fileURL.lastPathComponent
        }
        return "Unknown File"
    }
    
    nonisolated private func makeProgressBar(progress: Double, length: Int = 10) -> String {
        let filledCount = Int((progress.clamped(to: 0.0...1.0) * Double(length)).rounded())
        let emptyCount = length - filledCount
        return String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount)
    }
    
    nonisolated private func formatSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) Bytes"
        }
    }
    
    nonisolated private func formatSpeed(_ bytesPerSec: Int64) -> String {
        let kb = Double(bytesPerSec) / 1024.0
        let mb = kb / 1024.0
        
        if mb >= 1.0 {
            return String(format: "%.2f MB/s", mb)
        } else {
            return String(format: "%.2f KB/s", kb)
        }
    }
    
    nonisolated private func calculateETA(completed: Int64, total: Int64, speed: Int64) -> String {
        guard speed > 0 else { return "Infinite" }
        let remainingBytes = total - completed
        guard remainingBytes > 0 else { return "00:00:00" }
        
        let totalSeconds = Int(Double(remainingBytes) / Double(speed))
        
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    /// Cleans up all existing tasks in aria2 on startup to prevent ghost/zombie downloads and InfoHash registry errors.
    private func clearAllAria2Tasks() async {
        print("Initializing startup cleanup: Clearing all existing aria2 tasks...")
        
        var gidsToRemove: Set<String> = []
        
        if let active = try? await aria2.tellActive() {
            for task in active {
                gidsToRemove.insert(task.gid)
            }
        }
        
        if let waiting = try? await aria2.tellWaiting(offset: 0, num: 100) {
            for task in waiting {
                gidsToRemove.insert(task.gid)
            }
        }
        
        if let stopped = try? await aria2.tellStopped(offset: 0, num: 100) {
            for task in stopped {
                gidsToRemove.insert(task.gid)
            }
        }
        
        if !gidsToRemove.isEmpty {
            print("Found \(gidsToRemove.count) zombie tasks in aria2 on startup. Purging...")
            for gid in gidsToRemove {
                print("Purging zombie task GID: \(gid)")
                _ = try? await aria2.remove(gid)
                _ = try? await aria2.purgeDownloadResult(gid)
            }
        } else {
            print("No zombie tasks found in aria2 memory on startup.")
        }
        
        // Always clean up download directory on startup to ensure no orphaned files remain.
        clearDownloadDirectory()
        
        print("Startup cleanup finished.")
    }

    /// Safely clears all contents of the download directory.
    private func clearDownloadDirectory() {
        let fileManager = FileManager.default
        let downloadDirURL = URL(fileURLWithPath: downloadDir).standardized
        let destinationDirURL = URL(fileURLWithPath: destinationDir).standardized
        
        guard downloadDirURL.path.precomposedStringWithCanonicalMapping != destinationDirURL.path.precomposedStringWithCanonicalMapping else {
            print("Warning: downloadDir and destinationDir are the same path (\(downloadDir)). Skipping full directory wipe to prevent data loss.")
            return
        }
        
        print("Clearing download directory: \(downloadDirURL.path)...")
        do {
            let contents = try fileManager.contentsOfDirectory(at: downloadDirURL, includingPropertiesForKeys: nil, options: [])
            for itemURL in contents {
                try fileManager.removeItem(at: itemURL)
                print("Cleaned up leftover file/folder: \(itemURL.path)")
            }
            print("Download directory cleared.")
        } catch {
            print("Failed to clear download directory contents: \(error)")
        }
    }

    /// Handles explicit server initialization and cleanup requests from Telegram
    private func handleResetCommand(chatId: Int64) async {
        print("Reset command triggered by user from Chat ID: \(chatId)")
        
        do {
            let msg = try await bot.sendMessage(
                chatId: chatId,
                text: "🔄 <b>Starting server initialization...</b>\nStopping all active downloads and deleting temporary files."
            )
            
            // 1. Clear aria2 tasks
            var gidsToRemove: Set<String> = []
            if let active = try? await aria2.tellActive() {
                for task in active { gidsToRemove.insert(task.gid) }
            }
            if let waiting = try? await aria2.tellWaiting(offset: 0, num: 100) {
                for task in waiting { gidsToRemove.insert(task.gid) }
            }
            if let stopped = try? await aria2.tellStopped(offset: 0, num: 100) {
                for task in stopped { gidsToRemove.insert(task.gid) }
            }
            
            for gid in gidsToRemove {
                _ = try? await aria2.remove(gid)
                _ = try? await aria2.purgeDownloadResult(gid)
            }
            
            // 2. Clear bot local states
            activeTasks.removeAll()
            pendingQueue.removeAll()
            
            // 3. Clear download directory files
            clearDownloadDirectory()
            
            _ = try? await bot.editMessageText(
                chatId: chatId,
                messageId: msg.messageId,
                text: "✅ <b>Server initialization complete!</b>\nAll downloads and temp files have been cleared. You can now start new downloads."
            )
        } catch {
            print("Failed to execute reset command: \(error)")
            try? await bot.sendMessage(chatId: chatId, text: "❌ An error occurred during initialization: \(error.localizedDescription)")
        }
    }

    private func getFreeDiskSpace(at path: String) -> String {
        let fileManager = FileManager.default
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: path)
            if let freeBytes = attrs[.systemFreeSize] as? Int64,
               let totalBytes = attrs[.systemSize] as? Int64 {
                return "\(formatSize(freeBytes)) / \(formatSize(totalBytes)) available"
            }
        } catch {
            print("Failed to get disk space for \(path): \(error)")
        }
        return "Check failed"
    }

    private func handleInfoCommand(chatId: Int64) async {
        print("Info command triggered by user from Chat ID: \(chatId)")
        
        // 1. Get active downloading tasks info
        var activeLines: [String] = []
        let tasks = activeTasks
        
        let downloadingTasks = tasks.values.filter { $0.phase == .downloading }
        if downloadingTasks.isEmpty {
            activeLines.append("No downloads in progress.")
        } else {
            for task in downloadingTasks {
                if let status = try? await aria2.tellStatus(task.gid) {
                    let name = getFileName(from: status)
                    let progress = status.progress
                    let speed = status.speed
                    let total = status.totalSize
                    let completed = status.completedSize
                    
                    let bar = makeProgressBar(progress: progress, length: 8)
                    let pct = String(format: "%.1f", progress * 100.0)
                    activeLines.append("• <b>\(name.htmlEscaped)</b>\n  [\(bar)] \(pct)% (\(formatSize(completed))/\(formatSize(total))) | ⚡️ \(formatSpeed(speed))")
                } else {
                    activeLines.append("• GID: \(task.gid) (Waiting for status...)")
                }
            }
        }
        
        // 2. Get waiting tasks in queue
        var waitingLines: [String] = []
        if pendingQueue.isEmpty {
            waitingLines.append("No tasks in queue.")
        } else {
            for (index, tempId) in pendingQueue.enumerated() {
                guard let task = tasks[tempId] else { continue }
                let queuePos = index + 1
                let nameLabel: String
                if task.uri.lowercased().hasPrefix("magnet:?") {
                    if let range = task.uri.range(of: "dn=") {
                        let sub = task.uri[range.upperBound...]
                        let rawName = sub.split(separator: "&").first ?? "Magnet Link"
                        nameLabel = String(rawName).removingPercentEncoding ?? "Magnet Link"
                    } else {
                        nameLabel = "Magnet Link"
                    }
                } else if let url = URL(string: task.uri) {
                    nameLabel = url.lastPathComponent
                } else {
                    nameLabel = "Unknown File"
                }
                
                // Show first 5 tasks, group the rest
                if queuePos <= 5 {
                    waitingLines.append("\(queuePos). <b>\(nameLabel.htmlEscaped)</b>")
                } else if queuePos == 6 {
                    waitingLines.append("... and \(pendingQueue.count - 5) more waiting")
                    break
                }
            }
        }
        
        // 3. Get Disk Space
        let tempDisk = getFreeDiskSpace(at: downloadDir)
        let completedDisk = getFreeDiskSpace(at: destinationDir)
        
        let infoMessage = """
        ℹ️ <b>System & Mirror Status</b>
        
        📥 <b>Active Downloads (\(downloadingTasks.count)/\(maxConcurrentDownloads)):</b>
        \(activeLines.joined(separator: "\n\n"))
        
        ⏳ <b>Queue (Total \(pendingQueue.count)):</b>
        \(waitingLines.joined(separator: "\n"))
        
        💾 <b>Remaining Disk Space:</b>
        • Temp Folder (\(downloadDir)): \(tempDisk)
        • Destination Folder (\(destinationDir)): \(completedDisk)
        """
        
        try? await bot.sendMessage(chatId: chatId, text: infoMessage)
    }


    /// Cleans up local files (like .aria2 or torrent file) and calls aria2.remove/purge to ensure no ghost files or tasks remain.
    private func cleanupDownloadResources(gid: String, status: Aria2Status? = nil) async {
        // 1. Force removal from aria2 if it is still active/waiting
        let currentStatus: Aria2Status?
        if let status = status {
            currentStatus = status
        } else {
            currentStatus = try? await aria2.tellStatus(gid)
        }
        
        // Try to remove from aria2 queue (in case it is still active/paused/waiting)
        if let s = currentStatus {
            let state = s.status
            if state == "active" || state == "waiting" || state == "paused" {
                _ = try? await aria2.remove(gid)
            }
        } else {
            // Fallback: try removing anyway just in case
            _ = try? await aria2.remove(gid)
        }
        
        // Purge memory result in aria2
        _ = try? await aria2.purgeDownloadResult(gid)
        
        // 2. Clean up disk files (.aria2 and partial downloads)
        let fileManager = FileManager.default
        
        if let s = currentStatus {
            for file in s.files {
                let filePath = file.path
                guard !filePath.isEmpty else { continue }
                
                // Delete the main partial file (if exists)
                let fileURL = URL(fileURLWithPath: filePath)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try? fileManager.removeItem(at: fileURL)
                    print("Cleaned up incomplete file: \(fileURL.path)")
                }
                
                // Delete the .aria2 control file
                let aria2ControlURL = URL(fileURLWithPath: filePath + ".aria2")
                if fileManager.fileExists(atPath: aria2ControlURL.path) {
                    try? fileManager.removeItem(at: aria2ControlURL)
                    print("Cleaned up aria2 control file: \(aria2ControlURL.path)")
                }
            }
        }
        
        // 3. Clean up related torrent/meta files and any files containing GID in the downloadDir (always attempt)
        let downloadDirURL = URL(fileURLWithPath: downloadDir).standardized
        if let contents = try? fileManager.contentsOfDirectory(at: downloadDirURL, includingPropertiesForKeys: nil, options: []) {
            for itemURL in contents {
                let name = itemURL.lastPathComponent
                if name.contains(gid) {
                    try? fileManager.removeItem(at: itemURL)
                    print("Cleaned up leftover GID file: \(itemURL.path)")
                }
            }
        }
    }

    /// Safely edits a Telegram message. If edit fails (e.g. message deleted), fallbacks to sending a new message.
    private func safeEditMessage(
        chatId: Int64,
        messageId: Int,
        text: String,
        replyMarkup: InlineKeyboardMarkup? = nil
    ) async -> Int {
        do {
            let msg = try await bot.editMessageText(
                chatId: chatId,
                messageId: messageId,
                text: text,
                replyMarkup: replyMarkup
            )
            return msg.messageId
        } catch {
            let errStr = "\(error)"
            if errStr.contains("message is not modified") {
                return messageId
            }
            print("Warning: Failed to edit Telegram message \(messageId), sending fallback new message: \(error)")
            do {
                let msg = try await bot.sendMessage(
                    chatId: chatId,
                    text: text,
                    replyMarkup: replyMarkup
                )
                return msg.messageId
            } catch {
                print("Critical Error: Failed to send fallback message: \(error)")
                return messageId // Return original if both fail
            }
        }
    }
    
    private func updateTaskMessageId(gid: String, messageId: Int) {
        if var task = activeTasks[gid] {
            task.messageId = messageId
            activeTasks[gid] = task
        }
    }
    
    private func updateTaskAfterMetadataParsed(newGid: String, newMsgId: Int, newText: String) {
        if var task = activeTasks[newGid] {
            task.messageId = newMsgId
            task.lastStatusText = newText
            activeTasks[newGid] = task
        }
    }
    
    private func getLatestMessageId(for gid: String) -> Int? {
        return activeTasks[gid]?.messageId
    }
}

// Extension to clamp a Comparable value (like progress double)
extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension String {
    var htmlEscaped: String {
        return self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
