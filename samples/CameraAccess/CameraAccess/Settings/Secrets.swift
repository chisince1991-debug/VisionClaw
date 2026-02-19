import Foundation

// VisionClaw Secrets - Pre-configured for Louis's setup
enum Secrets {
    // Gemini API Key (免費)
    static let geminiAPIKey = "AIzaSyDEhTigUKqctB_VY6qaluivHwWmYbERxLU"
    
    // OpenClaw Gateway (使用 IP 更穩定)
    static let openClawHost = "http://192.168.100.128"
    static let openClawPort = 18789
    static let openClawGatewayToken = "0834aef511cfbba23684db50a12f5ffc85a6d456233592d8"
    
    // Hook Token (same as gateway token for simplicity)
    static let openClawHookToken = "0834aef511cfbba23684db50a12f5ffc85a6d456233592d8"
    
    // WebRTC (not used currently)
    static let webrtcSignalingURL = ""
}
