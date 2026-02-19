/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling. Extended with Gemini Live AI assistant and WebRTC live streaming integration.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop: single local feed (PiP disabled for now)
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // Gemini status overlay (top) + speaking indicator
      if geminiVM.isGeminiActive {
        VStack {
          GeminiStatusBar(geminiVM: geminiVM)
          Spacer()

          VStack(spacing: 8) {
            if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
              TranscriptView(
                userText: geminiVM.userTranscript,
                aiText: geminiVM.aiTranscript
              )
            }

            ToolCallStatusView(status: geminiVM.toolCallStatus)

            if geminiVM.isModelSpeaking {
              HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                  .foregroundColor(.white)
                  .font(.system(size: 14))
                SpeakingIndicator()
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(20)
            }
          }
          .padding(.bottom, 80)
        }
        .padding(.all, 24)
      }

      // WebRTC status overlay (top)
      if webrtcVM.isActive {
        VStack {
          WebRTCStatusBar(webrtcVM: webrtcVM)
          Spacer()
        }
        .padding(.all, 24)
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
        if geminiVM.isGeminiActive {
          geminiVM.stopSession()
        }
        if webrtcVM.isActive {
          webrtcVM.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    // Gemini error alert
    .alert("AI Assistant", isPresented: Binding(
      get: { geminiVM.errorMessage != nil },
      set: { if !$0 { geminiVM.errorMessage = nil } }
    )) {
      Button("OK") { geminiVM.errorMessage = nil }
    } message: {
      Text(geminiVM.errorMessage ?? "")
    }
    // WebRTC error alert
    .alert("Live Stream", isPresented: Binding(
      get: { webrtcVM.errorMessage != nil },
      set: { if !$0 { webrtcVM.errorMessage = nil } }
    )) {
      Button("OK") { webrtcVM.errorMessage = nil }
    } message: {
      Text(webrtcVM.errorMessage ?? "")
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel
  @State private var showDirectSession = false

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button (glasses mode only -- DAT SDK capture)
      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
      }

      // Direct OpenClaw button (直連小助理)
      CircleButton(
        icon: "sparkles",
        text: "直連"
      ) {
        showDirectSession = true
      }
      .opacity(geminiVM.isGeminiActive || webrtcVM.isActive ? 0.4 : 1.0)
      .disabled(geminiVM.isGeminiActive || webrtcVM.isActive)

      // Gemini AI button (disabled when WebRTC is active — audio conflict)
      CircleButton(
        icon: geminiVM.isGeminiActive ? "waveform.circle.fill" : "waveform.circle",
        text: "AI"
      ) {
        Task {
          if geminiVM.isGeminiActive {
            geminiVM.stopSession()
          } else {
            await geminiVM.startSession()
          }
        }
      }
      .opacity(webrtcVM.isActive || showDirectSession ? 0.4 : 1.0)
      .disabled(webrtcVM.isActive || showDirectSession)

      // WebRTC Live Stream button (disabled when Gemini is active — audio conflict)
      CircleButton(
        icon: webrtcVM.isActive
          ? "antenna.radiowaves.left.and.right.circle.fill"
          : "antenna.radiowaves.left.and.right.circle",
        text: "Live"
      ) {
        Task {
          if webrtcVM.isActive {
            webrtcVM.stopSession()
          } else {
            await webrtcVM.startSession()
          }
        }
      }
      .opacity(geminiVM.isGeminiActive || showDirectSession ? 0.4 : 1.0)
      .disabled(geminiVM.isGeminiActive || showDirectSession)
    }
    .overlay {
      if showDirectSession {
        DirectSessionOverlay(
          streamVM: viewModel,
          onDismiss: { showDirectSession = false }
        )
        .transition(.opacity)
      }
    }
  }
}

// Direct session overlay that shows the direct connection UI
struct DirectSessionOverlay: View {
  @ObservedObject var streamVM: StreamSessionViewModel
  let onDismiss: () -> Void
  @StateObject private var directVM = DirectSessionViewModel()
  @State private var showDebugLog = false
  
  private var currentFrame: UIImage? { streamVM.currentVideoFrame }
  
  var body: some View {
    ZStack {
      // Background - current frame or black
      if let frame = currentFrame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .ignoresSafeArea()
      } else {
        Color.black.ignoresSafeArea()
      }
      
      // Dark overlay for better readability
      Color.black.opacity(0.3).ignoresSafeArea()
      
      // Main UI - centered layout for glasses
      VStack(spacing: 16) {
        // Top bar with close button and connection status
        HStack {
          Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 32))
              .foregroundColor(.white)
              .shadow(radius: 4)
          }
          
          Spacer()
          
          // Debug log button
          Button(action: { showDebugLog.toggle() }) {
            Image(systemName: "ladybug.fill")
              .font(.system(size: 24))
              .foregroundColor(.yellow)
              .shadow(radius: 4)
          }
          .padding(.trailing, 8)
          
          // Connection status (more prominent)
          HStack(spacing: 8) {
            Circle()
              .fill(connectionStatusColor)
              .frame(width: 12, height: 12)
            Text(connectionStatusText)
              .font(.subheadline.bold())
              .foregroundColor(.white)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(connectionStatusColor.opacity(0.3))
          .background(.ultraThinMaterial)
          .cornerRadius(16)
        }
        .padding(.horizontal)
        .padding(.top, 20)
        
        // Spacer with less weight to push content up
        Spacer().frame(maxHeight: 100)
        
        // Main content area (centered)
        VStack(spacing: 20) {
          // State indicator (larger, more visible)
          VStack(spacing: 12) {
            // Visual indicator
            ZStack {
              // Pulsing rings when listening
              if directVM.state == .listening {
                ForEach(0..<3, id: \.self) { i in
                  Circle()
                    .stroke(Color.red.opacity(0.4), lineWidth: 3)
                    .frame(width: 100 + CGFloat(i) * 30, height: 100 + CGFloat(i) * 30)
                    .scaleEffect(1.2)
                    .opacity(0)
                    .animation(
                      .easeOut(duration: 1.5)
                      .repeatForever(autoreverses: false)
                      .delay(Double(i) * 0.3),
                      value: directVM.state
                    )
                }
              }
              
              Circle()
                .fill(buttonColor)
                .frame(width: 100, height: 100)
                .shadow(color: buttonColor.opacity(0.5), radius: 15)
              
              buttonIcon
                .font(.system(size: 40))
                .foregroundColor(.white)
            }
            .onTapGesture {
              handleButtonTap()
            }
            
            // State text (larger)
            HStack(spacing: 10) {
              stateIcon
              Text(stateText)
                .font(.title3.bold())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(stateColor.opacity(0.8))
            .cornerRadius(25)
          }
          
          // Transcript display (if any)
          if !directVM.transcript.isEmpty || !directVM.lastResponse.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              if !directVM.transcript.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: "person.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
                  Text(directVM.transcript)
                    .font(.body)
                    .foregroundColor(.white)
                }
              }
              
              if !directVM.lastResponse.isEmpty && directVM.state != .listening {
                Divider().background(Color.white.opacity(0.3))
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.title3)
                  Text(directVM.lastResponse)
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(8)
                }
              }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .padding(.horizontal)
          }
          
          // Error message (more prominent)
          if let error = directVM.errorMessage {
            HStack {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
              Text(error)
                .font(.subheadline)
                .foregroundColor(.white)
            }
            .padding()
            .background(Color.red.opacity(0.8))
            .cornerRadius(12)
            .padding(.horizontal)
          }
        }
        
        Spacer()
        
        // Manual send button (for debugging)
        if directVM.state == .listening && !directVM.transcript.isEmpty {
          Button(action: {
            Task {
              await directVM.stopListeningAndSend()
            }
          }) {
            HStack {
              Image(systemName: "paperplane.fill")
              Text("手動發送")
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.green)
            .cornerRadius(25)
          }
          .padding(.bottom, 10)
        }
        
        // Bottom hint
        Text(directVM.isAutoMode ? "🎤 自動模式：說完 1.5 秒自動發送" : "👆 點擊麥克風開始說話")
          .font(.caption)
          .foregroundColor(.white.opacity(0.7))
          .padding(.bottom, 80)  // Increased from 30 to 80 for glasses visibility
      }
    }
    // Debug log panel overlay
    .overlay(alignment: .bottom) {
      if showDebugLog {
        VStack(spacing: 8) {
          HStack {
            Text("🐛 Debug Log")
              .font(.headline.bold())
              .foregroundColor(.white)
            Spacer()
            Button("Copy") {
              UIPasteboard.general.string = directVM.debugLogs.joined(separator: "\n")
            }
            .font(.caption.bold())
            .foregroundColor(.blue)
            Button("Clear") {
              directVM.clearDebugLogs()
            }
            .font(.caption.bold())
            .foregroundColor(.red)
            Button("Close") {
              showDebugLog = false
            }
            .font(.caption.bold())
            .foregroundColor(.gray)
          }
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(directVM.debugLogs.enumerated()), id: \.offset) { index, log in
                  Text(log)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.green)
                    .id(index)
                }
              }
            }
            .onChange(of: directVM.debugLogs.count) { _ in
              if let last = directVM.debugLogs.indices.last {
                proxy.scrollTo(last, anchor: .bottom)
              }
            }
          }
          .frame(maxHeight: 200)
        }
        .padding()
        .background(Color.black.opacity(0.9))
        .cornerRadius(16)
        .padding()
      }
    }
    .task {
      await directVM.setup()
    }
    .onDisappear {
      directVM.cleanup()
    }
    .onChange(of: streamVM.currentVideoFrame) { newFrame in
      if let frame = newFrame {
        directVM.updateFrame(frame)
      }
    }
    .onAppear {
      // Set initial frame
      if let frame = streamVM.currentVideoFrame {
        directVM.updateFrame(frame)
      }
    }
  }
  
  // MARK: - Connection Status
  
  private var connectionStatusColor: Color {
    switch directVM.connectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .notConfigured: return .orange
    case .unreachable: return .red
    }
  }
  
  private var connectionStatusText: String {
    switch directVM.connectionState {
    case .connected: return "直連小助理"
    case .checking: return "連接中..."
    case .notConfigured: return "未設定"
    case .unreachable(let msg): return "❌ \(msg.prefix(20))"
    }
  }
  
  // MARK: - State Display
  
  private var stateColor: Color {
    switch directVM.state {
    case .idle: return .gray
    case .listening: return .red
    case .processing: return .orange
    case .speaking: return .purple
    case .error: return .red
    }
  }
  
  private var stateText: String {
    switch directVM.state {
    case .idle: return "準備中"
    case .listening: return "聆聽中..."
    case .processing: return "思考中..."
    case .speaking: return "回覆中..."
    case .error: return "發生錯誤"
    }
  }
  
  private var stateIcon: some View {
    Group {
      switch directVM.state {
      case .idle:
        Image(systemName: "circle")
      case .listening:
        Image(systemName: "waveform")
      case .processing:
        ProgressView().tint(.white)
      case .speaking:
        Image(systemName: "speaker.wave.2.fill")
      case .error:
        Image(systemName: "exclamationmark.triangle")
      }
    }
  }
  
  private var buttonColor: Color {
    switch directVM.state {
    case .listening: return .red
    case .processing: return .orange
    case .speaking: return .purple
    default: return .blue
    }
  }
  
  private var buttonIcon: some View {
    Group {
      switch directVM.state {
      case .listening:
        Image(systemName: "stop.fill")
      case .processing:
        ProgressView().tint(.white)
      case .speaking:
        Image(systemName: "speaker.wave.2.fill")
      default:
        Image(systemName: "mic.fill")
      }
    }
  }
  
  private func handleButtonTap() {
    switch directVM.state {
    case .idle:
      directVM.startListening()
    case .listening:
      Task {
        await directVM.stopListeningAndSend()
      }
    default:
      break
    }
  }
}
