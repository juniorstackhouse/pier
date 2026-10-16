/// A finite correction after explicitly following a lazy conversation's bottom. A scroll command can use an
/// estimated row height, so later layout may leave the viewport short of the bottom or beyond the content.
/// Geometry is sampled by the caller; it must never start or restart this sequence by itself.
public struct ConversationFollowSettlement: Sendable {
    public enum Action: Sendable, Equatable { case prime, scroll, wait, stop }

    public static let maximumChecks = 8
    private var checks = 0
    private var settledHeight: Double?
    private var finished = false
    private let primeFirst: Bool

    public init(primeFirst: Bool = false) { self.primeFirst = primeFirst }

    /// Call at spaced intervals, after allowing layout to finish. Two consecutive bottom readings with a stable
    /// content height confirm arrival. A negative distance also needs correction when the viewport overshot.
    public mutating func advance(distanceFromBottom: Double?, contentHeight: Double?, canFollow: Bool) -> Action {
        guard !finished else { return .stop }
        guard canFollow, checks < Self.maximumChecks else {
            finished = true
            return .stop
        }
        checks += 1
        // Always issue the requested command; geometry at entry can belong to the previous content.
        guard checks > 1 else { return primeFirst ? .prime : .scroll }
        // Measuring a real row is only preparation; always target the bottom afterward before accepting geometry.
        if primeFirst, checks == 2 { return .scroll }
        guard let distanceFromBottom, let contentHeight,
              distanceFromBottom.isFinite, contentHeight.isFinite, contentHeight > 0,
              abs(distanceFromBottom) <= 8 else {
            settledHeight = nil
            return .scroll
        }
        if let previous = settledHeight, abs(contentHeight - previous) <= 1 {
            finished = true
            return .stop
        }
        settledHeight = contentHeight
        return .wait
    }
}
