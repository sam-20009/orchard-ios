import SwiftUI

enum AetherTheme {
    static let background = Color(red: 0.035, green: 0.025, blue: 0.085)
    static let card = Color(red: 0.090, green: 0.082, blue: 0.160)
    static let purple = Color(red: 0.57, green: 0.29, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.32, blue: 0.73)
    static let textMuted = Color(red: 0.66, green: 0.66, blue: 0.78)
    static let gradient = LinearGradient(colors: [purple, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct AetherCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AetherTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

struct AetherHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("AetherMark")
                .resizable().scaledToFit().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aether XR").font(.system(size: 27, weight: .bold, design: .rounded))
                Text("REALIDADE ESTENDIDA NO IPHONE").font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2).foregroundStyle(AetherTheme.textMuted)
            }
            Spacer()
            Text("PREVIEW").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(AetherTheme.purple.opacity(0.25), in: Capsule())
        }
    }
}
