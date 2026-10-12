import SwiftUI

/// Landing: "How is your body feeling today?", the orb (tap to talk), and the touch route.
/// Two equally obvious ways in: tell Lofer, or show it on the body.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var greetIndex = 0
    private let timer = Timer.publish(every: 5.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(systemName: "clock.arrow.circlepath", label: "Body history") { app.path.append(.history) }
                Spacer()
                LoferMark().frame(width: 30, height: 30)
                Spacer()
                CircleIconButton(systemName: "person", label: "Profile and settings") { app.path.append(.profile) }
            }
            .padding(.horizontal, 18).padding(.top, 8)

            Text(app.homeLine)
                .font(LoferFont.greeting).foregroundStyle(Color.loferCream).multilineTextAlignment(.center)
                .lineSpacing(2).padding(.horizontal, 28).padding(.top, 34)
                .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: app.homeLine)
            if !app.homeContext.isEmpty {
                Text(app.homeContext.uppercased()).font(LoferFont.ui(10.5, .medium)).tracking(1.8).foregroundStyle(Color.loferPeach).padding(.top, 10)
            }
            Spacer(minLength: 0)
            VoiceOrb(state: app.voice.state, size: 300)
                .onTapGesture { app.micTapped() }
                .accessibilityAddTraits(.isButton)
            // What was heard, or why voice isn't working (typing always still works).
            Text(app.voice.problem?.message ?? app.homeHeard).font(LoferFont.ui(14.5)).foregroundStyle(Color.loferMuted).multilineTextAlignment(.center)
                .padding(.horizontal, 28).frame(minHeight: 22)
            HStack(spacing: 10) {
                Button { app.micTapped() } label: {
                    Label(app.voice.state == .listening ? "Listening…" : "Tap to talk", systemImage: "mic")
                        .font(LoferFont.ui(13)).padding(.horizontal, 13).padding(.vertical, 7)
                        .foregroundStyle(app.voice.state == .listening ? Color.loferCream : Color.loferMuted)
                        .background(Capsule().fill(Color(hex: 0x23201F).opacity(0.45))).overlay(Capsule().stroke(app.voice.state == .listening ? Color.loferPeach : Color.loferLine))
                }
                Button("or type") { app.keyboardTapped() }.font(LoferFont.ui(13)).foregroundStyle(Color.loferFaint).underline()
            }
            .buttonStyle(.plain).padding(.top, 6)
            Spacer(minLength: 18)
            Button { app.openBody() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "figure.stand").font(.system(size: 22)).foregroundStyle(Color.loferCream).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Or show me on your body").font(LoferFont.ui(15.5)).foregroundStyle(Color.loferCream)
                        Text("Tap where it’s bothering you").font(LoferFont.ui(12.5)).foregroundStyle(Color.loferMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Color.loferMuted)
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial.opacity(0.5)))
                .background(RoundedRectangle(cornerRadius: 26).fill(LinearGradient(colors: [Color(hex: 0x342E2B).opacity(0.55), Color(hex: 0x1A1716).opacity(0.7)], startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.loferLine2))
            }
            .buttonStyle(.plain).padding(.horizontal, 18).padding(.bottom, 16)
        }
        .onReceive(timer) { _ in
            guard app.voice.state == .idle, app.homeHeard.isEmpty else { return }
            greetIndex = (greetIndex + 1) % AppModel.greetings.count
            app.homeLine = AppModel.greetings[greetIndex]
        }
    }
}
