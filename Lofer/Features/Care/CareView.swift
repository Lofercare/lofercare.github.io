import SwiftUI

/// The care screen: three zones.
///   INFORMATION ZONE (top): back + breadcrumbs, Lofer's line on its own surface.
///   BODY ZONE (middle): the 3D body, framed into whatever space is left.
///   ACTION ZONE (bottom): the sheet for the current step + talk/type.
/// The zones are measured and passed to the 3D camera, so text never covers the body.
struct CareView: View {
    @Bindable var model: CareFlowModel
    @Environment(AppModel.self) private var app
    @State private var dockBottom: CGFloat = 140
    @State private var sheetTop: CGFloat = 600
    @State private var screenH: CGFloat = 844

    var body: some View {
        ZStack(alignment: .top) {
            BodySceneView(controller: model.body).ignoresSafeArea()
            if !model.bodyReady {
                Text("Preparing your body model…").font(LoferFont.caption).foregroundStyle(Color.loferMuted).padding(.top, 320)
            }
            VStack(spacing: 8) {
                navBar
                dock
                tools
                Spacer(minLength: 0)
                BottomSheet(solid: bandHeight < 170) {
                    CareSheet(model: model)
                    VoiceBar()
                }
                .background(GeometryReader { g in Color.clear.preference(key: SheetTopKey.self, value: g.frame(in: .named("care")).minY) })
            }
        }
        .coordinateSpace(name: "care")
        .background(GeometryReader { g in Color.clear.onAppear { screenH = g.size.height }.onChange(of: g.size.height) { _, h in screenH = h } })
        .onPreferenceChange(DockBottomKey.self) { dockBottom = $0; pushInsets() }
        .onPreferenceChange(SheetTopKey.self) { sheetTop = $0; pushInsets() }
        .animation(Motion.standard, value: model.step)
    }
    private var bandHeight: CGFloat { sheetTop - dockBottom }
    private func pushInsets() {
        // If there isn't enough room, let the body sit behind the (now solid) sheet.
        if bandHeight < 170 { model.body.setInsets(top: 0, bottom: 0) }
        else { model.body.setInsets(top: dockBottom + 10, bottom: max(0, screenH - sheetTop) + 18) }
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "chevron.left", label: "Back") { model.goBack() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let path = BodyAtlas.shared.path(to: model.focus)
                    let locating = model.step == .locate || model.step == .listening
                    ForEach(Array(path.enumerated()), id: \.offset) { i, id in
                        if i > 0 { Text("›").foregroundStyle(Color.loferFaint) }
                        Button(BodyAtlas.shared[id].shortName.uppercased()) { if locating { model.goFocus(id) } }
                            .font(LoferFont.ui(11, .medium)).tracking(1.5)
                            .foregroundStyle(i == path.count - 1 ? Color.loferCream : Color.loferFaint)
                            .disabled(!locating).padding(.vertical, 6).padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 4)
    }

    private var dock: some View {
        VStack(spacing: 4) {
            Text(model.agentLine).font(LoferFont.agentLine).foregroundStyle(Color.loferCream).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
            if !model.heard.isEmpty { Text(model.heard).font(LoferFont.caption).foregroundStyle(Color.loferMuted).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [Color(hex: 0x120F0E).opacity(0.82), Color(hex: 0x120F0E).opacity(0.55)], startPoint: .top, endPoint: .bottom)))
        .padding(.horizontal, 12)
        .background(GeometryReader { g in Color.clear.preference(key: DockBottomKey.self, value: g.frame(in: .named("care")).maxY) })
    }

    @ViewBuilder private var tools: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if model.limb != nil && [.locate, .listening, .clarify].contains(model.step) && bandHeight >= 170 {
                    HStack(spacing: 0) {
                        ForEach(["front", "back", "inner", "outer"], id: \.self) { v in
                            Button(v.capitalized) { model.setLimbView(v) }
                                .font(LoferFont.ui(11)).padding(.horizontal, 9).padding(.vertical, 5)
                                .foregroundStyle(model.limbView == v ? Color.loferCream : Color.loferMuted)
                                .background(Capsule().fill(model.limbView == v ? Color.loferPeach.opacity(0.16) : .clear))
                        }
                    }
                    .padding(3).background(Capsule().fill(Color(hex: 0x181514).opacity(0.7))).overlay(Capsule().stroke(Color.loferLine))
                }
                if model.viewOffHome && bandHeight >= 170 {
                    Button("↻ Reset view") { model.resetView() }
                        .font(LoferFont.ui(11.5)).foregroundStyle(Color.loferMuted).padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color(hex: 0x181514).opacity(0.7))).overlay(Capsule().stroke(Color.loferLine2))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }
}

private struct DockBottomKey: PreferenceKey { static var defaultValue: CGFloat = 140; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }
private struct SheetTopKey: PreferenceKey { static var defaultValue: CGFloat = 600; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }

/// Talk / type, always at the bottom of the sheet. The small orb shows the voice state.
struct VoiceBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack {
            Button { app.keyboardTapped() } label: { Label("Type", systemImage: "keyboard").font(LoferFont.ui(12.5)).foregroundStyle(Color.loferMuted) }
            Spacer()
            VoiceOrb(state: app.voice.state, size: 110).frame(width: 64, height: 52).clipped().onTapGesture { app.micTapped() }
                .accessibilityAddTraits(.isButton).accessibilityLabel("Talk")
            Spacer()
            Text(app.voice.problem?.shortLabel ?? [.listening: "Listening…", .thinking: "Thinking…", .speaking: "Tap to interrupt"][app.voice.state] ?? "Tap to talk")
                .font(LoferFont.ui(12.5)).foregroundStyle(app.voice.state == .listening ? Color.loferPeach : Color.loferMuted)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color.loferLine).frame(height: 1) }
    }
}
