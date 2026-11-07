import SwiftUI

/// Places the game picture and the deck for the current pose. Fills the whole window, because the
/// fold position arrives in window coordinates.
struct StreamLayoutView<Video: View>: View {
    @Environment(PoseMonitor.self) private var poses
    let deck: DeckModel
    let onClose: () -> Void
    let onGameAreaChange: (CGSize) -> Void
    let video: () -> Video
    @State private var showsDeckSheet = false
    @State private var tabBeforeSheet: DeckTab?

    init(deck: DeckModel, onClose: @escaping () -> Void, onGameAreaChange: @escaping (CGSize) -> Void = { _ in },
         @ViewBuilder video: @escaping () -> Video) {
        self.deck = deck
        self.onClose = onClose
        self.onGameAreaChange = onGameAreaChange
        self.video = video
    }

    var body: some View {
        // The outer reader keeps the safe area, so sideways buttons can stay clear of the rounded corners
        // and the Dynamic Island while the picture still fills the whole screen.
        GeometryReader { outer in
            content(safeArea: outer.safeAreaInsets)
        }
        .sheet(isPresented: $showsDeckSheet, onDismiss: restoreTab) {
            DeckView(model: deck, tabs: DeckTab.allCases.filter { $0 != .gamepad })
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
    }

    private func content(safeArea: EdgeInsets) -> some View {
        GeometryReader { geo in
            let pose = poses.pose.streamingPose(in: geo.size)
            let fold = PoseRegions.fold(poses.foldInWindow, containerOrigin: geo.frame(in: .global).origin)
            let regions = PoseRegions.make(pose: pose, size: geo.size, fold: fold)
            ZStack(alignment: .topLeading) {
                Color.black
                video()
                    .frame(width: regions.game.width, height: regions.game.height)
                    .clipped()
                    .offset(x: regions.game.minX, y: regions.game.minY)
                if let area = regions.deck {
                    DeckView(model: deck)
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                } else if !deck.hasPhysicalController {
                    // Sideways: see-through buttons straight over the game.
                    TouchGamepadView(input: deck.gamepad, buttons: deck.buttons, style: deck.style, showsBackdrop: false)
                        .padding(safeArea)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(deck.isLive)
                        .opacity(deck.isLive ? 1 : 0)
                }
            }
            // Sideways puts the left shoulder buttons top-left, so the close button moves to the middle.
            .overlay(alignment: pose == .sideways ? .top : .topLeading) {
                HStack(spacing: 8) {
                    CloseStreamButton(action: onClose)
                    if regions.deck == nil { menuButton }
                }
                .padding(16)
            }
            .onChange(of: regions.game.size, initial: true) { _, size in onGameAreaChange(size) }
        }
        .ignoresSafeArea()
    }

    /// Sideways has no deck, so the menu, trackpad and stats open in a sheet.
    private var menuButton: some View {
        Button {
            tabBeforeSheet = deck.tab
            if deck.tab == .gamepad { deck.select(.quickMenu) }
            showsDeckSheet = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Menu")
    }

    private func restoreTab() {
        if let tabBeforeSheet { deck.restore(tabBeforeSheet) }
        tabBeforeSheet = nil
    }
}

struct CloseStreamButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Close stream")
    }
}
