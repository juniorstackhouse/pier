#if DEBUG
import UIKit
import PierKit

/// `-navPerfProbe 1`: walks the app through the screens people move between (the Home, sessions of the paired boxes,
/// the Inbox, the Board, Projetos, a project and a worktree), one step every 2.5 s, and measures each step the way a
/// person feels it: how long until the next frame showed (the main thread laying the new screen out) and the hitch time
/// over the following 2 s. Works with real boxes and with the mock. One line per step on stderr ("NAV-PERF {...}") and
/// a summary ("NAV-PERF-SUMMARY {...}"); run it with Instruments' Time Profiler attached to see where the time goes.
@MainActor
enum NavPerfProbe {
    static func runIfRequested(model: AppModel) {
        guard UserDefaults.standard.bool(forKey: "navPerfProbe") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))   // the boxes connect and list their sessions
            let router = model.router
            var steps: [(String, () -> Void)] = [("home", { router.select(.tab(.home)) })]
            let sessions = model.boxes.flatMap { b in b.sessions.filter(\.isAgent).prefix(4).map { (b.name, $0) } }
            let projects = model.boxes.flatMap { b in b.locations.prefix(2).map { (b.name, $0) } }
            for (i, (box, s)) in sessions.enumerated() {
                steps.append(("session\(i)", { router.openSession(box: box, session: s) }))
                steps.append(("home", { router.select(.tab(.home)) }))
            }
            steps.append(("inbox", { router.select(.tab(.inbox)) }))
            steps.append(("board", { router.select(.tab(.board)) }))
            steps.append(("projects", { router.select(.tab(.projects)) }))
            for (i, (box, l)) in projects.enumerated() {
                steps.append(("project\(i)", { router.select(.project(ProjectRoute(box: box, location: l.name))) }))
                if let wt = l.worktrees?.first {
                    steps.append(("worktree\(i)", { router.select(.worktree(WorktreeRoute(box: box, location: l.name, worktree: wt.name))) }))
                }
            }
            steps.append(("home", { router.select(.tab(.home)) }))
            var all: [[String: Any]] = []
            for (name, go) in steps {
                let recorder = StepRecorder()
                recorder.start()
                go()
                try? await Task.sleep(for: .milliseconds(2500))
                var r = recorder.stop()
                r["step"] = name
                all.append(r)
                let line = (try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])) ?? Data()
                FileHandle.standardError.write(Data("NAV-PERF ".utf8) + line + Data("\n".utf8))
            }
            func median(_ k: String) -> Double {
                let v = all.compactMap { $0[k] as? Double }.sorted()
                return v.isEmpty ? 0 : v[v.count / 2]
            }
            let summary: [String: Any] = ["steps": all.count, "median_first_frame_ms": median("first_frame_ms"),
                                          "max_first_frame_ms": all.compactMap { $0["first_frame_ms"] as? Double }.max() ?? 0,
                                          "median_hitch_ms": median("hitch_ms")]
            let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
            FileHandle.standardError.write(Data("NAV-PERF-SUMMARY ".utf8) + data + Data("\n".utf8))
        }
    }
}

/// Frames after one step: when the first came (from the step's start), the longest gap, and the time frames came late.
@MainActor
private final class StepRecorder: NSObject {
    private var link: CADisplayLink?
    private var t0: CFTimeInterval = 0
    private var first: CFTimeInterval?
    private var last: CFTimeInterval?
    private var hitch: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    private var frames = 0

    func start() {
        t0 = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        frames += 1
        if first == nil { first = now }
        if let last {
            let gap = now - last
            longest = max(longest, gap)
            let budget = l.targetTimestamp - l.timestamp
            if gap > budget * 1.5 { hitch += gap - budget }
        }
        last = now
    }

    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        func ms(_ t: CFTimeInterval) -> Double { (t * 10000).rounded() / 10 }
        return ["first_frame_ms": ms((first ?? t0) - t0), "longest_frame_ms": ms(longest), "hitch_ms": ms(hitch), "frames": frames]
    }
}
#endif
