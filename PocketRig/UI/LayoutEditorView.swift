import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Drag, resize and fade the touch buttons for each position, for every game or just this one.
struct LayoutEditorView: View {
    let gameKey: String?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapticsStrength) private var hapticsStrength
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pose: Pose
    /// Per pose: is its draft saved for this game only? Starts from what is saved.
    @State private var scopes: [Pose: Bool] = [:]
    @State private var initialScopes: [Pose: Bool] = [:]
    @State private var drafts: [Pose: Draft] = [:]
    @State private var loaded: [Pose: Draft] = [:]
    @State private var selection: UUID?
    @State private var dragStart: ControlButton?
    @State private var resizeStart: ControlButton?
    @State private var confirmReset = false
    @State private var saveFailed = false
    /// Canvas glyph sizes at the default text size: body 17, caption 12, caption 2 11 (see `ControlGlyph`).
    @ScaledMetric(relativeTo: .body) private var symbolGlyphSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var titleGlyphSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var badgeGlyphSize: CGFloat = 11
    @State private var importing = false
    @State private var importMessage: String?
    /// The button whose combo is being recorded.
    @State private var recording: RecordingTarget?

    struct RecordingTarget: Identifiable {
        let id: UUID
    }

    struct Draft: Equatable {
        var buttons: [ControlButton]
        var style: ControllerStyle
    }

    init(pose: Pose, gameKey: String?) {
        self.gameKey = gameKey
        _pose = State(initialValue: pose.layoutPose)
    }

    private var store: LayoutStore { LayoutStore(context: context) }
    private var onlyThisGame: Bool { scopes[pose] ?? false }
    private var editsThisGame: Bool { gameKey != nil && onlyThisGame }

    /// Turning the switch on or off keeps edits the user already made; an untouched draft is reloaded
    /// from the level it now belongs to.
    private var scopeBinding: Binding<Bool> {
        Binding(get: { onlyThisGame }, set: { setScope($0) })
    }

    private var draft: Draft {
        drafts[pose] ?? Draft(buttons: LayoutStore.builtIn(pose: pose).buttons, style: .xbox)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { screen in
                let wide = screen.size.width > screen.size.height * 1.2
                VStack(spacing: 16) {
                    Picker("Button labels", selection: styleBinding) {
                        ForEach(ControllerStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if wide {
                        // Short, wide screens: canvas beside the controls so it keeps its size.
                        HStack(alignment: .top, spacing: 16) {
                            canvas
                            ScrollView {
                                VStack(spacing: 16) {
                                    if gameKey != nil {
                                        Toggle("Only for this game", isOn: scopeBinding)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    inspector
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 2)
                            }
                            .frame(maxWidth: screen.size.width * 0.4)
                        }
                    } else {
                        if gameKey != nil {
                            Toggle("Only for this game", isOn: scopeBinding)
                        }
                        canvas
                        // The inspector can be tall now; it scrolls so the canvas keeps its room.
                        ScrollView {
                            VStack(spacing: 16) { inspector }
                                .frame(maxWidth: .infinity)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: selection == nil ? 120 : screen.size.height * 0.42)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Edit buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) { posePicker }
                ToolbarItem(placement: .topBarTrailing) { shareMenu }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear(perform: prepare)
        .onChange(of: pose) { _, newPose in
            loadDraft(for: newPose)
            selection = nil
        }
        .confirmationDialog("Reset the \(pose.title) buttons?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(editsThisGame ? "This game goes back to your everyday \(pose.title) buttons."
                               : "The \(pose.title) buttons go back to the standard layout.")
        }
        .alert("Couldn't save your buttons", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pocketRigLayout, .json]) { result in
            handleImport(result)
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil },
                                                         set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sensoryFeedback(trigger: selection) { _, _ in
            hapticsStrength.tapIntensity == nil ? nil : SensoryFeedback.selection
        }
        .fullScreenCover(item: $recording) { target in
            MacroRecorderSheet(pose: pose, buttons: draft.buttons, style: draft.style) { macro in
                updateButton(target.id) {
                    $0.behavior = .macro
                    $0.macro = macro
                }
            }
        }
    }

    // MARK: Pieces

    private var currentFile: LayoutFile {
        LayoutFile(name: "\(pose.title) buttons", pose: pose, style: draft.style, buttons: draft.buttons)
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: currentFile, preview: SharePreview(currentFile.name)) {
                Label("Share these buttons", systemImage: "square.and.arrow.up")
            }
            Button("Import buttons…", systemImage: "square.and.arrow.down") { importing = true }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Share or import buttons")
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= LayoutFile.maximumBytes else { throw LayoutFile.ImportError.unreadable }
            let file = try LayoutFile.decode(Data(contentsOf: url))
            loadDraft(for: file.pose)
            drafts[file.pose] = Draft(buttons: file.buttons, style: file.style)
            pose = file.pose
            selection = nil
            let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
            importMessage = name.isEmpty
                ? "Loaded a layout for \(file.pose.title). Tap Save to keep it."
                : "Loaded “\(name)” for \(file.pose.title). Tap Save to keep it."
        } catch let error as LayoutFile.ImportError {
            importMessage = error.message
        } catch {
            importMessage = "Couldn't open that file. Try again."
        }
    }

    private var posePicker: some View {
        Menu {
            Picker("Position", selection: $pose) {
                ForEach(Pose.layoutPoses) { Label($0.title, systemImage: symbol(for: $0)).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                // Big text on a small phone: the name overlapped Cancel and Save, so only the icon shows
                // (VoiceOver still reads "Position: Upright").
                if typeSize.isAccessibilitySize {
                    Label(pose.title, systemImage: symbol(for: pose)).labelStyle(.iconOnly)
                } else {
                    Label(pose.title, systemImage: symbol(for: pose)).labelStyle(.titleAndIcon)
                }
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.headline)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Position: \(pose.title)")
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = fitted(DefaultLayouts.referenceSize(for: pose), in: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .onTapGesture { selection = nil }
                ForEach(draft.buttons) { button in
                    editorControl(button, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let button = draft.buttons.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.style.face(for: button.kind).name).font(.headline)
                Slider(value: opacityBinding(id), in: ControlButton.minimumOpacity...1) {
                    Text("Visibility")
                } minimumValueLabel: {
                    Image(systemName: "eye.slash").accessibilityLabel("See-through")
                } maximumValueLabel: {
                    Image(systemName: "eye").accessibilityLabel("Solid")
                }
                Toggle("Hide this button", isOn: hiddenBinding(id))
                if button.kind.supportsSpecialBehavior {
                    behaviorControls(button)
                }
                copyControls(button)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            Text("Tap a button to change it. Drag to move it. Drag the yellow corner to resize it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        HStack {
            Spacer()
            Button("Reset to standard", systemImage: "arrow.counterclockwise") { confirmReset = true }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private func behaviorControls(_ button: ControlButton) -> some View {
        // Side by side when it fits; stacked on narrow screens so "Normal" never breaks mid-word.
        let behaviorPicker = Menu {
            Picker("What it does", selection: behaviorBinding(button.id)) {
                ForEach(ButtonBehavior.allCases) { behavior in
                    Label(behavior.title, systemImage: behavior.badgeSymbol ?? "hand.tap").tag(behavior)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: button.behavior.badgeSymbol ?? "hand.tap")
                Text(button.behavior.title).lineLimit(1).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel("What it does")
        .accessibilityValue(button.behavior.title)
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("What it does")
                Spacer(minLength: 8)
                behaviorPicker
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What it does")
                behaviorPicker
            }
        }
        .frame(minHeight: 44)
        Text(button.behavior.explanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        switch button.behavior {
        case .turbo:
            LabeledContent("Speed") {
                Picker("Speed", selection: turboBinding(button.id)) {
                    ForEach(ButtonBehavior.turboOptions(including: button.turboHz), id: \.self) { hz in
                        Text(ButtonBehavior.turboTitle(hz)).tag(hz)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .frame(minHeight: 44)
        case .macro:
            ViewThatFits(in: .horizontal) {
                HStack {
                    comboSummary(button)
                    Spacer()
                    recordButton(button)
                }
                VStack(alignment: .leading, spacing: 8) {
                    comboSummary(button)
                    recordButton(button)
                }
            }
        case .normal, .toggle:
            EmptyView()
        }
    }

    private func comboSummary(_ button: ControlButton) -> some View {
        Text(button.macro.flatMap { $0.isEmpty ? nil : $0.summary() } ?? "No combo yet. Record one.")
            .font(.subheadline)
    }

    private func recordButton(_ button: ControlButton) -> some View {
        Button((button.macro?.isEmpty ?? true) ? "Record" : "Record again", systemImage: "record.circle") {
            recording = RecordingTarget(id: button.id)
        }
        .buttonStyle(.glass)
        .frame(minHeight: 44)
    }

    private func copyControls(_ button: ControlButton) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                addCopyButton(button)
                removeButton(button)
            }
            VStack(alignment: .leading, spacing: 8) {
                addCopyButton(button)
                removeButton(button)
            }
        }
    }

    private func addCopyButton(_ button: ControlButton) -> some View {
        Button("Add a copy", systemImage: "plus.square.on.square") { addCopy(of: button) }
            .buttonStyle(.glass)
            .frame(minHeight: 44)
            .disabled(!LayoutEditing.canAddCopy(to: draft.buttons))
    }

    @ViewBuilder
    private func removeButton(_ button: ControlButton) -> some View {
        if LayoutEditing.canRemove(button, from: draft.buttons) {
            Button("Remove", systemImage: "trash", role: .destructive) { remove(button) }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
        }
    }

    /// Smallest touch area for a control on the editor canvas, whatever its drawn size.
    static let minimumTouchSide: CGFloat = 44

    @ViewBuilder
    private func editorControl(_ button: ControlButton, in size: CGSize) -> some View {
        let rect = displayRect(button, in: size)
        let face = draft.style.face(for: button.kind)
        let isSelected = selection == button.id
        let shape = button.kind.keepsAspect ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8))
        ZStack {
            shape.fill(Color.white.opacity(button.isHidden ? 0.05 : 0.25))
            shape.stroke(isSelected ? Color.yellow : Color.white.opacity(0.6),
                         style: StrokeStyle(lineWidth: isSelected ? 3 : 1, dash: button.isHidden ? [4, 4] : []))
            controlGlyph(button, face: face, size: rect.size)
            if let badge = button.behavior.badgeSymbol {
                Image(systemName: badge)
                    .font(.system(size: ControlGlyph.pointSize(scaled: badgeGlyphSize, control: rect.size,
                                                               share: ControlGlyph.maxBadgeShare), weight: .bold))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(2)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .frame(width: rect.width, height: rect.height)
        .opacity(button.isHidden ? 0.6 : button.opacity)
        .overlay(alignment: .bottomTrailing) {
            if isSelected { resizeHandle(button, in: size) }
        }
        // The canvas is scaled down (about half size on iPhone SE), so the drawn control can be smaller
        // than a finger. The touch area never is; the selected control sits on top where areas overlap.
        .frame(width: max(rect.width, Self.minimumTouchSide), height: max(rect.height, Self.minimumTouchSide))
        .contentShape(Rectangle())
        .zIndex(isSelected ? 1 : 0)
        .onTapGesture { selection = button.id }
        .gesture(moveGesture(button, in: size))
        .accessibilityElement()
        .accessibilityLabel(accessibilityName(for: button, face: face))
        .accessibilityValue(button.isHidden ? "Hidden" : "\(Int((button.opacity * 100).rounded())) percent visible")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = button.id }
        .accessibilityAction(named: "Move left") { nudge(button, dx: -1, dy: 0, in: size) }
        .accessibilityAction(named: "Move right") { nudge(button, dx: 1, dy: 0, in: size) }
        .accessibilityAction(named: "Move up") { nudge(button, dx: 0, dy: -1, in: size) }
        .accessibilityAction(named: "Move down") { nudge(button, dx: 0, dy: 1, in: size) }
        .accessibilityAction(named: "Larger") { grow(button, by: 1, in: size) }
        .accessibilityAction(named: "Smaller") { grow(button, by: -1, in: size) }
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func controlGlyph(_ button: ControlButton, face: ControlFace, size: CGSize) -> some View {
        // The canvas is scaled down, so the glyph is capped by the drawn control, not only by the text size.
        let symbolFont = Font.system(size: ControlGlyph.pointSize(scaled: symbolGlyphSize, control: size))
        if button.isHidden {
            Image(systemName: "eye.slash").font(symbolFont)
        } else if let symbol = face.symbol {
            Image(systemName: symbol).font(symbolFont)
        } else if let title = face.title {
            Text(title)
                .font(.system(size: ControlGlyph.pointSize(scaled: titleGlyphSize, control: size), weight: .bold))
                .minimumScaleFactor(0.5).lineLimit(1)
        } else {
            Group {
                switch button.kind {
                case .dpad: Image(systemName: "dpad")
                case .leftStick: Image(systemName: "l.joystick")
                default: Image(systemName: "r.joystick")
                }
            }
            .font(symbolFont)
        }
    }

    private func resizeHandle(_ button: ControlButton, in size: CGSize) -> some View {
        Circle()
            .fill(Color.yellow)
            .frame(width: 16, height: 16)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: 22, y: 22)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if resizeStart?.id != button.id { resizeStart = button }
                        guard let start = resizeStart else { return }
                        replace(LayoutEditing.resize(start, by: value.translation, in: size, scale: scale(for: size)))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .accessibilityLabel("Resize")
    }

    private func moveGesture(_ button: ControlButton, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragStart?.id != button.id {
                    dragStart = button
                    selection = button.id
                }
                guard let start = dragStart else { return }
                replace(LayoutEditing.move(start, by: value.translation, in: size))
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Geometry

    /// Canvas points per real deck point.
    private func scale(for size: CGSize) -> CGFloat {
        let reference = DefaultLayouts.referenceSize(for: pose)
        return reference.width > 0 ? size.width / reference.width : 1
    }

    /// VoiceOver steps are 5% of the canvas's shorter side.
    private func step(in size: CGSize) -> CGFloat { min(size.width, size.height) * 0.05 }

    /// Kept out of the view chain: written inline, it can time out the type checker on a busy machine.
    private func accessibilityName(for button: ControlButton, face: ControlFace) -> String {
        if button.behavior == .normal { return face.name }
        return "\(face.name), \(button.behavior.title)"
    }

    private func nudge(_ button: ControlButton, dx: CGFloat, dy: CGFloat, in size: CGSize) {
        selection = button.id
        let amount = step(in: size)
        replace(LayoutEditing.move(button, by: CGSize(width: dx * amount, height: dy * amount), in: size))
    }

    private func grow(_ button: ControlButton, by direction: CGFloat, in size: CGSize) {
        selection = button.id
        let amount = step(in: size) * direction
        replace(LayoutEditing.resize(button, by: CGSize(width: amount, height: amount), in: size, scale: scale(for: size)))
    }

    private func fitted(_ reference: CGSize, in available: CGSize) -> CGSize {
        guard reference.width > 0, reference.height > 0 else { return available }
        let scale = min(available.width / reference.width, available.height / reference.height)
        return CGSize(width: reference.width * scale, height: reference.height * scale)
    }

    /// Where the button sits on the scaled-down canvas (round controls drawn square).
    private func displayRect(_ button: ControlButton, in size: CGSize) -> CGRect {
        let rect = button.frame.rect(in: size)
        guard button.kind.keepsAspect else { return rect }
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    private func symbol(for pose: Pose) -> String {
        switch pose {
        case .laptop: "laptopcomputer"
        case .book: "book"
        case .sideways: "iphone.landscape"
        case .upright, .cover: "iphone"
        }
    }

    // MARK: Drafts

    private var styleBinding: Binding<ControllerStyle> {
        Binding(get: { draft.style }, set: { style in updateDraft { $0.style = style } })
    }

    private func opacityBinding(_ id: UUID) -> Binding<Double> {
        Binding(get: { draft.buttons.first { $0.id == id }?.opacity ?? 1 },
                set: { value in updateButton(id) { $0.opacity = value } })
    }

    private func hiddenBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { draft.buttons.first { $0.id == id }?.isHidden ?? false },
                set: { value in updateButton(id) { $0.isHidden = value } })
    }

    private func behaviorBinding(_ id: UUID) -> Binding<ButtonBehavior> {
        Binding(get: { draft.buttons.first { $0.id == id }?.behavior ?? .normal },
                set: { value in
                    updateButton(id) { $0.behavior = value }
                    // A combo needs recording before it does anything.
                    if value == .macro, draft.buttons.first(where: { $0.id == id })?.macro?.isEmpty ?? true {
                        recording = RecordingTarget(id: id)
                    }
                })
    }

    private func turboBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { draft.buttons.first { $0.id == id }?.turboHz ?? ButtonBehavior.defaultTurboHz },
                set: { value in updateButton(id) { $0.turboHz = ButtonBehavior.clampedTurboHz(value) } })
    }

    private func addCopy(of button: ControlButton) {
        let copy = LayoutEditing.copy(of: button, in: DefaultLayouts.referenceSize(for: pose))
        updateDraft { $0.buttons.append(copy) }
        selection = copy.id
    }

    private func remove(_ button: ControlButton) {
        updateDraft { $0.buttons.removeAll { $0.id == button.id } }
        selection = nil
    }

    private func updateDraft(_ change: (inout Draft) -> Void) {
        var next = draft
        change(&next)
        drafts[pose] = next
    }

    private func updateButton(_ id: UUID, _ change: (inout ControlButton) -> Void) {
        updateDraft { d in
            if let i = d.buttons.firstIndex(where: { $0.id == id }) { change(&d.buttons[i]) }
        }
    }

    private func replace(_ button: ControlButton) {
        updateButton(button.id) { $0 = button }
    }

    private func loadDraft(for pose: Pose) {
        guard drafts[pose] == nil else { return }
        let resolved = store.resolve(pose: pose, gameKey: gameKey)
        let draft = Draft(buttons: resolved.buttons, style: resolved.style)
        drafts[pose] = draft
        loaded[pose] = draft
        let game = gameKey != nil && store.saved(pose: pose, gameKey: gameKey) != nil
        scopes[pose] = game
        initialScopes[pose] = game
    }

    private func setScope(_ onlyThisGame: Bool) {
        guard scopes[pose] != onlyThisGame else { return }
        scopes[pose] = onlyThisGame
        guard drafts[pose] == loaded[pose] else { return }   // keep the user's edits
        let source = onlyThisGame ? store.resolve(pose: pose, gameKey: gameKey)
                                  : store.resolve(pose: pose, gameKey: nil)
        let fresh = Draft(buttons: source.buttons, style: source.style)
        drafts[pose] = fresh
        loaded[pose] = fresh
        selection = nil
    }

    private func prepare() {
        loadDraft(for: pose)
        #if DEBUG
        // `-pr.editorSelect leftStick`: start with a button selected (screenshots of the handle and inspector).
        if let kind = DebugLaunchOptions.text("editorSelect").flatMap(ControlKind.init(rawValue:)) {
            selection = draft.buttons.first { $0.kind == kind }?.id
        }
        // `-pr.openMacroRecorder YES`: open "Record a combo" for the selected button (or Y).
        if DebugLaunchOptions.flag("openMacroRecorder"),
           let id = selection ?? draft.buttons.first(where: { $0.kind == .faceNorth })?.id {
            recording = RecordingTarget(id: id)
        }
        #endif
    }

    private func reset() {
        let base = editsThisGame ? store.fallback(pose: pose, gameKey: gameKey) : LayoutStore.builtIn(pose: pose)
        updateDraft { $0 = Draft(buttons: base.buttons, style: base.style) }
        selection = nil
    }

    private func save() {
        // Only poses the user changed (a different draft or a different scope) are written.
        var edits: [Pose: LayoutStore.PoseEdit] = [:]
        for (pose, draft) in drafts where draft != loaded[pose] || scopes[pose] != initialScopes[pose] {
            edits[pose] = LayoutStore.PoseEdit(buttons: draft.buttons, style: draft.style,
                                               onlyThisGame: gameKey != nil && (scopes[pose] ?? false))
        }
        do {
            try store.commit(edits, gameKey: gameKey)
            if hapticsStrength.tapIntensity != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
