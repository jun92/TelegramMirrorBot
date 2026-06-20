import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Telegram API Codables

public struct TelegramAPIResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public let ok: Bool
    public let result: T?
    public let description: String?
}

public struct TelegramUpdate: Codable, Sendable {
    public let updateId: Int
    public let message: TelegramMessage?
    public let callbackQuery: TelegramCallbackQuery?
    
    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

public struct TelegramMessage: Codable, Sendable {
    public let messageId: Int
    public let chat: TelegramChat
    public let text: String?
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case chat
        case text
    }
}

public struct TelegramChat: Codable, Sendable {
    public let id: Int64
    public let type: String
}

public struct TelegramCallbackQuery: Codable, Sendable {
    public let id: String
    public let from: TelegramUser
    public let message: TelegramMessage?
    public let data: String?
}

public struct TelegramUser: Codable, Sendable {
    public let id: Int64
    public let firstName: String
    public let username: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case username
    }
}

// Markup Codables
public struct InlineKeyboardMarkup: Codable, Sendable {
    public let inlineKeyboard: [[InlineKeyboardButton]]
    
    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
    
    public init(inlineKeyboard: [[InlineKeyboardButton]]) {
        self.inlineKeyboard = inlineKeyboard
    }
}

public struct InlineKeyboardButton: Codable, Sendable {
    public let text: String
    public let callbackData: String?
    
    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
    
    public init(text: String, callbackData: String?) {
        self.text = text
        self.callbackData = callbackData
    }
}

public struct TelegramBotError: Error, CustomStringConvertible, LocalizedError {
    public let code: Int
    public let message: String
    
    public var description: String {
        return "TelegramBotError (code \(code)): \(message)"
    }
    
    public var errorDescription: String? {
        return description
    }
}

// MARK: - TelegramBot Class

public actor TelegramBot {
    private let token: String
    private let baseURL: URL
    private let session: URLSession
    private var lastUpdateId: Int = 0
    
    public init(token: String) {
        self.token = token
        self.baseURL = URL(string: "https://api.telegram.org/bot\(token)/")!
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 40.0 // higher timeout for long polling
        config.timeoutIntervalForResource = 50.0
        self.session = URLSession(configuration: config)
    }
    
    private func makeRequest<P: Encodable, R: Decodable & Sendable>(method: String, params: P) async throws -> R {
        let url = baseURL.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(params)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TelegramBotError(code: 1, message: "HTTP \(method) request failed: \(errorText)")
        }
        
        let apiResp = try JSONDecoder().decode(TelegramAPIResponse<R>.self, from: data)
        if !apiResp.ok {
            throw TelegramBotError(code: 2, message: apiResp.description ?? "API Error")
        }
        
        guard let result = apiResp.result else {
            throw TelegramBotError(code: 3, message: "API success but no result payload")
        }
        
        return result
    }
    
    /// Long poll updates from Telegram
    public func getUpdates(timeout: Int = 30) async throws -> [TelegramUpdate] {
        struct Params: Encodable {
            let offset: Int?
            let timeout: Int
            let allowedUpdates: [String]
            
            enum CodingKeys: String, CodingKey {
                case offset, timeout
                case allowedUpdates = "allowed_updates"
            }
        }
        
        let offset = lastUpdateId > 0 ? lastUpdateId + 1 : nil
        let params = Params(offset: offset, timeout: timeout, allowedUpdates: ["message", "callback_query"])
        
        let updates: [TelegramUpdate] = try await makeRequest(method: "getUpdates", params: params)
        if let lastUpdate = updates.last {
            lastUpdateId = lastUpdate.updateId
        }
        return updates
    }
    
    /// Send a text message to a chat
    @discardableResult
    public func sendMessage(
        chatId: Int64,
        text: String,
        parseMode: String? = "HTML",
        replyMarkup: InlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        struct Params: Encodable {
            let chatId: Int64
            let text: String
            let parseMode: String?
            let replyMarkup: InlineKeyboardMarkup?
            
            enum CodingKeys: String, CodingKey {
                case chatId = "chat_id"
                case text
                case parseMode = "parse_mode"
                case replyMarkup = "reply_markup"
            }
        }
        
        let params = Params(chatId: chatId, text: text, parseMode: parseMode, replyMarkup: replyMarkup)
        return try await makeRequest(method: "sendMessage", params: params)
    }
    
    /// Edit an existing message
    @discardableResult
    public func editMessageText(
        chatId: Int64,
        messageId: Int,
        text: String,
        parseMode: String? = "HTML",
        replyMarkup: InlineKeyboardMarkup? = nil
    ) async throws -> TelegramMessage {
        struct Params: Encodable {
            let chatId: Int64
            let messageId: Int
            let text: String
            let parseMode: String?
            let replyMarkup: InlineKeyboardMarkup?
            
            enum CodingKeys: String, CodingKey {
                case chatId = "chat_id"
                case messageId = "message_id"
                case text
                case parseMode = "parse_mode"
                case replyMarkup = "reply_markup"
            }
        }
        
        let params = Params(chatId: chatId, messageId: messageId, text: text, parseMode: parseMode, replyMarkup: replyMarkup)
        return try await makeRequest(method: "editMessageText", params: params)
    }
    
    /// Acknowledge callback query
    public func answerCallbackQuery(callbackQueryId: String, text: String? = nil) async throws -> Bool {
        struct Params: Encodable {
            let callbackQueryId: String
            let text: String?
            
            enum CodingKeys: String, CodingKey {
                case callbackQueryId = "callback_query_id"
                case text
            }
        }
        
        let params = Params(callbackQueryId: callbackQueryId, text: text)
        return try await makeRequest(method: "answerCallbackQuery", params: params)
    }
    
    /// Delete a message
    @discardableResult
    public func deleteMessage(chatId: Int64, messageId: Int) async throws -> Bool {
        struct Params: Encodable {
            let chatId: Int64
            let messageId: Int
            
            enum CodingKeys: String, CodingKey {
                case chatId = "chat_id"
                case messageId = "message_id"
            }
        }
        
        let params = Params(chatId: chatId, messageId: messageId)
        return try await makeRequest(method: "deleteMessage", params: params)
    }
}
