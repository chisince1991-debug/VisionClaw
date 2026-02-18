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
  private let silenceThreshold: TimeInterval = 1.5  // 1.5秒靜默後自動發送
  private var hasDetectedSpeech: Bool = false
  private var isProcessingRequest: Bool = false  // 防止在處理中重新開始監聽
  
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
      try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
    
    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    
    guard recordingFormat.sampleRate > 0 else {
      errorMessage = "無效的音訊格式 (sampleRate=0)，麥克風可能被其他 app 佔用"
      state = .error("音訊格式無效")
      log("❌ Invalid recording format: sampleRate=\(recordingFormat.sampleRate)")
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
      log("🎤 Listening (format: \(Int(recordingFormat.sampleRate)) Hz)")
    } catch {
      errorMessage = "麥克風啟動失敗: \(error.localizedDescription)"
      state = .error("麥克風啟動失敗")
      log("❌ AudioEngine.start() error: \(error)")
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
    
    let frameToSend = currentFrame
    log("📤 Sending to 小助理: \"\(finalTranscript)\" (image: \(frameToSend != nil ? "YES" : "NO"))")
    
    let startTime = Date()
    let result = await bridge.delegateTask(
      task: finalTranscript,
      toolName: "voice",
      image: frameToSend
    )
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
  
  // MARK: - Voice Output (TTS)
  
  private func speak(_ text: String) async {
    state = .speaking
    
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
    
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.playback, mode: .default)
      try audioSession.setActive(true)
    } catch {
      log("⚠️ TTS audio session error: \(error.localizedDescription)")
    }
    
    synthesizer.speak(utterance)
    
    while synthesizer.isSpeaking {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    
    log("🔊 Finished speaking")
    
    // Clear transcript for next round
    transcript = ""
    
    // Auto-restart listening if in auto mode
    if isAutoMode {
      // Small delay before restarting
      try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
      startListening()
    } else {
      state = .idle
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
