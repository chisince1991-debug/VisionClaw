import Foundation
import UIKit

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: Any]] = []
  private let maxHistoryTurns = 10

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.newSessionKey()
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
        connectionState = .connected
        NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    sessionKey = OpenClawBridge.newSessionKey()
    conversationHistory = []
    NSLog("[OpenClaw] New session: %@", sessionKey)
  }

  private static func newSessionKey() -> String {
    let ts = ISO8601DateFormatter().string(from: Date())
    return "agent:main:glass:\(ts)"
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)
  //
  // Architecture for vision+voice:
  //   1. If image provided → Gemini API analyzes it first (fast, free, native multimodal)
  //   2. Image description + user's speech → sent as text to OpenClaw gateway
  //   3. OpenClaw (glass agent) responds with context from both vision and conversation
  //
  // This bypasses the gateway's lack of inline base64 image support.

  /// Delegate task with pre-computed vision description (skips Gemini call — used with pre-emptive vision)
  func delegateTaskWithVision(
    task: String,
    visionDescription: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    let enrichedTask = """
    [使用者透過眼鏡說]: \(task)
    [眼鏡攝影機畫面分析]: \(visionDescription)
    
    請根據使用者說的話和眼前的畫面來回答。用簡短口語化的中文回覆（這會透過語音播放給使用者聽）。
    """
    NSLog("[OpenClaw] 📸 Using pre-emptive vision (%d chars), skipping inline Gemini call", visionDescription.count)
    return await sendToGateway(enrichedTask: enrichedTask, toolName: toolName)
  }
  
  func delegateTask(
    task: String,
    toolName: String = "execute",
    image: UIImage? = nil
  ) async -> ToolResult {
    // Step 1: If image provided, analyze with Gemini Vision first (sequential fallback)
    var enrichedTask = task
    if let image = image {
      NSLog("[OpenClaw] 📸 Image provided — analyzing with Gemini Vision (inline)...")
      let visionResult = await analyzeImageWithGemini(image: image, userSpeech: task)
      if let description = visionResult {
        enrichedTask = """
        [使用者透過眼鏡說]: \(task)
        [眼鏡攝影機畫面分析]: \(description)
        
        請根據使用者說的話和眼前的畫面來回答。用簡短口語化的中文回覆（這會透過語音播放給使用者聽）。
        """
        NSLog("[OpenClaw] 📸 Vision analysis done (%d chars)", description.count)
      } else {
        NSLog("[OpenClaw] ⚠️ Vision analysis failed, sending text-only")
      }
    }

    return await sendToGateway(enrichedTask: enrichedTask, toolName: toolName)
  }
  
  // MARK: - Gateway Communication (shared by delegateTask and delegateTaskWithVision)
  
  func sendToGateway(enrichedTask: String, toolName: String) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    conversationHistory.append(["role": "user", "content": enrichedTask])

    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-agent-id")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages to gateway", conversationHistory.count)

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: body)
      request.httpBody = jsonData

      let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        let task = self.session.dataTask(with: request) { data, response, error in
          if let error = error {
            continuation.resume(throwing: error)
          } else if let data = data, let response = response {
            continuation.resume(returning: (data, response))
          } else {
            continuation.resume(throwing: NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data/response"]))
          }
        }
        task.resume()
      }

      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  // MARK: - Gemini Vision Analysis (direct API call, bypasses gateway)
  
  /// Public wrapper for pre-emptive vision analysis from ViewModel
  func analyzeImageWithGeminiPublic(image: UIImage, userSpeech: String) async -> String? {
    return await analyzeImageWithGemini(image: image, userSpeech: userSpeech)
  }
  
  /// Sends an image + user speech to Gemini API for fast multimodal analysis.
  /// Returns a text description of what the camera sees, or nil on failure.
  private func analyzeImageWithGemini(image: UIImage, userSpeech: String) async -> String? {
    // Compress image for speed (lower quality = faster upload)
    guard let jpegData = image.jpegData(compressionQuality: 0.5) else {
      NSLog("[Gemini Vision] ❌ Failed to compress image")
      return nil
    }
    
    let base64Image = jpegData.base64EncodedString()
    let apiKey = GeminiConfig.apiKey
    
    guard !apiKey.isEmpty else {
      NSLog("[Gemini Vision] ❌ No Gemini API key configured")
      return nil
    }
    
    // Use gemini-2.0-flash for fast vision (free tier, fast response)
    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
      return nil
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10  // Fast timeout — this needs to be snappy for voice
    
    let body: [String: Any] = [
      "contents": [[
        "parts": [
          ["text": """
          使用者戴著智慧眼鏡，正在透過語音跟你對話。以下是他說的話和眼鏡攝影機看到的畫面。
          
          使用者說：「\(userSpeech)」
          
          請詳細描述畫面中看到的所有重要內容（物品、文字、人物、場景、顏色等），用中文回答。
          如果畫面中有文字，請完整辨識出來。
          簡潔但完整，不超過 200 字。
          """],
          ["inline_data": [
            "mime_type": "image/jpeg",
            "data": base64Image
          ]]
        ]
      ]]
    ]
    
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      
      let (data, response) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
          if let error = error { cont.resume(throwing: error); return }
          guard let data = data, let response = response else {
            cont.resume(throwing: URLError(.badServerResponse)); return
          }
          cont.resume(returning: (data, response))
        }
        task.resume()
      }
      
      guard let httpResponse = response as? HTTPURLResponse else { return nil }
      
      NSLog("[Gemini Vision] Response: HTTP %d, %d bytes", httpResponse.statusCode, data.count)
      
      guard httpResponse.statusCode == 200 else {
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[Gemini Vision] ❌ Error: %@", String(bodyStr.prefix(300)))
        return nil
      }
      
      // Parse Gemini response: { "candidates": [{ "content": { "parts": [{ "text": "..." }] } }] }
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let candidates = json["candidates"] as? [[String: Any]],
         let first = candidates.first,
         let content = first["content"] as? [String: Any],
         let parts = content["parts"] as? [[String: Any]],
         let textPart = parts.first,
         let text = textPart["text"] as? String {
        NSLog("[Gemini Vision] ✅ Got description: %@", String(text.prefix(100)))
        return text
      }
      
      NSLog("[Gemini Vision] ❌ Unexpected response format")
      return nil
    } catch {
      NSLog("[Gemini Vision] ❌ Network error: %@", error.localizedDescription)
      return nil
    }
  }
}
