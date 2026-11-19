import AppKit
import AVFoundation
import CryptoKit
import DiskArbitration
import Foundation
import IOKit

struct Mix: Codable, Equatable {
    static let pitchRange = 50...200
    static let defaultPitch = 100

    var enabled = false
    var volume = 30
    var pan = 0
    var bass = 50
    var mid = 50
    var treble = 50
    var readPitch = defaultPitch
    var writePitch = defaultPitch

    init(enabled: Bool = false, volume: Int = 30, pan: Int = 0, bass: Int = 50, mid: Int = 50,
         treble: Int = 50, readPitch: Int = defaultPitch, writePitch: Int = defaultPitch) {
        self.enabled = enabled
        self.volume = volume
        self.pan = pan
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.readPitch = Self.clampPitch(readPitch)
        self.writePitch = Self.clampPitch(writePitch)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(enabled: values.decode(Bool.self, forKey: .enabled),
                      volume: values.decode(Int.self, forKey: .volume), pan: values.decode(Int.self, forKey: .pan),
                      bass: values.decode(Int.self, forKey: .bass), mid: values.decode(Int.self, forKey: .mid),
                      treble: values.decode(Int.self, forKey: .treble),
                      readPitch: values.decodeIfPresent(Int.self, forKey: .readPitch) ?? Self.defaultPitch,
                      writePitch: values.decodeIfPresent(Int.self, forKey: .writePitch) ?? Self.defaultPitch)
    }

    private static func clampPitch(_ value: Int) -> Int {
        clamp(value, pitchRange.lowerBound, pitchRange.upperBound)
    }

    static func clamp(_ value: Int, _ lower: Int = 0, _ upper: Int = 100) -> Int {
        min(upper, max(lower, value))
    }
}

struct Counters: Equatable {
    let read: UInt64
    let write: UInt64

    func change(since previous: Self?) -> Activity {
        guard let previous else { return [] }
        var result: Activity = []
        if read > previous.read { result.insert(.read) }
        if write > previous.write { result.insert(.write) }
        return result
    }
}

struct Activity: OptionSet {
    let rawValue: Int
    static let read = Self(rawValue: 1)
    static let write = Self(rawValue: 2)
}

enum Click {
    static let rate = 48_000
    static let frames = rate * 11 / 1_000
    static let stagger = rate * 4 / 1_000
    static let batchFrames = frames + 2 * stagger

    // Keep each click's default tone and duration when its pitch is 100 percent.
    static func synthesize(_ mix: Mix, write: Bool) -> [Int16] {
        let pan = Double(Mix.clamp(mix.pan, -100)) / 100
        let angle = (1 + pan * (2 - abs(pan))) * Double.pi / 4
        let level = 3500 * Double(Mix.clamp(mix.volume)) / 100
        let left = level * cos(angle)
        let right = level * sin(angle)
        func gain(_ position: Int) -> Double {
            pow(10, Double(Mix.clamp(position) - 50) * 12 / 50 / 20)
        }
        let bass = gain(mix.bass), mid = gain(mix.mid), treble = gain(mix.treble)
        let pitch = (write ? 0.68 : 1) * Double(write ? mix.writePitch : mix.readPitch) / Double(Mix.defaultPitch)
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let phase = 2 * Double.pi * pitch * Double(frame) / Double(rate)
            let envelope = min(1, Double(frame) / 16) * pow(1 - Double(frame) / Double(frames), 3)
            let sample = envelope * (bass * sin(phase * 360) + mid * sin(phase * 1250) + treble * sin(phase * 3900))
            pcm[2 * frame] = Int16(clamping: Int(sample * left))
            pcm[2 * frame + 1] = Int16(clamping: Int(sample * right))
        }
        return pcm
    }

    struct Pair {
        let read: [Int16]
        let write: [Int16]
        init(_ mix: Mix) {
            read = Click.synthesize(mix, write: false)
            write = Click.synthesize(mix, write: true)
        }
    }

    static func render(_ active: [(Activity, Pair)]) -> [Int16] {
        var sum = [Int32](repeating: 0, count: batchFrames * 2)
        func add(_ pcm: [Int16], at frame: Int) {
            for i in pcm.indices { sum[frame * 2 + i] += Int32(pcm[i]) }
        }
        for (i, item) in active.enumerated() {
            let offset = i.isMultiple(of: 2) ? 0 : stagger
            if item.0.contains(.read) { add(item.1.read, at: offset) }
            if item.0.contains(.write) { add(item.1.write, at: offset + (item.0.contains(.read) ? stagger : 0)) }
        }
        return sum.map { Int16(clamping: $0) }
    }
}

struct Disk: Equatable {
    let id: String
    let bsd: String
    let model: String
    var title: String { "\(model) (\(bsd))" }
}

final class DiskService {
    private let handle: io_registry_entry_t
    let generation: UInt64
    let disk: Disk

    init(handle: io_registry_entry_t, generation: UInt64, disk: Disk) {
        self.handle = handle
        self.generation = generation
        self.disk = disk
    }

    deinit { IOObjectRelease(handle) }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func counters() -> Counters? {
        guard let stats = Self.property(handle, "Statistics") as? [String: NSNumber],
              let read = stats["Operations (Read)"], let write = stats["Operations (Write)"] else { return nil }
        return Counters(read: read.uint64Value, write: write.uint64Value)
    }

    static func discover() -> [DiskService] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        var list: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &list)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(list) }
        var result: [DiskService] = []
        while case let driver = IOIteratorNext(list), driver != 0 {
            if let service = describe(driver, session: session) { result.append(service) }
            else { IOObjectRelease(driver) }
        }
        // Never share one mix between devices that report the same adapter identity.
        let counts = Dictionary(grouping: result, by: { $0.disk.id }).mapValues(\.count)
        return result.filter { counts[$0.disk.id] == 1 }.sorted {
            $0.disk.bsd.localizedStandardCompare($1.disk.bsd) == .orderedAscending
        }
    }

    private static func describe(_ driver: io_registry_entry_t, session: DASession) -> DiskService? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let media = IOIteratorNext(children), media != 0 {
            defer { IOObjectRelease(media) }
            guard IOObjectConformsTo(media, "IOMedia") != 0,
                  property(media, "Whole") as? Bool == true,
                  let bytes = property(media, "Size") as? NSNumber, bytes.uint64Value > 0,
                  let bsd = property(media, "BSD Name") as? String,
                  let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
                  let description = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String ?? "Disk")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transport.isEmpty, !transport.localizedCaseInsensitiveContains("virtual"),
                  !model.localizedCaseInsensitiveContains("disk image") else { continue }
            var parent: io_registry_entry_t = 0
            var device: [String: Any] = [:], protocolInfo: [String: Any] = [:]
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS {
                device = property(parent, "Device Characteristics") as? [String: Any] ?? [:]
                protocolInfo = property(parent, "Protocol Characteristics") as? [String: Any] ?? [:]
                IOObjectRelease(parent)
            }
            let serial = (device["Serial Number"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = description[kDADiskDescriptionDevicePathKey as String] as? String ?? ""
            let mediaUUID = property(media, "UUID") as? String
            let lun = (protocolInfo["SCSI Logical Unit Number"] as? NSNumber)?.stringValue ?? ""
            let identity: String
            if let serial, !serial.isEmpty, serial.contains(where: { !"0 -".contains($0) }) {
                identity = "serial:\(serial):\(lun)"
            } else if let mediaUUID, !mediaUUID.isEmpty { identity = "media:\(mediaUUID)" }
            else if !path.isEmpty { identity = "port:\(path)" }
            else { continue }
            let key = SHA256.hash(data: Data("\(model):\(bytes):\(identity)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            var generation: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &generation) == KERN_SUCCESS else { continue }
            return DiskService(handle: driver, generation: generation, disk: Disk(id: key, bsd: bsd, model: model))
        }
        return nil
    }
}

final class AudioOutput {
    private let engine = AVAudioEngine()
    private let live = AVAudioPlayerNode()
    private let preview = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(Click.rate), channels: 2)!
    private var queued = 0
    private var generation = 0
    private var lastSound: UInt64 = 0
    private let queue: DispatchQueue
    private let onError: () -> Void
    private var lastFailure: UInt64 = 0
    private var observer: NSObjectProtocol?

    init(queue: DispatchQueue, onError: @escaping () -> Void) {
        self.queue = queue
        self.onError = onError
        for node in [live, preview] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                         object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.reset() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func play(_ pcm: [Int16], isPreview: Bool = false) {
        guard isPreview || queued < 2 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if !engine.isRunning {
            guard lastFailure == 0 || isPreview || now - lastFailure >= 2_000_000_000 else { return }
            do { try engine.start(); lastFailure = 0 }
            catch { if lastFailure == 0 || isPreview { onError() }; lastFailure = now; return }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            channels[0][frame] = Float(pcm[2 * frame]) / 32768
            channels[1][frame] = Float(pcm[2 * frame + 1]) / 32768
        }
        lastSound = now
        if isPreview {
            preview.stop()
            preview.scheduleBuffer(buffer)
            preview.play()
        } else {
            queued += 1
            let token = generation
            live.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.queued = max(0, self.queued - 1)
                }
            }
            if !live.isPlaying { live.play() }
        }
    }

    func idleIfNeeded(now: UInt64) {
        if engine.isRunning, now - lastSound >= 2_000_000_000 { reset() }
    }

    func reset() {
        generation += 1
        queued = 0
        live.stop()
        preview.stop()
        engine.stop()
    }
}

final class DiskMonitor {
    private static let discoveryInterval = DispatchTimeInterval.seconds(5)
    private static let discoveryNanoseconds: UInt64 = 4_750_000_000
    private let queue = DispatchQueue(label: "me.onj.plattersong.audio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var topologyObservers: [NSObjectProtocol] = []
    private var output: AudioOutput!
    private var services: [DiskService] = []
    private var previous: [UInt64: Counters] = [:]
    private var mixes: [String: Click.Pair] = [:]
    private var settings: [String: Mix] = [:]
    private var enabled = false
    private var isSampling = false
    private var lastScan: UInt64?
    private let onDisks: ([Disk]) -> Void

    init(onDisks: @escaping ([Disk]) -> Void, onAudioError: @escaping () -> Void) {
        self.onDisks = onDisks
        output = AudioOutput(queue: queue) { DispatchQueue.main.async(execute: onAudioError) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: Self.discoveryInterval, leeway: .milliseconds(250))
        timer.resume()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            topologyObservers.append(workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.tick(forceDiscovery: true) }
            })
        }
    }

    deinit {
        timer?.cancel()
        for observer in topologyObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func configure(enabled: Bool, settings: [String: Mix]) {
        queue.async {
            if self.enabled != enabled { self.previous.removeAll(); self.output.reset() }
            self.enabled = enabled
            for key in self.mixes.keys where settings[key]?.enabled != true || settings[key]?.volume == 0 {
                self.mixes.removeValue(forKey: key)
            }
            for (key, mix) in settings where mix.enabled && mix.volume > 0 && self.settings[key] != mix {
                self.mixes[key] = Click.Pair(mix)
                for service in self.services where service.disk.id == key {
                    self.previous.removeValue(forKey: service.generation)
                }
            }
            self.settings = settings
            self.updateTimer()
        }
    }

    func preview(_ mix: Mix, write: Bool) {
        queue.async { [self] in
            let click = Click.synthesize(mix, write: write)
            let interval = Click.rate * 120 / 1_000 * 2
            var pcm = [Int16](repeating: 0, count: interval * 10)
            for i in 0..<10 { pcm.replaceSubrange(i * interval..<i * interval + click.count, with: click) }
            self.output.play(pcm, isPreview: true)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(2100)) { [weak self] in
                self?.output.idleIfNeeded(now: DispatchTime.now().uptimeNanoseconds)
            }
        }
    }

    private func updateTimer() {
        let active = enabled && services.contains { mixes[$0.disk.id] != nil }
        guard active != isSampling else { return }
        isSampling = active
        let interval: DispatchTimeInterval = active ? .milliseconds(25) : Self.discoveryInterval
        timer?.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: active ? .milliseconds(3) : .milliseconds(250))
    }

    private func tick(forceDiscovery: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if forceDiscovery || (lastScan.map { now - $0 >= Self.discoveryNanoseconds } ?? true) {
            lastScan = now
            let old = services.map(\.disk)
            let priorIdentity = Dictionary(uniqueKeysWithValues: services.map { ($0.generation, $0.disk.id) })
            services = DiskService.discover()
            let current = services.map(\.disk)
            let connected = Set(services.filter { priorIdentity[$0.generation] == $0.disk.id }.map(\.generation))
            previous = previous.filter { connected.contains($0.key) }
            if current != old { DispatchQueue.main.async { self.onDisks(current) } }
            updateTimer()
        }
        var active: [(Activity, Click.Pair)] = []
        if enabled {
            for service in services {
                guard let mix = mixes[service.disk.id], let counters = service.counters() else {
                    previous.removeValue(forKey: service.generation)
                    continue
                }
                let change = counters.change(since: previous.updateValue(counters, forKey: service.generation))
                if !change.isEmpty { active.append((change, mix)) }
            }
        }
        if !active.isEmpty { output.play(Click.render(active)) }
        output.idleIfNeeded(now: DispatchTime.now().uptimeNanoseconds)
    }
}
