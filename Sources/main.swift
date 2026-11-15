import AppKit
import CryptoKit
import Foundation
import Darwin

func runSelfTests() throws {
    try require(Counters(read: 1, write: 2).change(since: nil).isEmpty, "first observation is silent")
    try require(Counters(read: 20, write: 31).change(since: .init(read: 19, write: 30)) == [.read, .write],
                "reads and writes can coexist")
    try require(Counters(read: 2, write: 31).change(since: .init(read: 19, write: 30)) == .write,
                "counter reset does not sound")
    let mix = Mix()
    let pair = Click.Pair(mix)
    try require(pair.read.count == 1056 && pair.write.count == 1056 && pair.read != pair.write, "click shape")
    func hash(_ samples: [Int16]) -> String {
        samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }
    try require(hash(pair.read) == "f1764ed79fec2f8030d7b8c6bcf953a6a081bece375f23de983847de7b581dfa",
                "read PCM matches Sensor Readout 6.6.1")
    try require(hash(pair.write) == "d3294e1711c822d36625437b88f2797085b8801cb4f838ca68f719d886c744cb",
                "write PCM matches Sensor Readout 6.6.1")
    let combined = Click.render([([.read, .write], pair)])
    try require(combined.count == 1824 && Array(combined.prefix(Click.stagger * 2)) == Array(pair.read.prefix(384)),
                "distinct onsets and 19 ms cap")
    var left = mix
    left.pan = -100
    try require(Click.Pair(left).read.enumerated().filter { !$0.offset.isMultiple(of: 2) }.allSatisfy { $0.element == 0 },
                "hard left")
    var right = mix
    right.pan = 100
    try require(Click.Pair(right).write.enumerated().filter { $0.offset.isMultiple(of: 2) }.allSatisfy { $0.element == 0 },
                "hard right")
    var boosted = mix
    boosted.treble = 100
    try require(Click.Pair(boosted).read != pair.read, "EQ affects the sound")
    var prefs = Preferences()
    prefs.listening = true
    prefs.shortcut = nil
    prefs.mixes["physical"] = boosted
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
    try require(restored.listening && restored.shortcut == nil && restored.mixes == prefs.mixes, "settings round trip")
    try require(Updater.parts("1.0.1") == [1, 0, 1] && Updater.parts("1.01.0") == nil &&
                Updater.parts("1.0.1-beta") == nil, "canonical release versions")
    let valid = Updater.GitHubRelease.Asset(name: "Plattersong-1.0.1-macOS.zip", size: 100,
        browser_download_url: URL(string: "https://github.com/OnjLouis/Plattersong/releases/download/v1.0.1/Plattersong-1.0.1-macOS.zip")!)
    let release = Updater.GitHubRelease(tag_name: "v1.0.1", draft: false, prerelease: false, body: "Notes", assets: [valid])
    let update = try Updater.candidate(release, installed: "1.0.0")
    let downgrade = try Updater.candidate(release, installed: "1.0.2")
    try require(update?.notes == "Notes" && downgrade == nil, "official asset and no downgrade")
    try reject {
        _ = try Updater.candidate(.init(tag_name: "v1.0.1", draft: true, prerelease: false, body: nil, assets: [valid]),
                                  installed: "1.0.0")
    }
    try reject { try Updater.validateEntries("Plattersong.app/Contents/MacOS/Plattersong\n../escape", "") }
    try reject { try Updater.validateEntries("Plattersong.app/Contents/MacOS/Plattersong", "lrwxrwxrwx example") }
    print("PASS: counter baselines, read/write timing, stereo, EQ, persistence, catalog and archive rejection")
}

func require(_ condition: Bool, _ name: String) throws {
    if !condition { throw UpdateFailure.invalid("Test failed: \(name)") }
}

func reject(_ test: () throws -> Void) throws {
    do { try test() } catch { return }
    throw UpdateFailure.invalid("Test failed: invalid input accepted.")
}

func ioProbe(_ path: String) throws {
    let disks = DiskService.discover()
    try require(!disks.isEmpty, "physical disks enumerated")
    print("Physical disks: " + disks.map { $0.disk.title }.joined(separator: ", "))
    let saved = Dictionary(uniqueKeysWithValues: disks.compactMap { disk in disk.counters().map { (disk.generation, $0) } })
    let url = URL(fileURLWithPath: path)
    let writeFD = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    try require(writeFD >= 0, "fixture created")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
    try require(fcntl(writeFD, F_NOCACHE, 1) == 0, "fixture write bypasses cache")
    try writer.write(contentsOf: Data(repeating: 42, count: 8 * 1024 * 1024))
    try writer.synchronize()
    try writer.close()
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    try require(fcntl(file.fileDescriptor, F_NOCACHE, 1) == 0, "fixture read bypasses cache")
    let data = try file.readToEnd()
    try require(data?.count == 8 * 1024 * 1024, "fixture read complete")
    var changed: Activity = []
    for _ in 0..<20 {
        changed = disks.reduce(into: Activity()) { result, disk in
            if let value = disk.counters() { result.formUnion(value.change(since: saved[disk.generation])) }
        }
        if changed == [.read, .write] { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    try require(changed.contains(.read), "a physical disk reported reads")
    try require(changed.contains(.write), "a physical disk reported writes")
    print("PASS: live read and write counters advanced using a disposable fixture")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "--self-test":
        try runSelfTests()
    case "--io-probe" where arguments.count == 2:
        try ioProbe(arguments[1])
    case "--verify-update" where arguments.count == 3:
        try Updater.verify(URL(fileURLWithPath: arguments[1]), version: arguments[2], assess: false)
        print("PASS: Developer ID, bundle identifier, version and native architecture")
    case "--prepare-update" where arguments.count == 4:
        _ = try Updater.prepare(zip: URL(fileURLWithPath: arguments[1]), staging: URL(fileURLWithPath: arguments[2]),
                                version: arguments[3])
        print("PASS: archive allowlist, extraction, version, notarized Developer ID and native architecture")
    case "--test-install" where arguments.count == 4:
        print(Updater.installer(stageApp: URL(fileURLWithPath: arguments[1]), target: URL(fileURLWithPath: arguments[2]),
                                staging: URL(fileURLWithPath: arguments[3]), pid: Int32.max, reopen: false))
    default:
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppController(uiSmoke: arguments == ["--ui-smoke"])
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
