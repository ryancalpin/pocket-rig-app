import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(pcName: context.attributes.pcName, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.7))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadSymbol(state: context.state).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.percentText).font(.headline).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.name).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadDetail(pcName: context.attributes.pcName, state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                DownloadSymbol(state: context.state)
            } compactTrailing: {
                Text(context.state.percentText).font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                DownloadRing(state: context.state)
            }
            .keylineTint(.green)
        }
    }
}
