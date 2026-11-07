import SwiftUI
import WidgetKit

/// Control Center (and Lock Screen / Action button) "Resume game".
struct ResumeGameControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: PocketRigShared.resumeControlKind) {
            ControlWidgetButton(action: ResumeLastGameIntent()) {
                Label("Resume game", systemImage: "gamecontroller.fill")
            }
        }
        .displayName("Resume last game")
        .description("Opens Pocket Rig and starts your last game again.")
    }
}
