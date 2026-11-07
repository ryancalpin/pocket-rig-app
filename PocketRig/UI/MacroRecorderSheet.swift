import SwiftUI

/// "Record a combo": press buttons on a practice pad; what you press, and when, becomes the combo.
struct MacroRecorderSheet: View {
    let pose: Pose
    let buttons: [ControlButton]
    let style: ControllerStyle
    let onSave: (Macro) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapticsStrength) private var hapticsStrength
    @State private var session = MacroRecordingSession()
    @State private var saves = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    // Capped like the stream's notes: at accessibility sizes it took so much height that the
                    // practice pad shrank until its top-row buttons overlapped. VoiceOver reads it in full.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityAddTraits(.updatesFrequently)
                TouchGamepadView(input: session.input, buttons: MacroRecorder.recordingPad(from: buttons),
                                 style: style, showsBackdrop: false)
                    .aspectRatio(DefaultLayouts.referenceSize(for: pose), contentMode: .fit)
                    .background(Color.black, in: .rect(cornerRadius: 16))
                    .frame(maxHeight: .infinity)
            }
            .padding(16)
            .background(Color.black.ignoresSafeArea())
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Record a combo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // In the toolbar (not a row under the pad) so the practice pad keeps every spare point on small screens.
                ToolbarItem(placement: .bottomBar) {
                    Button("Start over", systemImage: "arrow.counterclockwise") { session.startOver() }
                        .disabled(!session.recorder.hasPresses)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(session.finished())
                        saves += 1
                        dismiss()
                    }
                    .disabled(!session.recorder.hasPresses)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .sensoryFeedback(trigger: saves) { _, _ in
            hapticsStrength.tapIntensity.map { SensoryFeedback.impact(weight: .light, intensity: Double($0)) }
        }
        .interactiveDismissDisabled(session.recorder.hasPresses)
    }

    private var status: String {
        let recorder = session.recorder
        if recorder.isFull { return "That's as long as a combo can be. Tap Save." }
        if !recorder.hasPresses { return "Press the buttons in order. Timing counts; waiting before you start doesn't." }
        let count = recorder.pressCount
        return count == 1 ? "Recording: 1 press so far." : "Recording: \(count) presses so far."
    }
}
