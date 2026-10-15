import SwiftUI
import PierKit

/// Regular width (iPad, Mac): a sidebar (sections, projects grouped by the person's sections with their
/// worktrees and sessions, live state) and a detail column with the same screens and stacks as the iPhone's tabs.
struct MainSplit: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            // One stack per section, the same paths the tabs use: notifications and deep links land here unchanged.
            switch router.tab {
            case .home:
                NavigationStack(path: $router.homePath) { DashboardView().pierDestinations() }.macInstantPush(router.homePath)
            case .inbox:
                NavigationStack(path: $router.inboxPath) { InboxScreen().pierDestinations() }.macInstantPush(router.inboxPath)
            case .board:
                NavigationStack(path: $router.boardPath) { BoardScreen().pierDestinations() }.macInstantPush(router.boardPath)
            case .projects:
                NavigationStack(path: $router.projectsPath) { ProjectsRoot().pierDestinations() }.macInstantPush(router.projectsPath)
            case .settings:
                NavigationStack(path: $router.settingsPath) { SettingsView().pierDestinations() }.macInstantPush(router.settingsPath)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.projectsPath.count) { router.projectsPathChanged() }
    }
}

extension View {
    /// On the Mac a pushed screen replaces the current one at once, as in Finder or Mail: UIKit's sliding push laid out
    /// both screens and animated them for a third of a second on every navigation (measured at ~100 ms of main thread
    /// to set up, plus the animated frames). The iPad keeps the slide.
    @ViewBuilder func macInstantPush(_ path: NavigationPath) -> some View {
        if Platform.isMac {
            transaction(value: path) { $0.disablesAnimations = true }
        } else {
            self
        }
    }
}
