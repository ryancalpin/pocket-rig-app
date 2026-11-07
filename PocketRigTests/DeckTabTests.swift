import Testing
@testable import PocketRig

@Suite struct DeckTabTests {
    @Test func tabsComeInSwipeOrder() {
        #expect(DeckTab.allCases == [.gamepad, .trackpad, .quickMenu, .stats])
    }

    @Test func statsCanBeSwipedAcross() {
        #expect(DeckTab.stats.allowsContentSwipe)
    }

    @Test func dragHeavyTabsKeepTheirDrags() {
        #expect(DeckTab.allCases.first == .gamepad)
        #expect(DeckTab.gamepad.title == "Gamepad")
        #expect(!DeckTab.gamepad.allowsContentSwipe)
        #expect(!DeckTab.trackpad.allowsContentSwipe)
    }

    @Test func neighborsStopAtTheEnds() {
        #expect(DeckTab.neighbor(of: .gamepad, in: DeckTab.allCases, forward: true) == .trackpad)
        #expect(DeckTab.neighbor(of: .trackpad, in: DeckTab.allCases, forward: true) == .quickMenu)
        #expect(DeckTab.neighbor(of: .quickMenu, in: DeckTab.allCases, forward: true) == .stats)
        #expect(DeckTab.neighbor(of: .stats, in: DeckTab.allCases, forward: true) == nil)
        #expect(DeckTab.neighbor(of: .gamepad, in: DeckTab.allCases, forward: false) == nil)
    }

    @Test func aTabThatIsNotShownStartsFromTheFirst() {
        #expect(DeckTab.neighbor(of: .gamepad, in: [.trackpad], forward: true) == .trackpad)
    }

    @Test @MainActor func swipingMovesBetweenTabs() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.swipe(forward: true, in: DeckTab.allCases)
        #expect(model.tab == .trackpad)
        model.swipe(forward: true, in: DeckTab.allCases)
        #expect(model.tab == .quickMenu)
        model.swipe(forward: true, in: DeckTab.allCases)
        model.swipe(forward: true, in: DeckTab.allCases)
        #expect(model.tab == .stats)
    }

    @Test @MainActor func selectingAndControllerState() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.select(.gamepad)
        #expect(model.tab == .gamepad)
        model.controllerChanged(true)
        #expect(model.hasPhysicalController)
    }

    @Test func aLoneTabHasNoNeighbors() {
        #expect(DeckTab.neighbor(of: .gamepad, in: [.gamepad], forward: true) == nil)
        #expect(DeckTab.neighbor(of: .gamepad, in: [.gamepad], forward: false) == nil)
        #expect(DeckTab.neighbor(of: .gamepad, in: [], forward: true) == nil)
    }

    @Test func quickMenuCanBeSwipedAcross() {
        #expect(DeckTab.quickMenu.allowsContentSwipe)
    }

    @Test func aControllerArrivingMovesGamepadToQuickMenu() {
        #expect(DeckHandoff.afterControllerChange(current: .gamepad, autoSwitched: false, hasController: true)
                == DeckHandoff(tab: .quickMenu, autoSwitched: true))
    }

    @Test func aControllerArrivingElsewhereLeavesTheTab() {
        #expect(DeckHandoff.afterControllerChange(current: .stats, autoSwitched: false, hasController: true)
                == DeckHandoff(tab: .stats, autoSwitched: false))
    }

    @Test func theControllerLeavingGoesBackToGamepad() {
        #expect(DeckHandoff.afterControllerChange(current: .quickMenu, autoSwitched: true, hasController: false)
                == DeckHandoff(tab: .gamepad, autoSwitched: false))
    }

    @Test func theControllerLeavingAfterTheUserMovedOnStaysPut() {
        #expect(DeckHandoff.afterControllerChange(current: .stats, autoSwitched: true, hasController: false)
                == DeckHandoff(tab: .stats, autoSwitched: false))
    }

    @Test @MainActor func theDeckFollowsTheController() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.controllerChanged(true)
        #expect(model.tab == .quickMenu)
        model.controllerChanged(false)
        #expect(model.tab == .gamepad)
    }

    @Test @MainActor func pickingATabCancelsTheAutoReturn() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.controllerChanged(true)
        model.select(.stats)
        model.select(.quickMenu)
        model.controllerChanged(false)
        #expect(model.tab == .quickMenu)
    }

    @Test @MainActor func closingTheSidewaysMenuKeepsTheAutoReturn() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.controllerChanged(true)   // auto-switched to the Quick menu
        model.restore(.quickMenu)       // the sideways menu sheet closes and puts the same tab back
        model.controllerChanged(false)
        #expect(model.tab == .gamepad)
    }

    @Test @MainActor func restoringPutsBackTheEarlierTab() {
        let model = DeckModel(gamepad: GamepadInput(sender: NoOpControllerSender()))
        model.select(.trackpad)
        model.select(.stats)            // picked inside the sheet
        model.restore(.trackpad)
        #expect(model.tab == .trackpad)
    }
}
