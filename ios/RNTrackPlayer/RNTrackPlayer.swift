//
//  RNTrackPlayer.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 13.08.17.
//  Copyright © 2017 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import AVFoundation
import SwiftAudioEx

@objc(RNTrackPlayer)
public class RNTrackPlayer: RCTEventEmitter, AudioSessionControllerDelegate {

    // MARK: - Attributes

    private var hasInitialized = false
    private let player = QueuedAudioPlayer()
    private let audioSessionController = AudioSessionController.shared
    private var shouldEmitProgressEvent: Bool = false
    private var shouldResumePlaybackAfterInterruptionEnds: Bool = false
    private var forwardJumpInterval: NSNumber? = nil;
    private var backwardJumpInterval: NSNumber? = nil;
    private var sessionCategory: AVAudioSession.Category = .playback
    private var sessionCategoryMode: AVAudioSession.Mode = .default
    private var sessionCategoryPolicy: AVAudioSession.RouteSharingPolicy = .default
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions = []
    // Store prepared player items to prevent them from being deallocated during async loading
    // Using AVPlayerItem instead of AVURLAsset ensures the loading isn't cancelled
    private var preparedPlayerItems: [String: AVPlayerItem] = [:]
    // Hidden warmup players that drive network reads for upcoming stream-chunk items.
    private var streamWarmupPlayers: [String: AVPlayer] = [:]
    private var streamWarmupStartTimes: [String: Date] = [:]
    private let enableStreamWarmupPlayers = false
    private let streamWarmupTargetSeconds: Double = 1.5
    private let streamWarmupPollIntervalSeconds: Double = 0.25
    private let streamWarmupMaxWaitSeconds: Double = 25.0

    // MARK: - Lifecycle Methods

    public override init() {
        super.init()
        EventEmitter.shared.register(eventEmitter: self)
        audioSessionController.delegate = self
        PreparedPlayerItemCache.beforeRetrieve = enableStreamWarmupPlayers
            ? { [weak self] url in
                _ = self?.detachStreamWarmupBestEffort(for: url, reason: "handoff")
            }
            : nil
        player.playWhenReady = false;
        player.event.receiveChapterMetadata.addListener(self, handleAudioPlayerChapterMetadataReceived)
        player.event.receiveTimedMetadata.addListener(self, handleAudioPlayerTimedMetadataReceived)
        player.event.receiveCommonMetadata.addListener(self, handleAudioPlayerCommonMetadataReceived)
        player.event.stateChange.addListener(self, handleAudioPlayerStateChange)
        player.event.fail.addListener(self, handleAudioPlayerFailed)
        player.event.currentItem.addListener(self, handleAudioPlayerCurrentItemChange)
        player.event.secondElapse.addListener(self, handleAudioPlayerSecondElapse)
        player.event.playWhenReadyChange.addListener(self, handlePlayWhenReadyChange)
    }

    deinit {
        PreparedPlayerItemCache.beforeRetrieve = nil
        reset(resolve: { _ in }, reject: { _, _, _  in })
    }

    // MARK: - RCTEventEmitter

    override public static func requiresMainQueueSetup() -> Bool {
        return true;
    }

    @objc(constantsToExport)
    override public func constantsToExport() -> [AnyHashable: Any] {
        return [
            "STATE_NONE": State.none.rawValue,
            "STATE_READY": State.ready.rawValue,
            "STATE_PLAYING": State.playing.rawValue,
            "STATE_PAUSED": State.paused.rawValue,
            "STATE_STOPPED": State.stopped.rawValue,
            "STATE_BUFFERING": State.buffering.rawValue,
            "STATE_LOADING": State.loading.rawValue,
            "STATE_ERROR": State.error.rawValue,

            "TRACK_PLAYBACK_ENDED_REASON_END": PlaybackEndedReason.playedUntilEnd.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_JUMPED": PlaybackEndedReason.jumpedToIndex.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_NEXT": PlaybackEndedReason.skippedToNext.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_PREVIOUS": PlaybackEndedReason.skippedToPrevious.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_STOPPED": PlaybackEndedReason.playerStopped.rawValue,

            "PITCH_ALGORITHM_LINEAR": PitchAlgorithm.linear.rawValue,
            "PITCH_ALGORITHM_MUSIC": PitchAlgorithm.music.rawValue,
            "PITCH_ALGORITHM_VOICE": PitchAlgorithm.voice.rawValue,

            "CAPABILITY_PLAY": Capability.play.rawValue,
            "CAPABILITY_PLAY_FROM_ID": "NOOP",
            "CAPABILITY_PLAY_FROM_SEARCH": "NOOP",
            "CAPABILITY_PAUSE": Capability.pause.rawValue,
            "CAPABILITY_STOP": Capability.stop.rawValue,
            "CAPABILITY_SEEK_TO": Capability.seek.rawValue,
            "CAPABILITY_SKIP": "NOOP",
            "CAPABILITY_SKIP_TO_NEXT": Capability.next.rawValue,
            "CAPABILITY_SKIP_TO_PREVIOUS": Capability.previous.rawValue,
            "CAPABILITY_SET_RATING": "NOOP",
            "CAPABILITY_JUMP_FORWARD": Capability.jumpForward.rawValue,
            "CAPABILITY_JUMP_BACKWARD": Capability.jumpBackward.rawValue,
            "CAPABILITY_LIKE": Capability.like.rawValue,
            "CAPABILITY_DISLIKE": Capability.dislike.rawValue,
            "CAPABILITY_BOOKMARK": Capability.bookmark.rawValue,

            "REPEAT_OFF": RepeatMode.off.rawValue,
            "REPEAT_TRACK": RepeatMode.track.rawValue,
            "REPEAT_QUEUE": RepeatMode.queue.rawValue,
        ]
    }

    @objc(supportedEvents)
    override public func supportedEvents() -> [String] {
        return EventType.allRawValues()
    }

    private func emit(event: EventType, body: Any? = nil) {
        EventEmitter.shared.emit(event: event, body: body)
    }

    // MARK: - AudioSessionControllerDelegate

    public func handleInterruption(type: InterruptionType) {
        switch type {
        case .began:
            // Interruption began, take appropriate actions (save state, update user interface)
            emit(event: EventType.RemoteDuck, body: [
                "paused": true
            ])
        case let .ended(shouldResume):
            if shouldResume {
                if (shouldResumePlaybackAfterInterruptionEnds) {
                    player.play()
                }
                // Interruption Ended - playback should resume
                emit(event: EventType.RemoteDuck, body: [
                    "paused": false
                ])
            } else {
                // Interruption Ended - playback should NOT resume
                emit(event: EventType.RemoteDuck, body: [
                    "paused": true,
                    "permanent": true
                ])
            }
        }
    }

    // MARK: - Bridged Methods

    private func rejectWhenNotInitialized(reject: RCTPromiseRejectBlock) -> Bool {
        let rejected = !hasInitialized;
        if (rejected) {
            reject("player_not_initialized", "The player is not initialized. Call setupPlayer first.", nil)
        }
        return rejected;
    }

    private func rejectWhenTrackIndexOutOfBounds(
        index: Int,
        min: Int? = nil,
        max : Int? = nil,
        message : String? = "The track index is out of bounds",
        reject: RCTPromiseRejectBlock
    ) -> Bool {
        let rejected = index < (min ?? 0) || index > (max ?? player.items.count - 1);
        if (rejected) {
            reject("index_out_of_bounds", message, nil)
        }
        return rejected
    }

    @objc(setupPlayer:resolver:rejecter:)
    public func setupPlayer(config: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if hasInitialized {
            reject("player_already_initialized", "The player has already been initialized via setupPlayer.", nil)
            return
        }

        // configure buffer size
        if let bufferDuration = config["minBuffer"] as? TimeInterval {
            player.bufferDuration = bufferDuration
        }

        if let autoHandleInterruptions = config["autoHandleInterruptions"] as? Bool {
            self.shouldResumePlaybackAfterInterruptionEnds = autoHandleInterruptions
        }

        // configure wether player waits to play (deprecated)
        if let waitForBuffer = config["waitForBuffer"] as? Bool {
            player.automaticallyWaitsToMinimizeStalling = waitForBuffer
        }

        // configure wether control center metdata should auto update
        player.automaticallyUpdateNowPlayingInfo = config["autoUpdateMetadata"] as? Bool ?? true

        // configure audio session - category, options & mode
        if
            let sessionCategoryStr = config["iosCategory"] as? String,
            let mappedCategory = SessionCategory(rawValue: sessionCategoryStr) {
            sessionCategory = mappedCategory.mapConfigToAVAudioSessionCategory()
        }

        if
            let sessionCategoryModeStr = config["iosCategoryMode"] as? String,
            let mappedCategoryMode = SessionCategoryMode(rawValue: sessionCategoryModeStr) {
            sessionCategoryMode = mappedCategoryMode.mapConfigToAVAudioSessionCategoryMode()
        }

        if
            let sessionCategoryPolicyStr = config["iosCategoryPolicy"] as? String,
            let mappedCategoryPolicy = SessionCategoryPolicy(rawValue: sessionCategoryPolicyStr) {
            sessionCategoryPolicy = mappedCategoryPolicy.mapConfigToAVAudioSessionCategoryPolicy()
        }

        let sessionCategoryOptsStr = config["iosCategoryOptions"] as? [String]
        let mappedCategoryOpts = sessionCategoryOptsStr?.compactMap { SessionCategoryOptions(rawValue: $0)?.mapConfigToAVAudioSessionCategoryOptions() } ?? []
        sessionCategoryOptions = AVAudioSession.CategoryOptions(mappedCategoryOpts)

        configureAudioSession()

        // setup event listeners
        player.remoteCommandController.handleChangePlaybackPositionCommand = { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.emit(event: EventType.RemoteSeek, body: ["position": event.positionTime])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleNextTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteNext)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePauseCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePause)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePlayCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePlay)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handlePreviousTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePrevious)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleSkipBackwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpBackward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleSkipForwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpForward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }

            return MPRemoteCommandHandlerStatus.commandFailed
        }

        player.remoteCommandController.handleStopCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteStop)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleTogglePlayPauseCommand = { [weak self] _ in
            self?.emit(event: self?.player.playerState == .paused
                ? EventType.RemotePlay
                : EventType.RemotePause
            )

            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleLikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteLike)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleDislikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteDislike)
            return MPRemoteCommandHandlerStatus.success
        }

        player.remoteCommandController.handleBookmarkCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteBookmark)
            return MPRemoteCommandHandlerStatus.success
        }

        hasInitialized = true
        resolve(NSNull())
    }


    private func configureAudioSession() {
        // IMPORTANT: Do NOT deactivate the audio session when currentItem is nil.
        // This happens briefly during chunk transitions (queue ends, next chunk loading).
        // If we deactivate, iOS sees "no audio session" and may terminate the app in background.
        // The session will naturally be released when the app is fully terminated.
        // 
        // Previous code that caused background termination:
        // if (player.currentItem == nil) {
        //     try? audioSessionController.deactivateSession()
        //     return
        // }
        
        // activate the audio session when there is an item to be played
        // and the player has been configured to start when it is ready loading:
        if (player.playWhenReady) {
            try? audioSessionController.activateSession()
            if #available(iOS 11.0, *) {
                try? AVAudioSession.sharedInstance().setCategory(sessionCategory, mode: sessionCategoryMode, policy: sessionCategoryPolicy, options: sessionCategoryOptions)
            } else {
                try? AVAudioSession.sharedInstance().setCategory(sessionCategory, mode: sessionCategoryMode, options: sessionCategoryOptions)
            }
        }
    }

    @objc(isServiceRunning:rejecter:)
    public func isServiceRunning(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        // TODO That is probably always true
        resolve(hasInitialized)
    }

    @objc(updateOptions:resolver:rejecter:)
    public func update(options: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var capabilitiesStr = options["capabilities"] as? [String] ?? []
        if (capabilitiesStr.contains("play") && capabilitiesStr.contains("pause")) {
            capabilitiesStr.append("togglePlayPause");
        }

        forwardJumpInterval = options["forwardJumpInterval"] as? NSNumber ?? forwardJumpInterval
        backwardJumpInterval = options["backwardJumpInterval"] as? NSNumber ?? backwardJumpInterval

        player.remoteCommands = capabilitiesStr
            .compactMap { Capability(rawValue: $0) }
            .map { capability in
                capability.mapToPlayerCommand(
                    forwardJumpInterval: forwardJumpInterval,
                    backwardJumpInterval: backwardJumpInterval,
                    likeOptions: options["likeOptions"] as? [String: Any],
                    dislikeOptions: options["dislikeOptions"] as? [String: Any],
                    bookmarkOptions: options["bookmarkOptions"] as? [String: Any]
                )
            }

        configureProgressUpdateEvent(
            interval: ((options["progressUpdateEventInterval"] as? NSNumber) ?? 0).doubleValue
        )

        resolve(NSNull())
    }

    private func configureProgressUpdateEvent(interval: Double) {
        shouldEmitProgressEvent = interval > 0
        self.player.timeEventFrequency = shouldEmitProgressEvent
            ? .custom(time: CMTime(seconds: interval, preferredTimescale: 1000))
            : .everySecond
    }

    @objc(add:before:resolver:rejecter:)
    public func add(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        // -1 means no index was passed and therefore should be inserted at the end.
        let index = trackIndex.intValue == -1 ? player.items.count : trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: index,
            max: player.items.count,
            reject: reject
        )) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }

        try? player.add(
            items: tracks,
            at: index
        )
        resolve(index)
    }

    @objc(addAndPrepare:before:resolver:rejecter:)
    public func addAndPrepare(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        // -1 means no index was passed and therefore should be inserted at the end.
        let index = trackIndex.intValue == -1 ? player.items.count : trackIndex.intValue;
        
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: index,
            max: player.items.count,
            reject: reject
        )) { return }

        var tracks = [Track]()
        
        for (idx, trackDict) in trackDicts.enumerated() {
            guard let track = Track(dictionary: trackDict) else {
                print("[TrackPlayer] addAndPrepare: ❌ Failed to create track at index \(idx)")
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            let sourceUrl = track.getSourceUrl()
            
            let asset: AVURLAsset
            let cacheKey: String
            
            if track.url.isLocal {
                asset = AVURLAsset(url: track.url.value, options: track.getAssetOptions())
                cacheKey = track.url.value.absoluteString
            } else if let url = URL(string: sourceUrl) {
                asset = AVURLAsset(url: url, options: track.getAssetOptions())
                cacheKey = url.absoluteString
            } else {
                print("[TrackPlayer] addAndPrepare: ⚠️ Invalid URL: \(sourceUrl)")
                tracks.append(track)
                continue
            }
            
            // Create AVPlayerItem and store in cache for the patched AVPlayerWrapper
            let playerItem = AVPlayerItem(asset: asset)
            PreparedPlayerItemCache.shared.store(playerItem, forURL: cacheKey)
            preparedPlayerItems[cacheKey] = playerItem

            // Determine URL type for logging
            let isStreamChunk = sourceUrl.contains("/stream-chunk/")
            let urlType = isStreamChunk ? "stream-chunk" : (track.url.isLocal ? "local" : "remote")
            let trackInsertionIndex = index + tracks.count
            tracks.append(track)

            // CRITICAL: Do not preflight-probe stream-chunk URLs here.
            // loadValuesAsynchronously can trigger a second GET /stream-chunk/* request
            // for the same chunk, which causes duplicate generation and unstable playback.
            if isStreamChunk {
                let currentIndex = player.currentIndex
                let shouldWarm = enableStreamWarmupPlayers && currentIndex >= 0 && trackInsertionIndex > currentIndex
                if shouldWarm {
                    // Use a separate AVPlayerItem for warmup so the cached playback
                    // item is never attached to more than one AVPlayer.
                    let warmupItem = AVPlayerItem(asset: asset)
                    startStreamWarmup(
                        cacheKey: cacheKey,
                        item: warmupItem,
                        trackIndex: trackInsertionIndex
                    )
                }
                print(
                    "[TrackPlayer] addAndPrepare: ℹ️ [stream-chunk] track \(trackInsertionIndex) queued " +
                    "(probe skipped, warmup=\(shouldWarm ? "on" : "off"))"
                )
                continue
            }
            
            // Pre-buffer: load playable + duration asynchronously.
            // For stream-chunk URLs the backend may return a 302→S3 or a progressive
            // stream — AVURLAsset handles both. Duration may be unknown until the
            // full response is received; that is fine — playback starts as soon as
            // enough data is buffered.
            asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) { [weak self] in
                var error: NSError?
                let playableStatus = asset.statusOfValue(forKey: "playable", error: &error)
                let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
                
                if playableStatus == .loaded {
                    var durationStr = "unknown"
                    if durationStatus == .loaded {
                        let dur = asset.duration
                        if !CMTIME_IS_INDEFINITE(dur) && !CMTIME_IS_INVALID(dur) {
                            durationStr = String(format: "%.1fs", CMTimeGetSeconds(dur))
                        } else {
                            // Duration indefinite — expected for progressive streams
                            durationStr = "indefinite (streaming)"
                        }
                    }
                    
                    // Single summary log per non-streaming track
                    DispatchQueue.main.async {
                        let bufferedStr: String
                        if let firstRange = playerItem.loadedTimeRanges.first?.timeRangeValue {
                            bufferedStr = String(format: "%.1fs buffered", CMTimeGetSeconds(firstRange.duration))
                        } else {
                            bufferedStr = "0s buffered"
                        }
                        print("[TrackPlayer] addAndPrepare: ✅ [\(urlType)] track \(idx) ready — \(durationStr), \(bufferedStr)")
                    }
                } else if let error = error {
                    print("[TrackPlayer] addAndPrepare: ❌ [\(urlType)] track \(idx) error: \(error.localizedDescription)")
                } else {
                    print("[TrackPlayer] addAndPrepare: ⚠️ [\(urlType)] track \(idx) playable=\(playableStatus.rawValue)")
                }
                
                // Clean up local retention once loading completes
                DispatchQueue.main.async {
                    self?.preparedPlayerItems.removeValue(forKey: cacheKey)
                }
            }
        }

        // Add tracks to the queue
        do {
            try player.add(
                items: tracks,
                at: index
            )
            print("[TrackPlayer] addAndPrepare: Adding \(tracks.count) track(s) at index \(index). Queue size: \(player.items.count)")
        } catch {
            print("[TrackPlayer] addAndPrepare: ❌ Queue add failed: \(error.localizedDescription)")
        }
        
        resolve(index)
    }

    @objc(load:resolver:rejecter:)
    public func load(
        trackDict: [String: Any],
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        guard let track = Track(dictionary: trackDict) else {
            reject("invalid_track_object", "Track is missing a required key", nil)
            return
        }

        player.load(item: track)
        resolve(player.currentIndex)
    }

    @objc(remove:resolver:rejecter:)
    public func remove(tracks indexes: [Int], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        for index in indexes {
            if (rejectWhenTrackIndexOutOfBounds(index: index, message: "One or more of the indexes were out of bounds.", reject: reject)) {
                return
            }
        }

        // Sort the indexes in descending order so we can safely remove them one by one
        // without having the next index possibly newly pointing to another item than intended:
        for index in indexes.sorted().reversed() {
            // Clean up prepared player items for removed tracks
            if index < player.items.count, let track = player.items[index] as? Track {
                let assetKey = track.url.value.absoluteString
                if preparedPlayerItems.removeValue(forKey: assetKey) != nil {
                    print("[RNTrackPlayer] remove: Cleaned up prepared player item for track at index \(index) (key: \(assetKey))")
                }
                PreparedPlayerItemCache.shared.remove(forURL: assetKey)
                stopStreamWarmup(for: assetKey, reason: "removed")
            }
            try? player.removeItem(at: index)
        }

        resolve(NSNull())
    }

    @objc(move:toIndex:resolver:rejecter:)
    public func move(
        fromIndex: NSNumber,
        toIndex: NSNumber,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: fromIndex.intValue,
            message: "The fromIndex is out of bounds",
            reject: reject)
        ) { return }
        if (rejectWhenTrackIndexOutOfBounds(
            index: toIndex.intValue,
            max: Int.max,
            message: "The toIndex is out of bounds",
            reject: reject)
        ) { return }
        try? player.moveItem(fromIndex: fromIndex.intValue, toIndex: toIndex.intValue)
        resolve(NSNull())
    }


    @objc(removeUpcomingTracks:rejecter:)
    public func removeUpcomingTracks(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.removeUpcomingItems()
        resolve(NSNull())
    }

    @objc(skip:initialTime:resolver:rejecter:)
    public func skip(
        to trackIndex: NSNumber,
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        let index = trackIndex.intValue;
        if (rejectWhenTrackIndexOutOfBounds(index: index, reject: reject)) { return }

        if (rejectWhenNotInitialized(reject: reject)) { return }

        print("Skipping to track:", index)
        try? player.jumpToItem(atIndex: index, playWhenReady: player.playerState == .playing)

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(skipToNext:resolver:rejecter:)
    public func skipToNext(
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.next()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(skipToPrevious:resolver:rejecter:)
    public func skipToPrevious(
        initialTime: Double,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.previous()

        // if an initialTime is passed the seek to it
        if (initialTime >= 0) {
            self.seekTo(time: initialTime, resolve: resolve, reject: reject)
        } else {
            resolve(NSNull())
        }
    }

    @objc(reset:rejecter:)
    public func reset(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        print("[RNTrackPlayer] reset: Cleaning up \(preparedPlayerItems.count) prepared player item(s)")
        player.stop()
        player.clear()
        // Clean up all prepared player items
        preparedPlayerItems.removeAll()
        PreparedPlayerItemCache.shared.clear()
        stopAllStreamWarmups(reason: "reset")
        print("[RNTrackPlayer] reset: ✅ All prepared player items cleaned up")
        resolve(NSNull())
    }

    @objc(play:rejecter:)
    public func play(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        player.play()
        resolve(NSNull())
    }

    @objc(pause:rejecter:)
    public func pause(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.pause()
        resolve(NSNull())
    }

    @objc(setPlayWhenReady:resolver:rejecter:)
    public func setPlayWhenReady(playWhenReady: Bool, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        player.playWhenReady = playWhenReady
        resolve(NSNull())
    }

    @objc(getPlayWhenReady:rejecter:)
    public func getPlayWhenReady(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve(player.playWhenReady)
    }

    @objc(stop:rejecter:)
    public func stop(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.stop()
        resolve(NSNull())
    }

    @objc(seekTo:resolver:rejecter:)
    public func seekTo(time: Double, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.seek(to: time)
        resolve(NSNull())
    }

    @objc(seekBy:resolver:rejecter:)
    public func seekBy(offset: Double, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.seek(by: offset)
        resolve(NSNull())
    }

    @objc(retry:rejecter:)
    public func retry(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        player.reload(startFromCurrentTime: true)
        resolve(NSNull())
    }

    @objc(setRepeatMode:resolver:rejecter:)
    public func setRepeatMode(repeatMode: NSNumber, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: repeatMode.intValue) ?? .off
        resolve(NSNull())
    }

    @objc(getRepeatMode:rejecter:)
    public func getRepeatMode(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.repeatMode.rawValue)
    }

    @objc(setVolume:resolver:rejecter:)
    public func setVolume(level: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.volume = level
        resolve(NSNull())
    }

    @objc(getVolume:rejecter:)
    public func getVolume(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.volume)
    }

    @objc(setRate:resolver:rejecter:)
    public func setRate(rate: Float, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.rate = rate
        resolve(NSNull())
    }

    @objc(getRate:rejecter:)
    public func getRate(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.rate)
    }

    @objc(getTrack:resolver:rejecter:)
    public func getTrack(index: NSNumber, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        if (index.intValue >= 0 && index.intValue < player.items.count) {
            let track = player.items[index.intValue]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc(getQueue:rejecter:)
    public func getQueue(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let serializedQueue = player.items.map { ($0 as! Track).toObject() }
        resolve(serializedQueue)
    }

    @objc(setQueue:resolver:rejecter:)
    public func setQueue(
        trackDicts: [[String: Any]],
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        var tracks = [Track]()
        for trackDict in trackDicts {
            guard let track = Track(dictionary: trackDict) else {
                reject("invalid_track_object", "Track is missing a required key", nil)
                return
            }

            tracks.append(track)
        }
        player.clear()
        try? player.add(items: tracks)
        resolve(index)
    }

    @objc(getActiveTrack:rejecter:)
    public func getActiveTrack(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = player.currentIndex
        if (index >= 0 && index < player.items.count) {
            let track = player.items[index]
            resolve((track as? Track)?.toObject())
        } else {
            resolve(NSNull())
        }
    }

    @objc(getActiveTrackIndex:rejecter:)
    public func getActiveTrackIndex(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        let index = player.currentIndex
        if index < 0 || index >= player.items.count {
            resolve(NSNull())
        } else {
            resolve(index)
        }
    }

    @objc(getDuration:rejecter:)
    public func getDuration(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.duration)
    }

    @objc(getBufferedPosition:rejecter:)
    public func getBufferedPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.bufferedPosition)
    }

    @objc(getPosition:rejecter:)
    public func getPosition(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        resolve(player.currentTime)
    }

    @objc(getProgress:rejecter:)
    public func getProgress(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve([
            "position": player.currentTime,
            "duration": player.duration,
            "buffered": player.bufferedPosition
        ])
    }

    @objc(getPlaybackState:rejecter:)
    public func getPlaybackState(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        resolve(getPlaybackStateBodyKeyValues(state: player.playerState))
    }

    @objc(updateMetadataForTrack:metadata:resolver:rejecter:)
    public func updateMetadata(for trackIndex: NSNumber, metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        let index = trackIndex.intValue;
        if (rejectWhenNotInitialized(reject: reject)) { return }
        if (rejectWhenTrackIndexOutOfBounds(index: index, reject: reject)) { return }

        let track : Track = player.items[index] as! Track;
        track.updateMetadata(dictionary: metadata)

        if (player.currentIndex == index) {
            Metadata.update(for: player, with: metadata)
        }

        resolve(NSNull())
    }

    @objc(clearNowPlayingMetadata:rejecter:)
    public func clearNowPlayingMetadata(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        player.nowPlayingInfoController.clear()
        resolve(NSNull())
    }

    @objc(updateNowPlayingMetadata:resolver:rejecter:)
    public func updateNowPlayingMetadata(metadata: [String: Any], resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        Metadata.update(for: player, with: metadata)
        resolve(NSNull())
    }

    private func warmupBufferedSeconds(for item: AVPlayerItem) -> Double {
        guard let first = item.loadedTimeRanges.first?.timeRangeValue else { return 0.0 }
        let value = CMTimeGetSeconds(first.duration)
        return value.isFinite ? max(0.0, value) : 0.0
    }

    private func warmupTotalBufferedSeconds(for item: AVPlayerItem) -> Double {
        item.loadedTimeRanges.reduce(0.0) { acc, rangeValue in
            let value = CMTimeGetSeconds(rangeValue.timeRangeValue.duration)
            if value.isFinite {
                return acc + max(0.0, value)
            }
            return acc
        }
    }

    private func startStreamWarmup(cacheKey: String, item: AVPlayerItem, trackIndex: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.streamWarmupPlayers[cacheKey] != nil {
                return
            }

            item.preferredForwardBufferDuration = self.streamWarmupTargetSeconds
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

            let warmer = AVPlayer(playerItem: item)
            warmer.isMuted = true
            warmer.automaticallyWaitsToMinimizeStalling = true
            warmer.allowsExternalPlayback = false

            self.streamWarmupPlayers[cacheKey] = warmer
            self.streamWarmupStartTimes[cacheKey] = Date()

            let shortKey = cacheKey.count > 70 ? String(cacheKey.prefix(70)) + "..." : cacheKey
            print("[TrackPlayer] warmup: ▶️ start track \(trackIndex) url=\(shortKey)")
            warmer.play()
            self.pollStreamWarmup(cacheKey: cacheKey, trackIndex: trackIndex)
        }
    }

    private func pollStreamWarmup(cacheKey: String, trackIndex: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + streamWarmupPollIntervalSeconds) { [weak self] in
            guard let self = self else { return }
            guard let warmer = self.streamWarmupPlayers[cacheKey], let item = warmer.currentItem else {
                self.streamWarmupPlayers.removeValue(forKey: cacheKey)
                self.streamWarmupStartTimes.removeValue(forKey: cacheKey)
                return
            }

            let start = self.streamWarmupStartTimes[cacheKey] ?? Date()
            let elapsed = Date().timeIntervalSince(start)
            let firstBuffered = self.warmupBufferedSeconds(for: item)
            let totalBuffered = self.warmupTotalBufferedSeconds(for: item)

            if item.status == .failed {
                self.stopStreamWarmup(for: cacheKey, reason: "failed", trackIndex: trackIndex)
                return
            }

            if totalBuffered >= self.streamWarmupTargetSeconds {
                print(
                    "[TrackPlayer] warmup: ✅ primed track \(trackIndex) " +
                    "elapsed=\(String(format: "%.2f", elapsed))s " +
                    "first=\(String(format: "%.2f", firstBuffered))s total=\(String(format: "%.2f", totalBuffered))s"
                )
                return
            }

            if elapsed >= self.streamWarmupMaxWaitSeconds {
                self.stopStreamWarmup(for: cacheKey, reason: "timeout", trackIndex: trackIndex)
                return
            }

            if Int((elapsed * 10).rounded()) % 20 == 0 {
                print(
                    "[TrackPlayer] warmup: … track \(trackIndex) elapsed=\(String(format: "%.1f", elapsed))s " +
                    "first=\(String(format: "%.2f", firstBuffered))s total=\(String(format: "%.2f", totalBuffered))s"
                )
            }

            self.pollStreamWarmup(cacheKey: cacheKey, trackIndex: trackIndex)
        }
    }

    @discardableResult
    private func detachStreamWarmupImmediately(for cacheKey: String, reason: String, trackIndex: Int? = nil) -> Bool {
        var didDetach = false
        let detach = {
            let start = self.streamWarmupStartTimes.removeValue(forKey: cacheKey)
            guard let warmer = self.streamWarmupPlayers.removeValue(forKey: cacheKey) else {
                let shortKey = cacheKey.count > 70 ? String(cacheKey.prefix(70)) + "..." : cacheKey
                print("[TrackPlayer] warmup: ℹ️ no active warmup for reason=\(reason) key=\(shortKey)")
                return
            }

            let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0.0
            let item = warmer.currentItem
            let firstBuffered = item.map { self.warmupBufferedSeconds(for: $0) } ?? 0.0
            let totalBuffered = item.map { self.warmupTotalBufferedSeconds(for: $0) } ?? 0.0
            let statusRaw = item?.status.rawValue ?? -1

            warmer.pause()
            warmer.replaceCurrentItem(with: nil)

            let idx = trackIndex.map(String.init) ?? "?"
            print(
                "[TrackPlayer] warmup: ⏹️ \(reason) track \(idx) " +
                "elapsed=\(String(format: "%.2f", elapsed))s status=\(statusRaw) " +
                "first=\(String(format: "%.2f", firstBuffered))s total=\(String(format: "%.2f", totalBuffered))s"
            )
            didDetach = true
        }

        if Thread.isMainThread {
            detach()
        } else {
            DispatchQueue.main.sync(execute: detach)
        }
        return didDetach
    }

    private func normalizedWarmupKey(_ value: String) -> String {
        if let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first {
            return String(parts)
        }
        return value
    }

    @discardableResult
    private func detachStreamWarmupBestEffort(for cacheKey: String, reason: String, trackIndex: Int? = nil) -> Bool {
        if detachStreamWarmupImmediately(for: cacheKey, reason: reason, trackIndex: trackIndex) {
            return true
        }

        let target = normalizedWarmupKey(cacheKey)
        var matchedKey: String?
        let locate = {
            matchedKey = self.streamWarmupPlayers.keys.first(where: {
                self.normalizedWarmupKey($0) == target
            })
        }

        if Thread.isMainThread {
            locate()
        } else {
            DispatchQueue.main.sync(execute: locate)
        }

        guard let key = matchedKey else {
            return false
        }
        return detachStreamWarmupImmediately(
            for: key,
            reason: "\(reason)-normalized",
            trackIndex: trackIndex
        )
    }

    private func stopStreamWarmup(for cacheKey: String, reason: String, trackIndex: Int? = nil) {
        _ = detachStreamWarmupImmediately(for: cacheKey, reason: reason, trackIndex: trackIndex)
    }

    private func stopAllStreamWarmups(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.streamWarmupPlayers.isEmpty {
                self.streamWarmupStartTimes.removeAll()
                return
            }
            let count = self.streamWarmupPlayers.count
            for (_, warmer) in self.streamWarmupPlayers {
                warmer.pause()
                warmer.replaceCurrentItem(with: nil)
            }
            self.streamWarmupPlayers.removeAll()
            self.streamWarmupStartTimes.removeAll()
            print("[TrackPlayer] warmup: 🧹 cleared \(count) player(s), reason=\(reason)")
        }
    }

    private func getPlaybackStateErrorKeyValues() -> Dictionary<String, Any> {
        switch player.playbackError {
            case .failedToLoadKeyValue: return [
                "message": "Failed to load resource",
                "code": "ios_failed_to_load_resource"
            ]
            case .invalidSourceUrl: return [
                "message": "The source url was invalid",
                "code": "ios_invalid_source_url"
            ]
            case .notConnectedToInternet: return [
                "message": "A network resource was requested, but an internet connection has not been established and can’t be established automatically.",
                "code": "ios_not_connected_to_internet"
            ]
            case .playbackFailed: return [
                "message": "Playback of the track failed",
                "code": "ios_playback_failed"
            ]
            case .itemWasUnplayable: return [
                "message": "The track could not be played",
                "code": "ios_track_unplayable"
            ]
            default: return [
                "message": "A playback error occurred",
                "code": "ios_playback_error"
            ]
        }
    }

    private func getPlaybackStateBodyKeyValues(state: AudioPlayerState) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": State.fromPlayerState(state: state).rawValue]
        if (state == AudioPlayerState.failed) {
            body["error"] = getPlaybackStateErrorKeyValues()
        }
        return body
    }

    // MARK: - QueuedAudioPlayer Event Handlers

    func handleAudioPlayerStateChange(state: AVPlayerWrapperState) {
        // PATCHED: Log state changes for background audio debugging
        NSLog("[RNTrackPlayer] 🔊 State → %@ | index=%d time=%.1f duration=%.1f playWhenReady=%d",
              "\(state)", player.currentIndex, player.currentTime, player.duration, player.playWhenReady ? 1 : 0)
        
        emit(event: EventType.PlaybackState, body: getPlaybackStateBodyKeyValues(state: state))
        if (state == .ended) {
            NSLog("[RNTrackPlayer] 🔊 Queue ended at index=%d position=%.1f", player.currentIndex, player.currentTime)
            emit(event: EventType.PlaybackQueueEnded, body: [
                "track": player.currentIndex,
                "position": player.currentTime,
            ] as [String : Any])
        }
    }
    
    func handleAudioPlayerCommonMetadataReceived(metadata: [AVMetadataItem]) {
        let commonMetadata = MetadataAdapter.convertToCommonMetadata(metadata: metadata, skipRaw: true)
        emit(event: EventType.MetadataCommonReceived, body: ["metadata": commonMetadata])
    }
    
    func handleAudioPlayerChapterMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataChapterReceived, body:  ["metadata": metadataItems])
    }

    func handleAudioPlayerTimedMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        emit(event: EventType.MetadataTimedReceived, body: ["metadata": metadataItems])
        
        // SwiftAudioEx was updated to return the array of timed metadata
        // Until we have support for that in RNTP, we take the first item to keep existing behaviour.
        let metadata = metadata.first?.items ?? []
        let metadataItem = MetadataAdapter.legacyConversion(metadata: metadata)
        emit(event: EventType.PlaybackMetadataReceived, body: metadataItem)
    }

    func handleAudioPlayerFailed(error: Error?) {
        NSLog("[RNTrackPlayer] ❌ PLAYBACK FAILED: %@", error?.localizedDescription ?? "unknown")
        emit(event: EventType.PlaybackError, body: ["error": error?.localizedDescription])
    }

    func handleAudioPlayerCurrentItemChange(
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    ) {
        NSLog("[RNTrackPlayer] 🔊 Track change: %@ → %@, lastPos=%.1f",
              lastIndex != nil ? "\(lastIndex!)" : "nil",
              index != nil ? "\(index!)" : "nil",
              lastPosition ?? 0)

        if let item = item {
            DispatchQueue.main.async {
                UIApplication.shared.beginReceivingRemoteControlEvents();
            }
            // Update now playing controller with isLiveStream option from track
            if self.player.automaticallyUpdateNowPlayingInfo {
                let isTrackLiveStream = (item as? Track)?.isLiveStream ?? false
                self.player.nowPlayingInfoController.set(keyValue: NowPlayingInfoProperty.isLiveStream(isTrackLiveStream))
            }
            if enableStreamWarmupPlayers, let activeTrack = item as? Track {
                let cacheKey = activeTrack.getSourceUrl()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.stopStreamWarmup(
                        for: cacheKey,
                        reason: "activated-cleanup",
                        trackIndex: index
                    )
                }
            }
        }
        // IMPORTANT: Do NOT call endReceivingRemoteControlEvents when item becomes nil.
        // This happens during chunk transitions and signals iOS we're done with audio,
        // which can cause background termination. Keep receiving remote control events
        // so lock screen controls continue to work during chunk loading.
        // 
        // Previous code that caused issues:
        // else {
        //     DispatchQueue.main.async {
        //         UIApplication.shared.endReceivingRemoteControlEvents();
        //     }
        // }

        if (item != nil && lastItem == nil) {
            configureAudioSession();
        }
        // Don't call configureAudioSession when item becomes nil - it would deactivate the session

        var a: Dictionary<String, Any> = ["lastPosition": lastPosition ?? 0]
        if let lastIndex = lastIndex {
            a["lastIndex"] = lastIndex
        }

        if let lastTrack = (lastItem as? Track)?.toObject() {
            a["lastTrack"] = lastTrack
        }

        if let index = index {
            a["index"] = index
        }

        if let track = (item as? Track)?.toObject() {
            a["track"] = track
        }
        emit(event: EventType.PlaybackActiveTrackChanged, body: a)

        // deprecated:
        var b: Dictionary<String, Any> = ["position": lastPosition ?? 0]
        if let lastIndex = lastIndex {
            b["lastIndex"] = lastIndex
        }
        if let index = index {
            b["nextTrack"] = index
        }
        emit(event: EventType.PlaybackTrackChanged, body: b)
    }

    func handleAudioPlayerSecondElapse(seconds: Double) {
        // because you cannot prevent the `event.secondElapse` from firing
        // do not emit an event if `progressUpdateEventInterval` is nil
        // additionally, there are certain instances in which this event is emitted
        // _after_ a manipulation to the queu causing no currentItem to exist (see reset)
        // in which case we shouldn't emit anything or we'll get an exception.
        if !shouldEmitProgressEvent || player.currentItem == nil { return }
        emit(
            event: EventType.PlaybackProgressUpdated,
            body: [
                "position": player.currentTime,
                "duration": player.duration,
                "buffered": player.bufferedPosition,
                "track": player.currentIndex,
            ]
        )
    }

    func handlePlayWhenReadyChange(playWhenReady: Bool) {
        configureAudioSession();
        emit(
            event: EventType.PlaybackPlayWhenReadyChanged,
            body: [
                "playWhenReady": playWhenReady
            ]
        )
    }
    
    // MARK: - Test Helpers
    
    #if DEBUG
    /// Test helper to get the count of prepared player items
    /// This is only available in DEBUG builds for testing purposes
    @objc(getPreparedPlayerItemsCount:rejecter:)
    public func getPreparedPlayerItemsCount(
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        resolve(preparedPlayerItems.count)
    }
    #endif
}
