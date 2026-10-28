import Foundation

/// Recognises a CDN block page standing in for an API response.
///
/// chatgpt.com and claude.ai sit behind Cloudflare, which can refuse an IP it
/// distrusts (often a VPN/proxy exit) with an HTML page — "Unable to load
/// site … If you are using a VPN, try turning it off" — and HTTP 403. Without
/// recognising it that looks like a generic server error ("err"), which sends
/// people looking for a bug in the app or a CLI update instead of at the route.
///
/// Deliberately narrow: only a 403 whose body is HTML *and* carries
/// Cloudflare's markers. A JSON 403 from the API itself, or Cloudflare's
/// 5xx outage pages, are not treated as a block.
public enum EdgeBlockDetector {
    public static func blockError(statusCode: Int, body: Data) -> UsageError? {
        guard statusCode == 403 else { return nil }
        let text = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
        let lower = text.lowercased()
        let isHTML = lower.contains("<html") || lower.contains("<!doctype html")
        let isCloudflare = lower.contains("ray id") || lower.contains("cloudflare")
            || lower.contains("unable to load site") || lower.contains("cf-error")
        guard isHTML, isCloudflare else { return nil }
        return .blockedByEdge(ip: blockedIP(in: text))
    }

    /// The client IP Cloudflare prints on the page ("IP: 45.141.79.41"), if any.
    static func blockedIP(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"IP:\s*([0-9A-Fa-f.:]{3,45})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
