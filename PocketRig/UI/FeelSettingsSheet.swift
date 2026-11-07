import SwiftData
import SwiftUI

/// "Vibration & aiming": how strongly the phone vibrates, feel-the-sound, and tilt to aim. Changes apply
/// to a running stream straight away.
struct FeelSettingsSheet: View {
    @Bindable var settings: FeelSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize

    static let vibrationFooter = "How strongly the phone vibrates for game rumble and button taps. A connected controller rumbles at its own strength."
    static let soundFooter = "Turns the game's bass into vibration when the game isn't rumbling. It stays off while a controller is connected."
    static let noMotorNote = "This device can't vibrate, so these vibration settings do nothing here."

    static func aimFooter(for mode: GyroMode) -> String {
        switch mode {
        case .off: "Tilt the phone to aim, like moving the right stick or the mouse."
        case .rightStick: "Tilting moves the right stick. Your thumb still works on top of it."
        case .mouse: "Tilting moves the mouse pointer. Good for games that aim with the mouse."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    strengthPicker
                } header: {
                    Text("Phone vibration")
                } footer: {
                    Text(Self.vibrationFooter)
                }
                Section {
                    Toggle("Feel the sound", isOn: $settings.feelTheSound)
                        .disabled(settings.hapticsStrength == .off)
                } footer: {
                    Text(Self.soundFooter)
                }
                Section {
                    Picker("Tilt to aim", selection: $settings.gyroMode) {
                        ForEach(GyroMode.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.gyroMode != .off {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Sensitivity", value: FeelSettings.sensitivityTitle(settings.gyroSensitivity))
                            Slider(value: $settings.gyroSensitivity, in: FeelSettings.sensitivityRange, step: 0.25) {
                                Text("Sensitivity")
                            } minimumValueLabel: {
                                Image(systemName: "tortoise").accessibilityLabel("Slower")
                            } maximumValueLabel: {
                                Image(systemName: "hare").accessibilityLabel("Faster")
                            }
                            .accessibilityValue(FeelSettings.sensitivityTitle(settings.gyroSensitivity))
                        }
                        Toggle("Flip up and down", isOn: $settings.gyroInvertY)
                    }
                } header: {
                    Text("Aiming")
                } footer: {
                    Text(Self.aimFooter(for: settings.gyroMode))
                }
                if !PhoneHaptics.isSupported {
                    Section {
                        Label(Self.noMotorNote, systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Vibration & aiming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(trigger: settings.hapticsStrength) { _, new in
                new.tapIntensity == nil ? nil : SensoryFeedback.selection
            }
        }
        .presentationDetents([.medium, .large])
        // Dark like the rest of the stream screen, so the grey notes stay readable over the game.
        // (preferredColorScheme applies to this sheet's own presentation, not the window behind it.)
        .preferredColorScheme(.dark)
        .onDisappear { try? context.save() }
    }

    @ViewBuilder
    private var strengthPicker: some View {
        let picker = Picker("Strength", selection: $settings.hapticsStrength) {
            ForEach(HapticsStrength.allCases) { Text($0.title).tag($0) }
        }
        // Four segments don't fit at the largest text sizes.
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }
}
