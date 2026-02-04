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
    
    private var cache: [String: AVPlayerItem] = [:]
    private let queue = DispatchQueue(label: "PreparedPlayerItemCache", attributes: .concurrent)
    
    private override init() {
        super.init()
    }
    
    /// Store a prepared AVPlayerItem for a URL
    @objc public func store(_ item: AVPlayerItem, forURL url: String) {
        queue.async(flags: .barrier) {
            self.cache[url] = item
            print("[PreparedPlayerItemCache] Stored item for: \(url) (total: \(self.cache.count))")
        }
    }
    
    /// Retrieve and remove a prepared AVPlayerItem for a URL
    /// Returns nil if no prepared item exists
    @objc public func retrieve(forURL url: String) -> AVPlayerItem? {
        var item: AVPlayerItem?
        queue.sync {
            item = self.cache[url]
        }
        if item != nil {
            queue.async(flags: .barrier) {
                self.cache.removeValue(forKey: url)
                print("[PreparedPlayerItemCache] ✅ Retrieved prepared item for: \(url) (remaining: \(self.cache.count))")
            }
        } else {
            print("[PreparedPlayerItemCache] No prepared item for: \(url)")
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
    
    /// Clear all cached items
    @objc public func clear() {
        queue.async(flags: .barrier) {
            let count = self.cache.count
            self.cache.removeAll()
            print("[PreparedPlayerItemCache] Cleared \(count) item(s)")
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
