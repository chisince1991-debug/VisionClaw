import Foundation
import SwiftUI
import Speech
import AVFoundation

enum DirectSessionState: Equatable {
  case idle
  case listening
  case processing
  case speaking
  case error(String)
}

@MainActor
class DirectSessionViewModel: ObservableObject {
  @Published var state: DirectSessionState = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured
  @Published var transcript: String = ""
  @Published var lastResponse: String = ""
  @Published var errorMessage: String?
  @Published var isAutoMode: Bool = true  // 自動模式（免按鈕）
  @Published var debugLogs: [String] = []  // In-app debug log
  
  private let bridge = OpenClawBridge()
  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private let synthesizer = AVSpeechSynthesizer()
  
  /// Current frame from glasses
  var currentFrame: UIImage?
  
  /// Debug log max entries
  private let maxDebugLogs = 50
  
  /// Voice activity detection
  private var lastSpeechTime: Date = Date()
  private var silenceTimer: Task<Void, Never>?
  private let silenceThreshold: TimeInterval = 1.0  // 1.0秒靜默後自動發送（從1.5s優化）
  private var hasDetectedSpeech: Bool = false
  private var isProcessingRequest: Bool = false  // 防止在處理中重新開始監聽
  
  /// Pre-emptive Gemini Vision: start analyzing frame as soon as speech detected
  private var preemptiveVisionTask: Task<String?, Never>?
  private var preemptiveVisionFrame: UIImage?
  
  // MARK: - Debug Logging
  
  private func log(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let entry = "[\(timestamp)] \(message)"
    NSLog("[DirectSession] %@", message)
    debugLogs.append(entry)
    if debugLogs.count > maxDebugLogs {
      debugLogs.removeFirst(debugLogs.count - maxDebugLogs)
    }
  }
  
  func clearDebugLogs() {
    debugLogs.removeAll()
  }
  
  // MARK: - Lifecycle
  
  func setup() async {
    log("🚀 Setup starting...")
    log("📍 Host: \(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)")
    log("🔑 Token configured: \(GeminiConfig.isOpenClawConfigured ? "YES" : "NO")")
    
    await bridge.checkConnection()
    connectionState = bridge.connectionState
    log("📡 Connection: \(String(describing: connectionState))")
    
    if case .unreachable(let reason) = connectionState {
      errorMessage = "無法連線到小助理: \(reason)"
      state = .error("連線失敗: \(reason)")
      log("❌ Connection failed: \(reason)")
      return
    }
    
    if case .notConfigured = connectionState {
      errorMessage = "尚未設定 OpenClaw 連線，請到設定頁填入 Host 和 Token"
      state = .error("未設定連線")
      log("❌ Not configured")
      return
    }
    
    bridge.resetSession()
    
    // Request speech recognition permission
    log("🎤 Requesting speech authorization...")
    let authorized = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
    
    if !authorized {
      errorMessage = "語音辨識未授權，請到 iOS 設定 > VisionClaw > 語音辨識 開啟權限"
      state = .error("語音辨識未授權")
      log("❌ Speech not authorized")
      return
    }
    
    log("✅ Setup complete, autoMode: \(isAutoMode)")
    
    // Auto-start listening if in auto mode
    if isAutoMode {
      try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
      startListening()
    }
  }
  
  // MARK: - Voice Input
  
  func startListening() {
    guard state == .idle || state == .speaking else {
      log("⚠️ Cannot start listening, state: \(state)")
      return
    }
    
    guard !isProcessingRequest else {
      log("⚠️ Cannot start listening, request in progress")
      return
    }
    
    guard let speechRecognizer = speechRecognizer else {
      errorMessage = "語音辨識器未初始化（zh-TW locale 不可用）"
      state = .error("語音辨識器未初始化")
      log("❌ SFSpeechRecognizer is nil — zh-TW locale may not be supported on this device")
      return
    }
    
    guard speechRecognizer.isAvailable else {
      errorMessage = "語音辨識暫時不可用，請檢查網路連線（Apple 語音辨識需要網路）"
      state = .error("語音辨識不可用")
      log("❌ SFSpeechRecognizer.isAvailable = false (needs internet)")
      return
    }
    
    synthesizer.stopSpeaking(at: .immediate)
    
    let audioSession = AVAudioSession.sharedInstance()
    do {
      // Fixed category throughout app lifecycle to avoid IPC bug with AVSpeechSynthesizer
      // Using .voiceChat mode instead of .measurement for better TTS compatibility
      try audioSession.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
      )
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      log("🔊 Audio session configured (bluetooth: enabled, mode: voiceChat)")
      
      // Log current audio route for debugging
      let route = audioSession.currentRoute
      let inputs = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
      let outputs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
      log("🔊 Audio route — IN: [\(inputs)] OUT: [\(outputs)]")
    } catch {
      errorMessage = "音訊設定失敗: \(error.localizedDescription)"
      state = .error("音訊設定失敗")
      log("❌ AVAudioSession error: \(error)")
      return
    }
    
    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest = recognitionRequest else {
      errorMessage = "無法建立語音辨識請求（記憶體不足？）"
      state = .error("辨識請求建立失敗")
      log("❌ Failed to create SFSpeechAudioBufferRecognitionRequest")
      return
    }
    recognitionRequest.shouldReportPartialResults = true
    
    // Access inputNode — this can throw/crash if no mic input is available (e.g. bluetooth disconnect)
    let inputNode: AVAudioInputNode
    do {
      inputNode = audioEngine.inputNode
    } catch {
      errorMessage = "無法取得麥克風輸入，請確認眼鏡已連接或手機麥克風可用"
      state = .error("麥克風不可用")
      log("❌ audioEngine.inputNode failed: \(error)")
      return
    }
    
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    log("🎤 Input format: \(Int(recordingFormat.sampleRate)) Hz, \(recordingFormat.channelCount) ch")
    
    guard recordingFormat.sampleRate > 0 else {
      errorMessage = "無效的音訊格式 (sampleRate=0)，麥克風可能被其他 app 佔用或藍牙裝置未連接"
      state = .error("音訊格式無效")
      log("❌ Invalid recording format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")
      return
    }
    
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }
    
    audioEngine.prepare()
    do {
      try audioEngine.start()
      state = .listening
      transcript = ""
      log("🎤 Listening (\(Int(recordingFormat.sampleRate)) Hz, \(recordingFormat.channelCount) ch)")
    } catch {
      let nsError = error as NSError
      errorMessage = "麥克風啟動失敗 [\(nsError.code)]: \(error.localizedDescription)"
      state = .error("麥克風啟動失敗")
      log("❌ AudioEngine.start() error [\(nsError.domain) \(nsError.code)]: \(error)")
      inputNode.removeTap(onBus: 0)
      return
    }
    
    recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self = self else { return }
      
      if let result = result {
        Task { @MainActor in
          let newTranscript = result.bestTranscription.formattedString
          if newTranscript != self.transcript && !newTranscript.isEmpty {
            self.log("📝 \"\(newTranscript)\"")
            self.transcript = newTranscript
            
            // Pre-emptive Vision: start Gemini analysis on FIRST speech detection
            // By the time silence is detected (~1s later), vision result is already ready
            if !self.hasDetectedSpeech, let frame = self.currentFrame {
              self.log("📸 Pre-emptive Vision: capturing frame & starting Gemini analysis NOW")
              self.preemptiveVisionFrame = frame
              self.preemptiveVisionTask = Task {
                await self.bridge.analyzeImageWithGeminiPublic(image: frame, userSpeech: newTranscript)
              }
            }
            
            self.hasDetectedSpeech = true
            self.lastSpeechTime = Date()
            self.silenceTimer?.cancel()
            self.startSilenceTimer()
          }
        }
      }
      
      if let error = error {
        let nsError = error as NSError
        Task { @MainActor in
          self.log("⚠️ Recognition error [\(nsError.domain) \(nsError.code)]: \(error.localizedDescription)")
          // Code 1110 = no speech detected (normal), don't show as error
          if nsError.code != 1110 {
            self.errorMessage = "語音辨識錯誤: \(error.localizedDescription) (code \(nsError.code))"
          }
        }
      }
    }
  }
  
  private func startSilenceTimer() {
    silenceTimer?.cancel()
    silenceTimer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(silenceThreshold * 1_000_000_000))
      
      if Task.isCancelled { return }
      
      let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
      
      if silenceDuration >= silenceThreshold && hasDetectedSpeech && state == .listening {
        log("🔇 Silence \(String(format: "%.1f", silenceDuration))s → auto-sending")
        await stopListeningAndSend()
      }
    }
  }
  
  func stopListeningAndSend() async {
    guard state == .listening else { return }
    
    silenceTimer?.cancel()
    silenceTimer = nil
    
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    
    let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    log("📝 Final: \"\(finalTranscript)\"")
    
    hasDetectedSpeech = false
    
    guard !finalTranscript.isEmpty else {
      if isAutoMode {
        startListening()
      } else {
        state = .idle
      }
      return
    }
    
    state = .processing
    isProcessingRequest = true
    
    let startTime = Date()
    
    // Check if pre-emptive vision analysis is available (started when speech first detected)
    var visionDescription: String? = nil
    if let visionTask = preemptiveVisionTask {
      log("📸 Waiting for pre-emptive Vision result...")
      let preemptiveStart = Date()
      visionDescription = await visionTask.value
      let preemptiveWait = Date().timeIntervalSince(preemptiveStart)
      if let desc = visionDescription {
        log("📸 Pre-emptive Vision ready! (waited \(String(format: "%.1f", preemptiveWait))s, \(desc.count) chars)")
      } else {
        log("⚠️ Pre-emptive Vision failed (waited \(String(format: "%.1f", preemptiveWait))s)")
      }
    } else if currentFrame != nil {
      // No pre-emptive task (e.g. speech was too short) — fall back to inline analysis
      log("📸 No pre-emptive Vision, falling back to inline Gemini call")
    }
    
    // Clean up pre-emptive state
    preemptiveVisionTask = nil
    preemptiveVisionFrame = nil
    
    let hasVision = visionDescription != nil || currentFrame != nil
    log("📤 Sending to 小助理: \"\(finalTranscript)\" (vision: \(hasVision ? "YES" : "NO"), preemptive: \(visionDescription != nil ? "HIT" : "MISS"))")
    
    // If we have pre-emptive vision, pass it directly (skip Gemini call inside delegateTask)
    let result: ToolResult
    if let desc = visionDescription {
      result = await bridge.delegateTaskWithVision(
        task: finalTranscript,
        visionDescription: desc,
        toolName: "voice"
      )
    } else {
      result = await bridge.delegateTask(
        task: finalTranscript,
        toolName: "voice",
        image: currentFrame
      )
    }
    let elapsed = Date().timeIntervalSince(startTime)
    log("⏱️ Response in \(String(format: "%.1f", elapsed))s")
    
    isProcessingRequest = false
    
    switch result {
    case .success(let response):
      lastResponse = response
      log("✅ Got reply (\(response.count) chars)")
      await speak(response)
    case .failure(let error):
      errorMessage = "小助理回覆失敗: \(error)"
      state = .error(error)
      log("❌ OpenClaw error: \(error)")
      if isAutoMode {
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s delay
        errorMessage = nil
        startListening()
      }
    }
  }
  
  // MARK: - Voice Output (MiniMax TTS primary, ElevenLabs fallback)
  
  private var ttsPlayer: AVAudioPlayer?
  
  // TTS keys from Secrets.swift (no hardcoded keys in this file)
  private var openAIAPIKey: String { Secrets.openAIAPIKey }
  private var elevenLabsAPIKey: String { Secrets.elevenLabsAPIKey }
  private var elevenLabsVoiceId: String { Secrets.elevenLabsVoiceId }
  
  private func speak(_ text: String) async {
    state = .speaking
    log("🔊 TTS starting: \"\(String(text.prefix(80)))...\"")
    
    // Truncate for snappy voice UX (shorter = faster TTS + shorter playback)
    let spokenText = text.count > 200 ? String(text.prefix(200)) + "。" : text
    
    // Strip markdown formatting for cleaner speech
    let cleanText = spokenText
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "##", with: "")
      .replacingOccurrences(of: "#", with: "")
      .replacingOccurrences(of: "- ", with: "")
      .replacingOccurrences(of: "`", with: "")
    
    // Keep audio session consistent — DO NOT switch mode or deactivate/reactivate
    // Switching mode triggers iOS IPC bug with AVSpeechSynthesizer (三方會診 2026-02-19 結論)
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
      )
      if !audioSession.isOtherAudioPlaying {
        try audioSession.setActive(true)
      }
      log("🔊 Audio session: playAndRecord + voiceChat (consistent, no switching)")
    } catch {
      log("⚠️ Audio session error: \(error.localizedDescription)")
    }
    
    // Try OpenAI TTS first, fallback to ElevenLabs
    var audioData = await openAITTS(text: cleanText)
    
    if audioData == nil {
      log("⚠️ OpenAI TTS failed, trying ElevenLabs fallback...")
      audioData = await elevenLabsTTS(text: cleanText)
    }
    
    if let audioData = audioData {
      log("🔊 Got audio data: \(audioData.count) bytes, first 4 bytes: \(audioData.prefix(4).map { String(format: "%02X", $0) }.joined())")
      do {
        ttsPlayer = try AVAudioPlayer(data: audioData)
        ttsPlayer?.volume = 1.0
        ttsPlayer?.prepareToPlay()
        
        // Log audio route before playing
        let route = audioSession.currentRoute
        let outputs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log("🔊 Playing on: [\(outputs)], duration: \(String(format: "%.1f", ttsPlayer?.duration ?? 0))s")
        
        ttsPlayer?.play()
        
        while ttsPlayer?.isPlaying == true {
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("🔊 Finished playing audio")
      } catch {
        log("❌ AVAudioPlayer error: \(error.localizedDescription)")
      }
    } else {
      log("❌ All TTS methods failed — both MiniMax and ElevenLabs returned nil")
    }
    
    log("🔊 Finished speaking (\(cleanText.count) chars)")
    transcript = ""
    
    if isAutoMode {
      try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms (was 800ms)
      startListening()
    } else {
      state = .idle
    }
  }
  
  // MARK: - OpenAI TTS (primary — stable, good Chinese)
  
  private func openAITTS(text: String) async -> Data? {
    guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
      log("❌ OpenAI TTS: invalid URL")
      return nil
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15
    
    let body: [String: Any] = [
      "model": "tts-1",
      "input": text,
      "voice": "nova",
      "response_format": "aac",  // aac: native iOS support, smaller than mp3
      "speed": 1.15  // slightly faster speech for snappier feel
    ]
    
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    } catch {
      log("❌ OpenAI TTS: JSON error: \(error.localizedDescription)")
      return nil
    }
    
    log("🔊 Calling OpenAI TTS...")
    
    do {
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
      
      guard let httpResponse = response as? HTTPURLResponse else {
        log("❌ OpenAI TTS: no HTTP response")
        return nil
      }
      
      log("🔊 OpenAI TTS response: HTTP \(httpResponse.statusCode), \(data.count) bytes")
      
      guard httpResponse.statusCode == 200 else {
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        log("❌ OpenAI TTS error: HTTP \(httpResponse.statusCode) - \(String(bodyStr.prefix(200)))")
        return nil
      }
      
      // OpenAI returns raw audio data
      if data.count > 50 {
        log("🔊 OpenAI TTS: got \(data.count) bytes audio")
        return data
      }
      
      log("❌ OpenAI TTS: response too small (\(data.count) bytes)")
      return nil
    } catch {
      log("❌ OpenAI TTS network error: \(error.localizedDescription)")
      return nil
    }
  }
  
  // MARK: - ElevenLabs TTS (fallback)
  
  private func elevenLabsTTS(text: String) async -> Data? {
    guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenLabsVoiceId)") else {
      return nil
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 30
    
    let body: [String: Any] = [
      "text": text,
      "model_id": "eleven_flash_v2_5",
      "voice_settings": [
        "stability": 0.5,
        "similarity_boost": 0.75
      ]
    ]
    
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      log("🔊 Calling ElevenLabs API...")
      
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
      
      if let httpResponse = response as? HTTPURLResponse {
        log("🔊 ElevenLabs: HTTP \(httpResponse.statusCode), \(data.count) bytes")
        if httpResponse.statusCode == 200 && data.count > 1000 {
          return data
        }
      }
      return nil
    } catch {
      log("❌ ElevenLabs error: \(error.localizedDescription)")
      return nil
    }
  }
  
  // MARK: - Frame Update
  
  func updateFrame(_ image: UIImage) {
    currentFrame = image
  }
  
  // MARK: - Cleanup
  
  func cleanup() {
    silenceTimer?.cancel()
    silenceTimer = nil
    preemptiveVisionTask?.cancel()
    preemptiveVisionTask = nil
    preemptiveVisionFrame = nil
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    synthesizer.stopSpeaking(at: .immediate)
    state = .idle
    hasDetectedSpeech = false
  }
}
