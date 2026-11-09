import SwiftUI

@main
struct ZETXDropApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.peers)
                .preferredColorScheme(.dark)
                .tint(Theme.c1)
        }
        .onChange(of: phase) { newPhase in
            store.scenePhaseChanged(newPhase)
        }
    }
}

enum Theme {
    static let bg = Color(red: 7 / 255, green: 11 / 255, blue: 20 / 255)
    static let card = Color(red: 16 / 255, green: 24 / 255, blue: 48 / 255)
    static let card2 = Color(red: 20 / 255, green: 31 / 255, blue: 61 / 255)
    static let line = Color(red: 31 / 255, green: 43 / 255, blue: 77 / 255)
    static let mut = Color(red: 139 / 255, green: 152 / 255, blue: 189 / 255)
    static let c1 = Color(red: 0, green: 229 / 255, blue: 1)
    static let c2 = Color(red: 1, green: 43 / 255, blue: 214 / 255)
    static let violet = Color(red: 122 / 255, green: 92 / 255, blue: 1)
    static let ok = Color(red: 43 / 255, green: 1, blue: 154 / 255)
    static let err = Color(red: 1, green: 77 / 255, blue: 109 / 255)
    static let grad = LinearGradient(colors: [c1, violet, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct GradientButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.grad.opacity(enabled ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

func formatSize(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}
