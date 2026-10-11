import Foundation

/// Whether a pairing link's host is this very device: pierd running on this Mac, whose `pierd setup` hands its link to
/// the app here. Those links pair without the confirmation links from elsewhere get (they name this machine, which only
/// something already running on it can serve). Pure: the device's names and addresses are the caller's.
public enum LocalHost {
    public static func isThisDevice(_ host: String, names: [String], addresses: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return false }
        if h == "localhost" || h == "::1" || h.hasPrefix("127.") { return true }
        for n in names.map({ $0.lowercased() }) where !n.isEmpty {
            // "ana-mac", "ana-mac.local": the Bonjour name with or without its domain.
            if h == n || h == n + ".local" || h + ".local" == n { return true }
        }
        return addresses.contains { $0.lowercased() == h }
    }
}
