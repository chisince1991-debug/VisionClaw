import SwiftUI

struct DirectSessionView: View {
  @StateObject private var viewModel = DirectSessionViewModel()
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @State private var showDebugLog = false
  
  var body: some View {
    ZStack {
      // Background - glasses feed or placeholder
      if let frame = wearablesViewModel.currentFrame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .ignoresSafeArea()
      } else {
        Color.black.ignoresSafeArea()
        VStack {
          Image(systemName: "eyeglasses")
            .font(.system(size: 60))
            .foregroundColor(.gray)
          Text("等待眼鏡連接...")
            .foregroundColor(.gray)
        }
      }
      
      // Overlay UI
      VStack {
        // Status bar
        HStack {
          // Connection status
          HStack(spacing: 8) {
            Circle()
              .fill(connectionColor)
              .frame(width: 10, height: 10)
            Text(connectionText)
              .font(.caption)
              .foregroundColor(.white)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(.ultraThinMaterial)
          .cornerRadius(20)
          
          Spacer()
          
          // Debug log button
          Button(action: { showDebugLog.toggle() }) {
            Image(systemName: "ladybug.fill")
              .font(.caption)
              .foregroundColor(.white.opacity(0.6))
          }
          .padding(.horizontal, 8)
          
          // State indicator
          if viewModel.state != .idle {
            HStack(spacing: 6) {
              stateIcon
              Text(stateText)
                .font(.caption)
                .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(stateColor.opacity(0.8))
            .cornerRadius(20)
          }
        }
        .padding()
        
        // Debug log panel
        if showDebugLog {
          debugLogPanel
        }
        
        Spacer()
        
        // Transcript / Response display
        if !viewModel.transcript.isEmpty || !viewModel.lastResponse.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            if !viewModel.transcript.isEmpty {
              HStack {
                Image(systemName: "person.fill")
                  .foregroundColor(.blue)
                Text(viewModel.transcript)
                  .foregroundColor(.white)
              }
              .font(.body)
            }
            
            if !viewModel.lastResponse.isEmpty && viewModel.state != .listening {
              HStack(alignment: .top) {
                Image(systemName: "sparkles")
                  .foregroundColor(.purple)
                Text(viewModel.lastResponse)
                  .foregroundColor(.white)
                  .lineLimit(5)
              }
              .font(.body)
            }
          }
          .padding()
          .background(.ultraThinMaterial)
          .cornerRadius(16)
          .padding(.horizontal)
        }
        
        // Error message — detailed and tappable to copy
        if let error = viewModel.errorMessage {
          Text("⚠️ \(error)")
            .font(.caption)
            .foregroundColor(.red)
            .multilineTextAlignment(.leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding(.horizontal)
            .onTapGesture {
              UIPasteboard.general.string = error
              // Brief visual feedback via errorMessage update
              viewModel.errorMessage = "✅ 已複製錯誤訊息"
              Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { viewModel.errorMessage = nil }
              }
            }
        }
        
        // Main control button
        Button(action: handleButtonTap) {
          ZStack {
            Circle()
              .fill(buttonColor)
              .frame(width: 80, height: 80)
              .shadow(radius: 10)
            
            buttonIcon
              .font(.system(size: 32))
              .foregroundColor(.white)
          }
        }
        .disabled(viewModel.state == .processing)
        .padding(.bottom, 40)
      }
    }
    .task {
      await viewModel.setup()
    }
    .onDisappear {
      viewModel.cleanup()
    }
    .onChange(of: wearablesViewModel.currentFrame) { newFrame in
      if let frame = newFrame {
        viewModel.updateFrame(frame)
      }
    }
  }
  
  // MARK: - Debug Log Panel
  
  private var debugLogPanel: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("🐛 Debug Log")
          .font(.caption.bold())
          .foregroundColor(.green)
        Spacer()
        Button("Copy All") {
          UIPasteboard.general.string = viewModel.debugLogs.joined(separator: "\n")
        }
        .font(.caption2)
        .foregroundColor(.yellow)
        Button("Clear") {
          viewModel.clearDebugLogs()
        }
        .font(.caption2)
        .foregroundColor(.red)
      }
      
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(viewModel.debugLogs.enumerated()), id: \.offset) { index, log in
              Text(log)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.9))
                .id(index)
            }
          }
        }
        .onChange(of: viewModel.debugLogs.count) { _ in
          if let last = viewModel.debugLogs.indices.last {
            proxy.scrollTo(last, anchor: .bottom)
          }
        }
      }
      .frame(maxHeight: 200)
    }
    .padding(8)
    .background(Color.black.opacity(0.85))
    .cornerRadius(8)
    .padding(.horizontal)
  }
  
  // MARK: - Computed Properties
  
  private var connectionColor: Color {
    switch viewModel.connectionState {
    case .connected: return .green
    case .checking: return .yellow
    case .notConfigured, .unreachable: return .red
    }
  }
  
  private var connectionText: String {
    switch viewModel.connectionState {
    case .connected: return "已連接"
    case .checking: return "連接中..."
    case .notConfigured: return "未設定"
    case .unreachable(let msg): return "無法連接: \(msg)"
    }
  }
  
  private var stateColor: Color {
    switch viewModel.state {
    case .idle: return .clear
    case .listening: return .red
    case .processing: return .orange
    case .speaking: return .purple
    case .error: return .red
    }
  }
  
  private var stateIcon: some View {
    Group {
      switch viewModel.state {
      case .listening:
        Image(systemName: "waveform")
      case .processing:
        ProgressView()
          .tint(.white)
          .scaleEffect(0.8)
      case .speaking:
        Image(systemName: "speaker.wave.2.fill")
      default:
        EmptyView()
      }
    }
  }
  
  private var stateText: String {
    switch viewModel.state {
    case .idle: return ""
    case .listening: return "聆聽中..."
    case .processing: return "思考中..."
    case .speaking: return "回覆中..."
    case .error: return "錯誤"
    }
  }
  
  private var buttonColor: Color {
    switch viewModel.state {
    case .listening: return .red
    case .processing: return .orange
    case .speaking: return .purple
    default: return .blue
    }
  }
  
  private var buttonIcon: some View {
    Group {
      switch viewModel.state {
      case .listening:
        Image(systemName: "stop.fill")
      case .processing:
        ProgressView()
          .tint(.white)
      case .speaking:
        Image(systemName: "speaker.wave.2.fill")
      default:
        Image(systemName: "mic.fill")
      }
    }
  }
  
  // MARK: - Actions
  
  private func handleButtonTap() {
    switch viewModel.state {
    case .idle:
      viewModel.startListening()
    case .listening:
      Task {
        await viewModel.stopListeningAndSend()
      }
    case .speaking:
      // Could add interrupt functionality
      break
    default:
      break
    }
  }
}

#Preview {
  DirectSessionView(wearablesViewModel: WearablesViewModel())
}
