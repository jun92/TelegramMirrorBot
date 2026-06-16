import Foundation

@main
struct TelegramMirrorBot {
    static func main() async {
        print("Starting Telegram Mirror Bot Daemon...")
        
        let env = ProcessInfo.processInfo.environment
        
        // 1. Get Telegram Token
        guard let telegramToken = env["TELEGRAM_BOT_TOKEN"], !telegramToken.isEmpty else {
            print("ERROR: TELEGRAM_BOT_TOKEN environment variable is required.")
            exit(1)
        }
        
        // 2. Get Allowed Chat ID (Optional)
        var allowedChatId: Int64? = nil
        if let chatIdStr = env["TELEGRAM_ALLOWED_CHAT_ID"], let chatId = Int64(chatIdStr) {
            allowedChatId = chatId
            print("Access restricted to Telegram Chat ID: \(chatId)")
        } else {
            print("Access: Public (No TELEGRAM_ALLOWED_CHAT_ID specified)")
        }
        
        // 3. Get Aria2 RPC URL
        let rpcUrlString = env["ARIA2_RPC_URL"] ?? "http://127.0.0.1:6800/jsonrpc"
        guard let rpcURL = URL(string: rpcUrlString) else {
            print("ERROR: Invalid ARIA2_RPC_URL format: \(rpcUrlString)")
            exit(1)
        }
        print("Connecting to aria2c RPC: \(rpcUrlString)")
        
        // 4. Get Aria2 Secret
        let rpcSecret = env["ARIA2_RPC_SECRET"]
        if rpcSecret != nil {
            print("Using aria2c RPC Secret: [REDACTED]")
        } else {
            print("No aria2c RPC Secret provided.")
        }
        
        // 5. Get Dirs
        let downloadDir = env["DOWNLOAD_DIR"] ?? "/downloads/temp"
        let destinationDir = env["DESTINATION_DIR"] ?? "/downloads/completed"
        
        // 6. Get Update Interval
        let updateIntervalStr = env["UPDATE_INTERVAL"] ?? "3.0"
        let updateInterval = TimeInterval(updateIntervalStr) ?? 3.0
        print("Update Interval: \(updateInterval) seconds")
        
        // Initialize Clients
        let aria2 = Aria2Client(rpcURL: rpcURL, secret: rpcSecret)
        let bot = TelegramBot(token: telegramToken)
        
        let daemon = MirrorDaemon(
            aria2: aria2,
            bot: bot,
            downloadDir: downloadDir,
            destinationDir: destinationDir,
            updateInterval: updateInterval,
            allowedChatId: allowedChatId
        )
        
        // Start Daemon
        await daemon.start()
    }
}
