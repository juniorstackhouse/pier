#if DEBUG
import SwiftUI

/// Only the synthetic chat lab opts into this counter. It records how many older-page requests happened, never
/// their offsets or contents. `before=0` (a dashboard's tail read) is not a request for earlier history.
enum ChatHistoryDiagnostics {
    static var enabled: Bool {
        UITestMock.enabled && MockChatLab.enabled && UserDefaults.standard.bool(forKey: "uiTestChatLabProbe")
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var beforeRequests = 0

    static func didRequestHistory() {
        guard enabled else { return }
        let count = lock.withLock { beforeRequests += 1; return beforeRequests }
        Task { @MainActor in
            // Requests can finish on different queues; an older update cannot move the counter backwards.
            ChatHistoryProbeModel.shared.count = max(ChatHistoryProbeModel.shared.count, count)
        }
    }
}

@MainActor @Observable
private final class ChatHistoryProbeModel {
    static let shared = ChatHistoryProbeModel()
    var count = 0
}

/// A one-point accessibility sentinel outside the scroll view. Observing it does not fold or lay out the record.
/// Absent unless the explicit mock-only launch flag is present; never included in a Release build.
@MainActor
struct ChatHistoryProbe: View {
    @State private var model = ChatHistoryProbeModel.shared

    var body: some View {
        if ChatHistoryDiagnostics.enabled {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("chat-history-before-count")
                .accessibilityLabel("Synthetic history requests")
                .accessibilityValue(String(model.count))
        }
    }
}
#endif
