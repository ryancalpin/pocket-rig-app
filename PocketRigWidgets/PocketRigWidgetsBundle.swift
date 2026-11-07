import SwiftUI
import WidgetKit

@main
struct PocketRigWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LastGameWidget()
        ResumeGameControl()
        DownloadLiveActivity()
    }
}
