import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

// MARK: - Audio Device

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    var name: String
    var isDefault: Bool
    var isOutput: Bool
    var sampleRates: [Double]
    var currentSampleRate: Double
    var manufacturer: String
    var transportType: String

    var isUSB: Bool {
        transportType.lowercased().contains("usb")
    }

    var isBuiltIn: Bool {
        name.lowercased().contains("built-in") || name.lowercased().contains("macbook")
    }
}

// MARK: - Playback State

enum PlaybackState: Equatable {
    case stopped
    case playing
    case paused
    case loading
}

// MARK: - Audio Engine

/// Core audio playback engine using AVAudioEngine with:
/// - Bit-perfect output via HAL output device selection
/// - Automatic sample rate switching to match source
/// - 10-band parametric EQ
/// - FLAC/ALAC/WAV/AIFF decoding via AVAudioFile
final class AudioEngine: ObservableObject {

    /// Shared singleton for cross-window access.
    static let shared = AudioEngine()

    // MARK: - Published State

    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var currentTrack: Track?
    /// Playback position, updated by the UI's own 500ms timer via
    /// `refreshCurrentTime()`. Intentionally NOT @Published: publishing this
    /// twice a second fired objectWillChange and re-rendered every view
    /// observing AudioEngine (ContentView, playbar, fullscreen player…),
    /// which caused sustained CPU spikes during playback.
    private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBitPerfect: Bool = false
    @Published private(set) var activeDevice: AudioDevice?
    @Published private(set) var availableDevices: [AudioDevice] = []
    @Published var volume: Float = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
        }
    }
    @Published var isShuffleEnabled: Bool = false
    @Published var isRepeatEnabled: Bool = false
    @Published var isEQEnabled: Bool = false
    @Published var eqGains: [Float] = Array(repeating: 0, count: 10) {
        didSet {
            updateEQ()
        }
    }
    @Published var playbackError: String?

    // MARK: - Private

    private let engine = AVAudioEngine()
    private var playerNode: AVAudioPlayerNode!
    private var eqNode: AVAudioUnitEQ!
    private var audioFile: AVAudioFile?

    private var isSeeking = false

    /// Tracks the current "generation" of playback. Each new load increments it.
    /// Completion handlers capture the generation at schedule time and only fire
    /// if they are still current — preventing stale handlers from triggering skips.
    private var playbackGeneration: UInt64 = 0

    private var currentSampleRate: Double = 44100

    /// The frame position in the current file where playback started.
    /// Used to compute correct `currentTime` after seeks, since the player
    /// node's sample time resets to 0 after stop()/reset().
    private var startFrameOffset: AVAudioFramePosition = 0

    private var queue: [Track] = []
    private var currentIndex: Int = 0

    /// Tracks inserted via "Play Next". These are played before the
    /// remaining queue after the current track finishes.
    private var pendingNextTracks: [Track] = []

    private var observers: [NSObjectProtocol] = []

    /// Debounced machinery for the CoreAudio HAL device listeners. These
    /// fire repeatedly during playback (sample-clock renegotiation works the
    /// HAL), so refreshes are coalesced to 2.0s, gated on a cheap device-ID
    /// fingerprint, AND only published when the device list actually changed
    /// — never on every HAL callback.
    private var deviceRefreshTask: Task<Void, Never>?

    /// Value type capturing the currently-enumerated audio device IDs.
    /// `scheduleDeviceRefresh()` compares this cheap fingerprint before
    /// running the expensive full re-enumeration, so HAL notification storms
    /// during playback (sample-clock renegotiation) do not repeatedly
    /// describe every device (name / sample-rate / transport syscalls).
    private typealias DeviceFingerprint = [AudioDeviceID]
    private var cachedDeviceFingerprint: DeviceFingerprint = []

    // MARK: - Init

    @MainActor
    init() {
        setupEngine()

        // Apply the persisted default volume from Settings on launch.
        // The `volume` didSet writes through to the main mixer node.
        volume = Float(ThemeManager.shared.defaultVolume)

        // Apply the persisted EQ sound style from Settings on launch.
        if !ThemeManager.shared.eqPreset.isOff {
            setEQGains(ThemeManager.shared.eqPreset.gains)
            setEQEnabled(true)
        }

        setupDeviceMonitoring()
        refreshAudioDevices()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        deviceRefreshTask?.cancel()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        playerNode = AVAudioPlayerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 10)

        // Configure 10-band EQ (ISO standard frequencies).
        // IMPORTANT: All bands start BYPASSED. Each bypassed band still runs
        // biquad filter math on the real-time audio thread — activating even
        // a single band at 0 gain introduces measurable DSP cost on every
        // sample of every channel. Since EQ is off by default, keep every
        // filter out of the signal path until the user explicitly enables it.
        let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for (index, freq) in frequencies.enumerated() {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = true
        }

        engine.attach(playerNode)
        engine.attach(eqNode)

        reconnectGraph()

        // Set initial volume
        engine.mainMixerNode.outputVolume = volume
    }

    /// Re-establishes all node connections using the current hardware sample rate.
    /// Must be called whenever the output device or its sample rate changes.
    ///
    /// IMPORTANT — EQ entirely OUT of the signal path when disabled:
    /// `AVAudioUnitEQ` still runs a render callback on the real-time thread
    /// even when every band is bypassed. Connecting player → mainMixer
    /// directly means ZERO EQ DSP runs during normal playback.
    private func reconnectGraph() {
        guard let format = engine.outputNode.inputFormat(forBus: 0) as AVAudioFormat? else { return }

        // Disconnect everything first to avoid stale connection formats
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(eqNode)

        if isEQEnabled {
            // Connect: player -> EQ -> mainMixer -> output
            engine.connect(playerNode, to: eqNode, format: format)
            engine.connect(eqNode, to: engine.mainMixerNode, format: format)
        } else {
            // EQ completely bypassed at the graph level:
            // player -> mainMixer -> output. No AVAudioUnitEQ render
            // callback runs on the audio thread at all.
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        }
    }

    /// Starts the engine if not already running.
    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }

        do {
            // Re-connect the graph using the current hardware format before
            // starting — this ensures the engine renders at the new sample
            // rate instead of a stale cached format from a previous device.
            reconnectGraph()

            try engine.start()
            if !engine.isRunning {
                print("⚠️ Audio engine failed to start")
            }
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Device Management

    func refreshAudioDevices() {
        applyDevices(Self.enumerateDevices())
    }

    /// Equality-guarded publish: the device list and active device are ONLY
    /// published when they actually change. The CoreAudio HAL fires the
    /// device listeners constantly while audio is active; unconditional
    /// @Published writes here re-render every view observing AudioEngine
    /// (ContentView, playbar, fullscreen player…) — a sustained CPU storm.
    private func applyDevices(_ devices: [AudioDevice]) {
        if devices != availableDevices {
            availableDevices = devices
        }
        let newActive = devices.first(where: { $0.isDefault }) ?? devices.first
        if let newActive {
            if activeDevice?.id != newActive.id || activeDevice?.currentSampleRate != newActive.currentSampleRate {
                activeDevice = newActive
            }
        } else {
            if activeDevice != nil {
                activeDevice = nil
            }
        }
    }

    /// Coalesces HAL notification bursts (2.0s debounce), then:
    /// 1. reads a cheap device-ID fingerprint on a utility queue,
    /// 2. skips the expensive full re-enumeration when the fingerprint
    ///    matches the cached one (device set unchanged),
    /// 3. publishes on the main actor only when the list actually changed.
    private func scheduleDeviceRefresh() {
        deviceRefreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, !Task.isCancelled else { return }

            // Cheap fingerprint: just the device IDs (2 syscalls), not the
            // full per-device description.
            let deviceIDs = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.currentDeviceIDs())
                }
            }

            // Device set unchanged — skip the expensive enumeration entirely.
            guard deviceIDs != self.cachedDeviceFingerprint else { return }
            self.cachedDeviceFingerprint = deviceIDs

            let devices = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Self.enumerateDevices())
                }
            }
            self.applyDevices(devices)
        }
        deviceRefreshTask = task
    }

    /// Lightweight: reads only the system's audio device ID list (a couple
    /// of CoreAudio syscalls) — far cheaper than the full per-device
    /// enumeration. Used as a fingerprint to skip `enumerateDevices()` when
    /// the device set has not changed.
    nonisolated private static func currentDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs
    }

    /// Pure CoreAudio enumeration — nonisolated so it can run on a utility
    /// queue without touching the main actor.
    nonisolated private static func enumerateDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []

        let deviceIDs = currentDeviceIDs()

        // Get default output device
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDeviceID = AudioDeviceID(0)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &defaultSize,
            &defaultDeviceID
        )

        for deviceID in deviceIDs {
            guard let device = describeDevice(id: deviceID, isDefault: deviceID == defaultDeviceID) else { continue }
            devices.append(device)
        }

        // Sort: default first, then built-in, then USB
        devices.sort { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name < b.name
        }

        return devices
    }

    nonisolated private static func describeDevice(id: AudioDeviceID, isDefault: Bool) -> AudioDevice? {
        // Check if output device
        var scopeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &scopeAddress, 0, nil, &dataSize) == noErr else { return nil }

        var streamConfig = AudioBufferList()
        guard AudioObjectGetPropertyData(id, &scopeAddress, 0, nil, &dataSize, &streamConfig) == noErr else { return nil }

        let bufferCount = Int(streamConfig.mNumberBuffers)
        guard bufferCount > 0 else { return nil }

        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let nameResult = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
        let deviceName = (nameResult == noErr ? (name?.takeRetainedValue() as String?) : nil) ?? "Unknown Device"

        // Get manufacturer
        var manufacturerAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var manufacturer: Unmanaged<CFString>?
        var manufacturerSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let manufacturerResult = AudioObjectGetPropertyData(id, &manufacturerAddress, 0, nil, &manufacturerSize, &manufacturer)
        let manufacturerName = (manufacturerResult == noErr ? (manufacturer?.takeRetainedValue() as String?) : nil) ?? "Unknown"

        // Get transport type
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transportType)

        let transportString: String
        switch transportType {
        case kAudioDeviceTransportTypeUSB:
            transportString = "USB"
        case kAudioDeviceTransportTypeBuiltIn:
            transportString = "Built-in"
        case kAudioDeviceTransportTypeBluetooth:
            transportString = "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay:
            transportString = "AirPlay"
        case kAudioDeviceTransportTypeHDMI:
            transportString = "HDMI"
        case kAudioDeviceTransportTypeThunderbolt:
            transportString = "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire:
            transportString = "FireWire"
        default:
            transportString = "Unknown"
        }

        // Get supported sample rates
        var ratesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var ratesSize: UInt32 = 0
        var sampleRates: [Double] = []
        if AudioObjectGetPropertyDataSize(id, &ratesAddress, 0, nil, &ratesSize) == noErr {
            let rateCount = Int(ratesSize) / MemoryLayout<AudioValueRange>.size
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: rateCount)
            if AudioObjectGetPropertyData(id, &ratesAddress, 0, nil, &ratesSize, &ranges) == noErr {
                for range in ranges {
                    let rate = range.mMinimum
                    if rate > 0 {
                        sampleRates.append(rate)
                    }
                }
            }
        }

        // Get current sample rate
        var currentRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var currentRate: Double = 0
        var currentRateSize = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &currentRateAddress, 0, nil, &currentRateSize, &currentRate)

        return AudioDevice(
            id: id,
            name: deviceName,
            isDefault: isDefault,
            isOutput: true,
            sampleRates: sampleRates,
            currentSampleRate: currentRate,
            manufacturer: manufacturerName,
            transportType: transportString
        )
    }

    private func setupDeviceMonitoring() {
        // Monitor device changes — debounced by scheduleDeviceRefresh().
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.scheduleDeviceRefresh()
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            deviceListener
        )

        // Monitor default output device changes
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            deviceListener
        )
    }

    // MARK: - Sample Rate Switching

    /// Sets the output device's sample rate to match the source track.
    /// This is the key to bit-perfect playback - the DAC is told to switch
    /// to the exact sample rate of the audio file.
    ///
    /// Important: This must be called with the engine STOPPED.
    /// Changing the hardware sample rate while the engine is rendering
    /// causes glitches and audio corruption.
    func switchSampleRate(to rate: Double) {
        guard let device = activeDevice else { return }

        // Read the device's actual current rate, not our cached one
        var currentRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var actualRate: Double = 0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(
            device.id,
            &currentRateAddress,
            0,
            nil,
            &rateSize,
            &actualRate
        )

        // Guard against redundant switches — no-op if the device is already
        // at the target rate. Prevents clicks/pops between consecutive songs
        // at the same sample rate.
        guard abs(actualRate - rate) > 1.0 else {
            currentSampleRate = actualRate
            isBitPerfect = true
            return
        }

        // Check the device actually supports this rate
        guard device.sampleRates.contains(rate) || device.sampleRates.isEmpty else {
            print("Device \(device.name) does not support \(rate) Hz")
            // Fall back to non-bit-perfect (OS will resample)
            isBitPerfect = false
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newRate = rate
        let result = AudioObjectSetPropertyData(
            device.id,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &newRate
        )

        if result == noErr {
            currentSampleRate = rate
            isBitPerfect = true
            print("Switched output to \(rate) Hz on \(device.name)")
        } else {
            print("Failed to switch sample rate to \(rate): \(result)")
            isBitPerfect = false
        }
    }

    /// Selects an output device for playback.
    func selectDevice(_ device: AudioDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = device.id
        let result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if result == noErr {
            activeDevice = device
            // Re-apply sample rate for current track
            if let track = currentTrack, let file = audioFile {
                let wasPlaying = playbackState == .playing
                let resumeTime = currentTime

                // Pause the engine so we can safely switch rates
                engine.pause()
                switchSampleRate(to: track.sampleRate)
                startEngineIfNeeded()

                // Re-schedule the file for the new engine configuration
                playbackGeneration &+= 1
                let generation = playbackGeneration

                playerNode.stop()
                playerNode.reset()

                let sampleRate = file.processingFormat.sampleRate
                guard sampleRate > 0 else { return }

                let totalFrames = file.length
                let framePosition = AVAudioFramePosition(resumeTime * sampleRate)
                let clampedFrame = min(max(framePosition, 0), totalFrames)
                let remainingFrames = max(0, totalFrames - clampedFrame)

                guard remainingFrames > 0 else { return }

                file.framePosition = clampedFrame
                startFrameOffset = clampedFrame

                playerNode.scheduleSegment(
                    file,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, self.playbackGeneration == generation else { return }
                        if self.playbackState == .playing {
                            self.handleTrackEnded()
                        }
                    }
                }

                if wasPlaying {
                    playerNode.play()
                    playbackState = .playing
                } else {
                    playbackState = .paused
                }
            }
        }
    }

    // MARK: - Playback Control

    func play(track: Track, in queue: [Track]? = nil) {
        if let queue = queue, !queue.isEmpty {
            self.queue = queue
            if let index = queue.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
        }

        loadAndPlay(track)
    }

    func playQueue(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = min(max(index, 0), tracks.count - 1)
        pendingNextTracks.removeAll()
        loadAndPlay(tracks[currentIndex])
    }

    /// Inserts a track right after the currently playing track.
    /// If the current queue is empty, the track becomes the only queue item.
    func playNext(track: Track) {
        pendingNextTracks.append(track)

        // If nothing is currently loaded, just play it directly.
        if currentTrack == nil {
            queue = [track]
            currentIndex = 0
            pendingNextTracks.removeAll()
            loadAndPlay(track)
        }
    }

    /// Appends a track to the end of the playback queue.
    func addToQueue(track: Track) {
        guard let currentTrack else {
            queue = [track]
            currentIndex = 0
            loadAndPlay(track)
            return
        }

        queue.append(track)

        // Keep currentIndex correct — if the current track is found,
        // it points at the current position; otherwise fall back to 0.
        if let index = queue.firstIndex(where: { $0.id == currentTrack.id }) {
            currentIndex = index
        }
    }

    func togglePlayPause() {
        switch playbackState {
        case .playing:
            pause()
        case .paused:
            resume()
        case .stopped, .loading:
            if let track = currentTrack {
                loadAndPlay(track)
            }
        }
    }

    func pause() {
        playerNode.pause()
        playbackState = .paused
    }

    func resume() {
        guard audioFile != nil else { return }

        // Make sure the engine is running — it may have stopped
        // after a sample rate change.
        startEngineIfNeeded()

        playerNode.play()
        playbackState = .playing
        refreshCurrentTime()
    }

    func stop() {
        // Increment generation to invalidate any pending completion handlers
        playbackGeneration &+= 1

        playerNode.stop()
        playerNode.reset()
        audioFile = nil
        currentTrack = nil
        currentTime = 0
        duration = 0
        playbackState = .stopped
    }

    func next() {
        guard !queue.isEmpty else { return }

        if isShuffleEnabled {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex = (currentIndex + 1) % queue.count
        }

        loadAndPlay(queue[currentIndex])
    }

    func previous() {
        guard !queue.isEmpty else { return }

        // If we're more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        if isShuffleEnabled {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
        }

        loadAndPlay(queue[currentIndex])
    }

    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }

        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return }

        // Clamp to valid range
        let clampedTime = min(max(0, time), duration)
        let totalFrames = file.length
        let framePosition = AVAudioFramePosition(clampedTime * sampleRate)
        let clampedFrame = min(max(framePosition, 0), totalFrames)
        let remainingFrames = max(0, totalFrames - clampedFrame)

        // Nothing to play
        guard remainingFrames > 0 else { return }

        // Invalidate any pending completion handlers before stopping
        playbackGeneration &+= 1
        let generation = playbackGeneration

        playerNode.stop()
        playerNode.reset()

        file.framePosition = clampedFrame
        // Remember where in the file we are, so the display link can
        // account for the offset after the player node restarts.
        startFrameOffset = clampedFrame
        let frameCount = AVAudioFrameCount(remainingFrames)

        playerNode.scheduleSegment(
            file,
            startingFrame: clampedFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            // Only fire if this is still the current generation
            DispatchQueue.main.async {
                guard let self = self, self.playbackGeneration == generation else { return }
                if self.playbackState == .playing {
                    self.handleTrackEnded()
                }
            }
        }

        currentTime = clampedTime
        if playbackState == .playing {
            playerNode.play()
        }
    }

    // MARK: - EQ

    func setEQEnabled(_ enabled: Bool) {
        guard enabled != isEQEnabled else { return }
        isEQEnabled = enabled
        for (index, band) in eqNode.bands.enumerated() {
            band.bypass = !enabled
            if enabled {
                band.gain = eqGains[index]
            }
        }

        // Physically insert/remove the EQ node from the graph. Pausing the
        // engine preserves the player's scheduled file; the reconnect takes
        // effect when the engine restarts.
        //
        // IMPORTANT: disconnecting/reconnecting the graph RESETS the player
        // node, which fires the currently-scheduled segment's completion
        // handler. Without a fresh generation guard that handler was still
        // "current" — so selecting a sound style mid-track made
        // `handleTrackEnded()` auto-advance to the next song. Preserve the
        // playback position by re-scheduling the file from the saved frame
        // (mirroring the seek path) and bumping the generation first, so the
        // stale handler is swallowed and the new one only fires at the true
        // end of the track.
        let wasPlaying = playbackState == .playing
        let resumeTime = currentTime
        engine.pause()
        reconnectGraph()

        if let file = audioFile {
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = file.length
            let framePosition = AVAudioFramePosition(resumeTime * sampleRate)
            let clampedFrame = min(max(framePosition, 0), totalFrames)
            let remainingFrames = max(0, totalFrames - clampedFrame)

            if remainingFrames > 0 {
                playbackGeneration &+= 1
                let generation = playbackGeneration
                playerNode.stop()
                playerNode.reset()
                file.framePosition = clampedFrame
                startFrameOffset = clampedFrame
                playerNode.scheduleSegment(
                    file,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, self.playbackGeneration == generation else { return }
                        if self.playbackState == .playing {
                            self.handleTrackEnded()
                        }
                    }
                }
                currentTime = resumeTime
            }

            startEngineIfNeeded()
            if wasPlaying {
                playerNode.play()
                playbackState = .playing
            }
        } else {
            if wasPlaying {
                startEngineIfNeeded()
                playerNode.play()
            } else {
                startEngineIfNeeded()
            }
        }
    }

    func setEQGains(_ gains: [Float]) {
        guard gains.count == 10 else { return }
        eqGains = gains
    }

    /// Applies a named EQ sound style. The "Flat (Off)" style physically
    /// disables the EQ; every other style boosts/cuts the relevant bands and
    /// enables the EQ in one pass.
    ///
    /// When the EQ is ALREADY connected, switching between non-flat presets
    /// only updates the live band gains — no graph reconnection — so playback
    /// is never interrupted and the change is audible immediately. The graph
    /// is only touched when crossing the on/off boundary.
    func applyEQPreset(_ preset: EQPreset) {
        if preset.isOff {
            if isEQEnabled {
                setEQEnabled(false)
            }
        } else {
            setEQGains(preset.gains)
            if !isEQEnabled {
                setEQEnabled(true)
            }
        }
    }

    private func updateEQ() {
        for (index, band) in eqNode.bands.enumerated() where index < eqGains.count {
            band.gain = eqGains[index]
        }
    }

    // MARK: - Private

    private func loadAndPlay(_ track: Track) {
        playbackState = .loading
        currentTrack = track
        currentTime = 0

        // Reset seek offset for a fresh track
        startFrameOffset = 0

        // Invalidate any pending completion handlers for previous playback
        playbackGeneration &+= 1
        let generation = playbackGeneration

        // Stop and clear the player node — this also cancels
        // any stale completion handlers from previous tracks.
        playerNode.stop()
        playerNode.reset()

        // Load the audio file OFF the main thread. AVAudioFile(forReading:)
        // performs disk I/O + header parsing, which can stall the UI for
        // large hi-res FLAC/ALAC files. The decoded file object is then
        // scheduled and played on the main actor.
        let url = track.url
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let loadedFile: AVAudioFile?
            do {
                loadedFile = try AVAudioFile(forReading: url)
            } catch {
                loadedFile = nil
            }

            await MainActor.run {
                // Bail if a newer track was requested while loading
                guard self.playbackGeneration == generation else { return }

                guard let file = loadedFile else {
                    print("Failed to load track: \(url.lastPathComponent)")
                    self.playbackError = "Failed to load \"\(track.displayTitle)\".\n\nCould not read the audio file."
                    self.audioFile = nil
                    self.playbackState = .stopped
                    return
                }

                self.audioFile = file
                self.duration = Double(file.length) / file.processingFormat.sampleRate

                // Pause the engine so we can safely reconfigure the hardware
                self.engine.pause()

                // Switch the DAC sample rate to match the source (bit-perfect)
                let sourceRate = file.processingFormat.sampleRate
                if sourceRate > 0 {
                    self.switchSampleRate(to: sourceRate)
                }

                // Restart the engine at the new hardware rate
                self.startEngineIfNeeded()

                // Now schedule and play the file
                self.playerNode.scheduleFile(file, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, self.playbackGeneration == generation else { return }
                        if self.playbackState == .playing {
                            self.handleTrackEnded()
                        }
                    }
                }

                self.playerNode.play()
                self.playbackState = .playing
                self.refreshCurrentTime()
            }
        }
    }

    private func handleTrackEnded() {
        // Repeat current track if enabled
        if isRepeatEnabled, let track = currentTrack {
            loadAndPlay(track)
            return
        }

        // Play "Play Next" tracks first
        if !pendingNextTracks.isEmpty {
            let nextTrack = pendingNextTracks.removeFirst()

            // Insert the pending track into the main queue right after the
            // current position so next/prev navigation stays consistent.
            if let currentIdx = queue.firstIndex(where: { $0.id == currentTrack?.id }) {
                queue.insert(nextTrack, at: currentIdx + 1)
                currentIndex = currentIdx + 1
            } else {
                queue.insert(nextTrack, at: 0)
                currentIndex = 0
            }
            loadAndPlay(nextTrack)
            return
        }

        // Auto-advance to next track — disabled via Settings ("Auto-advance
        // to next track" off) means playback stops when the track ends.
        guard ThemeManager.shared.autoAdvance else {
            stop()
            return
        }

        if !queue.isEmpty {
            next()
        } else {
            stop()
        }
    }

    /// Polls the player node for the current playback position.
    ///
    /// Views call this on their OWN lightweight timer (1s) — it updates the
    /// plain `currentTime` property WITHOUT going through @Published.
    /// This is the key to low CPU: no objectWillChange storm reaches
    /// ContentView, FloatingPlaybar, or the fullscreen player while a song
    /// is playing. Only the tiny seekbar view re-renders.
    func refreshCurrentTime() {
        guard let file = audioFile, !isSeeking else { return }

        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let sampleRate = file.processingFormat.sampleRate
            if sampleRate > 0 {
                // playerTime.sampleTime is relative to the node start (0),
                // but our file may be scheduled from an offset after seek.
                // Add the file's start frame offset to get the true position.
                let time = (Double(playerTime.sampleTime) + Double(startFrameOffset)) / sampleRate
                currentTime = min(max(time, 0), duration)
            }
        }
    }
}
