import Foundation

private let pveBase = "https://\(AppConfig.pveHost):8006/"
private let openScheme = "pvewidget"

/// Accepts only "<kind>/<id>" targets such as "node/pve" or "qemu/102".
private func isValidTarget(_ target: String) -> Bool {
    target.wholeMatch(of: /(node|qemu|lxc)\/[A-Za-z0-9._-]+/) != nil
}

/// Proxmox web UI URL for a resource, e.g. "qemu/102" -> ".../#v1:0:=qemu%2F102".
func pveURL(for target: String) -> URL? {
    guard isValidTarget(target),
          let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._")))
    else { return nil }
    return URL(string: pveBase + "#v1:0:=" + encoded)
}

/// App deep link used by widget taps: pvewidget://open?target=<kind>/<id>.
func widgetOpenURL(target: String) -> URL {
    var c = URLComponents()
    c.scheme = openScheme
    c.host = "open"
    c.queryItems = [URLQueryItem(name: "target", value: target)]
    return c.url!
}

/// Target from a deep link produced by `widgetOpenURL`, or nil for anything else.
func openTarget(from url: URL) -> String? {
    guard url.scheme == openScheme, url.host == "open",
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    return comps.queryItems?.first(where: { $0.name == "target" })?.value
}

/// A link opened without a visible window must not leave a windowless app running.
func shouldQuitAfterOpen(windowVisible: Bool) -> Bool { !windowVisible }
