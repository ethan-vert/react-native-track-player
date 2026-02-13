//
//  PreparedPlayerItemCache.swift
//  RNTrackPlayer
//
//  Global cache for pre-buffered AVPlayerItems.
//  This enables the addAndPrepare functionality by allowing
//  the patched AVPlayerWrapper to use pre-buffered items.
//
//  The patched AVPlayerWrapper accesses this cache via Objective-C runtime.
//

import Foundation
import AVFoundation

/// Global cache for pre-buffered AVPlayerItems
/// Used by addAndPrepare to store items, and by patched AVPlayerWrapper to retrieve them
@objc(PreparedPlayerItemCache)
public class PreparedPlayerItemCache: NSObject {
    @objc public static let shared = PreparedPlayerItemCache()
    public static var beforeRetrieve: ((String) -> Void)?
    
    private var cache: [String: AVPlayerItem] = [:]
    private let queue = DispatchQueue(label: "PreparedPlayerItemCache", attributes: .concurrent)
    
    private override init() {
        super.init()
    }
    
    /// Store a prepared AVPlayerItem for a URL
    @objc public func store(_ item: AVPlayerItem, forURL url: String) {
        queue.async(flags: .barrier) {
            self.cache[url] = item
        }
    }
    
    /// Retrieve and remove a prepared AVPlayerItem for a URL
    /// Returns nil if no prepared item exists
    @objc public func retrieve(forURL url: String) -> AVPlayerItem? {
        // Allow RNTrackPlayer to detach any warmup AVPlayer holding this item
        // before AVPlayerWrapper attaches it to the active AVPlayer.
        let shortUrl = url.count > 80 ? String(url.prefix(80)) + "..." : url
        print("[PreparedCache] ↔️ beforeRetrieve hook: \(PreparedPlayerItemCache.beforeRetrieve == nil ? "nil" : "set") url=\(shortUrl)")
        PreparedPlayerItemCache.beforeRetrieve?(url)

        var item: AVPlayerItem?
        queue.sync(flags: .barrier) {
            item = self.cache.removeValue(forKey: url)
        }
        if let found = item {
            let ranges = found.loadedTimeRanges.compactMap { $0.timeRangeValue }
            let rangesStr = ranges.enumerated().map { idx, range in
                let start = CMTimeGetSeconds(range.start)
                let dur = CMTimeGetSeconds(range.duration)
                let end = CMTimeGetSeconds(range.end)
                return "#\(idx){\(String(format: "%.2f", start))→\(String(format: "%.2f", end)) d=\(String(format: "%.2f", dur))}"
            }.joined(separator: ", ")
            let firstBuffered = ranges.first.map { CMTimeGetSeconds($0.duration) } ?? 0
            let totalBuffered = ranges.reduce(0.0) { acc, r in acc + max(0, CMTimeGetSeconds(r.duration)) }
            let dur = found.duration
            let durStr = CMTIME_IS_INDEFINITE(dur) || CMTIME_IS_INVALID(dur)
                ? "indefinite"
                : String(format: "%.2fs", CMTimeGetSeconds(dur))
            let accessEvents = found.accessLog()?.events.count ?? 0
            print(
                "[PreparedCache] ✅ HIT url=\(shortUrl) " +
                "status=\(found.status.rawValue) keepUp=\(found.isPlaybackLikelyToKeepUp) " +
                "bufEmpty=\(found.isPlaybackBufferEmpty) bufFull=\(found.isPlaybackBufferFull) " +
                "first=\(String(format: "%.2f", firstBuffered))s total=\(String(format: "%.2f", totalBuffered))s " +
                "ranges=[\(rangesStr.isEmpty ? "none" : rangesStr)] dur=\(durStr) accessEvents=\(accessEvents)"
            )
        } else {
            let shortUrl = url.count > 80 ? String(url.prefix(80)) + "..." : url
            print("[PreparedCache] ❌ MISS — \(shortUrl)")
        }
        return item
    }
    
    /// Check if a prepared item exists for a URL (without removing it)
    @objc public func has(url: String) -> Bool {
        var exists = false
        queue.sync {
            exists = self.cache[url] != nil
        }
        return exists
    }

    /// Remove a prepared item for a URL (if present)
    @objc public func remove(forURL url: String) {
        queue.sync(flags: .barrier) {
            self.cache.removeValue(forKey: url)
        }
    }
    
    /// Clear all cached items
    @objc public func clear() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
    
    /// Get the number of cached items
    @objc public var count: Int {
        var c = 0
        queue.sync {
            c = self.cache.count
        }
        return c
    }
}
