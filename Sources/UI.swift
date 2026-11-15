import AppKit
import AVFoundation
import Carbon
import ServiceManagement

struct Shortcut: Codable, Equatable {
    let key: UInt32
    let modifiers: UInt32
    let display: String

    static let initial = Shortcut(key: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey),
                                  display: "Control+Shift+K")
}

struct Preferences: Codable {
    var listening = false
    var mixes: [String: Mix] = [:]
    var shortcut: Shortcut? = .initial
    var feedback = 0
}

@MainActor final class GlobalShortcut {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var number: UInt32 = 0
    var toggle: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x504C5452, id.id == owner.number else { return OSStatus(eventNotHandledErr) }
            owner.toggle?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func install(_ shortcut: Shortcut?) -> Bool {
        guard let shortcut else {
            if let registration { UnregisterEventHotKey(registration) }
            registration = nil
            return true
        }
        guard handler != nil else { return false }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x504C5452, id: number &+ 1)
        guard RegisterEventHotKey(shortcut.key, shortcut.modifiers, id, GetApplicationEventTarget(),
                                  UInt32(kEventHotKeyExclusive), &next) == noErr else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        number = id.id
        registration = next
        return true
    }

    func close() {
        _ = install(nil)
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

final class MixSlider: NSSlider {
    var describe: (Int) -> String = { String($0) }
    override func accessibilityValueDescription() -> String? { describe(integerValue) }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event); return
        }
        let next: Int
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_DownArrow: next = integerValue - 1
        case kVK_RightArrow, kVK_UpArrow: next = integerValue + 1
        case kVK_PageDown: next = integerValue - 10
        case kVK_PageUp: next = integerValue + 10
        case kVK_Home: next = Int(minValue)
        case kVK_End: next = Int(maxValue)
        default: super.keyDown(with: event); return
        }
        integerValue = Mix.clamp(next, Int(minValue), Int(maxValue))
        sendAction(action, to: target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

final class SettingsWindow: NSWindow {
    var focusOrder: [NSView] = []
    var help: (() -> Void)?
    var project: (() -> Void)?
    var updates: (() -> Void)?
    var captureShortcut: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { super.sendEvent(event); return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if captureShortcut?(event) == true { return }
        switch (Int(event.keyCode), flags) {
        case (kVK_F1, .control), (kVK_F1, .command): project?(); return
        case (kVK_F1, .shift): updates?(); return
        case (kVK_F1, []): help?(); return
        case (kVK_Escape, []): performClose(nil); return
        case (kVK_ANSI_W, .command): performClose(nil); return
        case (kVK_Tab, []), (kVK_Tab, .shift):
            let controls = focusOrder.filter { !($0 is NSControl) || ($0 as? NSControl)?.isEnabled == true }
            let index = controls.firstIndex { $0 === firstResponder }
            if !controls.isEmpty {
                let next = index.map { ($0 + (flags == .shift ? controls.count - 1 : 1)) % controls.count }
                    ?? (flags == .shift ? controls.count - 1 : 0)
                makeFirstResponder(controls[next])
            }
            return
        default: break
        }
        super.sendEvent(event)
    }
}

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let storageKey = "Plattersong.preferences.v1"
    private var prefs: Preferences
    private let persisted = UserDefaults.standard
    private var disks: [Disk] = []
    private var diskID: String? { disks.indices.contains(diskPicker.indexOfSelectedItem) ? disks[diskPicker.indexOfSelectedItem].id : nil }
    private var monitor: DiskMonitor!
    private let global = GlobalShortcut()
    private var statusItem: NSStatusItem!
    private var monitorItem: NSMenuItem!
    private var window: SettingsWindow!
    private let diskPicker = NSPopUpButton()
    private let enabled = NSButton(checkboxWithTitle: "Enable this disk", target: nil, action: nil)
    private let volume = MixSlider()
    private let pan = MixSlider()
    private let bass = MixSlider()
    private let mid = MixSlider()
    private let treble = MixSlider()
    private let shortcut = NSButton()
    private let feedback = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previewRead = NSButton()
    private let previewWrite = NSButton()
    private let reset = NSButton()
    private let start = NSButton()
    private let speech = AVSpeechSynthesizer()
    private var recordingShortcut = false
    private var shortcutAvailable = false
    private var checking = false
    private var noFocus = false
    private let uiSmoke: Bool

    init(uiSmoke: Bool = false) {
        self.uiSmoke = uiSmoke
        if uiSmoke {
            prefs = Preferences()
        } else if let data = UserDefaults.standard.data(forKey: Self.storageKey),
                  let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            prefs = saved
        } else { prefs = Preferences() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        makeMenus()
        monitor = DiskMonitor(onDisks: { [weak self] disks in self?.updateDisks(disks) },
                              onAudioError: { [weak self] in self?.message("Audio output is unavailable. Plattersong will retry.") })
        global.toggle = { [weak self] in self?.toggleMonitoring() }
        if !uiSmoke { shortcutAvailable = global.install(prefs.shortcut) }
        refresh()
        configure()
        if uiSmoke {
            showSettings()
            do { try runUISmoke() }
            catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                global.close()
                exit(1)
            }
            return
        }
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let event = launch?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        if persisted.data(forKey: Self.storageKey) == nil && event != OSType(keyAELaunchedAsLogInItem) {
            save()
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { global.close() }
    func windowDidBecomeKey(_ notification: Notification) { refreshLogin() }
    func windowWillClose(_ notification: Notification) {
        recordingShortcut = false
        refreshShortcut()
    }

    private var projectURL: URL { URL(string: "https://github.com/OnjLouis/Plattersong")! }
    private func save() {
        guard !uiSmoke, let data = try? JSONEncoder().encode(prefs) else { return }
        persisted.set(data, forKey: Self.storageKey)
    }
    private func configure() { monitor.configure(enabled: prefs.listening, settings: prefs.mixes) }

    private func makeMenus() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let commands = NSMenu()
        app.submenu = commands
        menu.addItem(app)
        commands.addItem(item("About Plattersong", #selector(about)))
        commands.addItem(item("Settings...", #selector(showSettings), ","))
        commands.addItem(item("Check for Updates...", #selector(checkUpdates)))
        commands.addItem(.separator())
        commands.addItem(item("Hide Plattersong", #selector(hideWindow), "h"))
        commands.addItem(item("Quit Plattersong", #selector(quit), "q"))
        let help = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        help.submenu = helpMenu
        menu.addItem(help)
        helpMenu.addItem(item("Plattersong Manual", #selector(manual)))
        let project = item("GitHub Project", #selector(openProject), String(UnicodeScalar(NSF1FunctionKey)!))
        project.keyEquivalentModifierMask = .control
        helpMenu.addItem(project)
        helpMenu.addItem(item("Donate", #selector(donate)))
        NSApp.mainMenu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let tray = NSMenu()
        monitorItem = item("Start Monitoring", #selector(toggleMonitoring))
        tray.addItem(monitorItem)
        tray.addItem(item("Settings...", #selector(showSettings), ","))
        tray.addItem(.separator())
        tray.addItem(item("Check for Updates...", #selector(checkUpdates)))
        tray.addItem(item("Plattersong Manual", #selector(manual)))
        tray.addItem(item("GitHub Project", #selector(openProject)))
        tray.addItem(item("Donate", #selector(donate)))
        tray.addItem(.separator())
        tray.addItem(item("Quit Plattersong", #selector(quit), "q"))
        statusItem.menu = tray
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func button(_ button: NSButton, _ title: String, _ action: Selector, _ hint: String) {
        button.title = title
        button.bezelStyle = .rounded
        setup(button, title, action, hint)
    }
    private func setup(_ control: NSControl, _ name: String, _ action: Selector, _ hint: String) {
        control.target = self
        control.action = action
        control.setAccessibilityLabel(name)
        control.setAccessibilityHelp(hint)
        control.toolTip = hint
        // AppKit can report AXUnknown for controls in an accessory window before activation.
        if control is NSPopUpButton { control.setAccessibilityRole(.popUpButton) }
        else if control is NSSlider { control.setAccessibilityRole(.slider) }
        else if control === enabled || control === login { control.setAccessibilityRole(.checkBox) }
        else if control is NSButton { control.setAccessibilityRole(.button) }
    }

    private func makeWindow() {
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Plattersong Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.help = { [weak self] in self?.focusedHelp() }
        window.project = { [weak self] in self?.openProject() }
        window.updates = { [weak self] in self?.checkUpdates() }
        window.captureShortcut = { [weak self] event in self?.capture(event) ?? false }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        window.contentView = stack
        let width = stack.widthAnchor
        func row(_ name: String, _ control: NSControl, value: NSTextField? = nil) {
            let label = NSTextField(labelWithString: name)
            label.widthAnchor.constraint(equalToConstant: 145).isActive = true
            let row = NSStackView(views: [label, control] + (value.map { [$0] } ?? []))
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: width, constant: -40).isActive = true
        }
        setup(diskPicker, "Physical disk", #selector(selectionChanged), "Choose a physical disk to tune.")
        diskPicker.addItem(withTitle: "No supported disks connected")
        row("Physical disk", diskPicker)
        setup(enabled, "Enable this disk", #selector(mixChanged), "Include this disk when monitoring is on.")
        stack.addArrangedSubview(enabled)
        let sliders: [(MixSlider, String, Int, (Int) -> String)] = [
            (volume, "Volume", 0, { "\($0) percent" }),
            (pan, "Pan", -100, { $0 == 0 ? "Center" : "\($0 < 0 ? "Left" : "Right") \(abs($0)) percent" }),
            (bass, "Bass", 0, Self.eqValue), (mid, "Midrange", 0, Self.eqValue), (treble, "Treble", 0, Self.eqValue)
        ]
        for (slider, name, min, description) in sliders {
            slider.minValue = Double(min)
            slider.maxValue = 100
            slider.isContinuous = true
            slider.describe = description
            setup(slider, name, #selector(mixChanged),
                  "Arrow keys adjust by one step. Page Up and Page Down adjust by ten. Home and End set the endpoints.")
            let value = NSTextField(labelWithString: "")
            value.widthAnchor.constraint(equalToConstant: 140).isActive = true
            value.setAccessibilityElement(false)
            levelLabels.append(value)
            row(name, slider, value: value)
        }
        button(previewRead, "Preview Read", #selector(tryRead), "Hear the read sound with this disk's current mix.")
        button(previewWrite, "Preview Write", #selector(tryWrite), "Hear the write sound with this disk's current mix.")
        button(reset, "Reset Mix", #selector(resetMix), "Restore the default volume, pan and EQ for this disk.")
        stack.addArrangedSubview(NSStackView(views: [previewRead, previewWrite, reset]))
        button(shortcut, "Change Shortcut...", #selector(changeShortcut), "Record a global shortcut with at least two modifiers.")
        let clear = NSButton()
        button(clear, "Clear", #selector(clearShortcut), "Remove the global monitoring shortcut.")
        let shortcutLine = NSStackView(views: [shortcut, clear])
        let shortcutLabel = NSTextField(labelWithString: "Global toggle hotkey")
        shortcutLabel.widthAnchor.constraint(equalToConstant: 145).isActive = true
        stack.addArrangedSubview(NSStackView(views: [shortcutLabel, shortcutLine]))
        feedback.addItems(withTitles: ["Spoken", "Chime", "None"])
        setup(feedback, "Start/stop feedback", #selector(feedbackChanged), "Choose how Plattersong confirms monitoring changes.")
        row("Start/stop feedback", feedback)
        setup(login, "Open at login", #selector(loginChanged), "Launch in the menu bar when you sign in to this Mac.")
        stack.addArrangedSubview(login)
        button(start, "Start Monitoring", #selector(toggleMonitoring), "Toggle live read and write sounds. Plattersong remembers this state.")
        let close = NSButton()
        button(close, "Close", #selector(hideWindow), "Close settings and keep Plattersong in the menu bar.")
        stack.addArrangedSubview(NSStackView(views: [start, close]))
        status.setAccessibilityLabel("Monitoring status")
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(lessThanOrEqualTo: width, constant: -40).isActive = true
        let order: [NSView] = [diskPicker, enabled, volume, pan, bass, mid, treble, previewRead, previewWrite,
                               reset, shortcut, clear, feedback, login, start, close]
        for (i, view) in order.enumerated() { view.nextKeyView = order[(i + 1) % order.count] }
        window.focusOrder = order
        window.initialFirstResponder = diskPicker
        window.center()
    }

    private var levelLabels: [NSTextField] = []
    private static func eqValue(_ percent: Int) -> String {
        let db = Double(percent - 50) * 12 / 50
        if db == 0 { return "Flat, 0 dB" }
        return "\(db > 0 ? "Plus" : "Minus") \(String(format: "%.2f", abs(db))) dB"
    }
    private var sliders: [MixSlider] { [volume, pan, bass, mid, treble] }

    private func updateDisks(_ next: [Disk]) {
        guard next != disks else { return }
        let previous = diskID
        disks = next
        diskPicker.removeAllItems()
        if next.isEmpty { diskPicker.addItem(withTitle: "No supported disks connected") }
        else { diskPicker.addItems(withTitles: next.map(\.title)) }
        diskPicker.selectItem(at: next.firstIndex { $0.id == previous } ?? 0)
        refreshSelection()
        refreshStatus()
    }

    private func refreshSelection() {
        let mix = diskID.flatMap { prefs.mixes[$0] } ?? Mix()
        enabled.state = mix.enabled ? .on : .off
        for (slider, value) in zip(sliders, [mix.volume, mix.pan, mix.bass, mix.mid, mix.treble]) { slider.integerValue = value }
        for control in [enabled, volume, pan, bass, mid, treble, previewRead, previewWrite, reset] as [NSControl] {
            control.isEnabled = diskID != nil
        }
        updateValues()
    }
    private func updateValues() {
        for (slider, label) in zip(sliders, levelLabels) { label.stringValue = slider.describe(slider.integerValue) }
    }
    private func refresh() {
        refreshSelection()
        refreshLogin()
        feedback.selectItem(at: Mix.clamp(prefs.feedback, 0, 2))
        refreshShortcut()
        refreshStatus()
    }
    private func refreshShortcut() {
        let name = prefs.shortcut?.display ?? "None"
        shortcut.title = recordingShortcut ? "Press shortcut now" : "Change: \(name)"
        shortcut.setAccessibilityLabel(recordingShortcut ? "Press shortcut now" : "Global toggle hotkey: \(name)")
    }
    private func refreshStatus() {
        let title = prefs.listening ? "Stop Monitoring" : "Start Monitoring"
        start.title = title
        start.setAccessibilityLabel(title)
        monitorItem.title = title
        monitorItem.state = prefs.listening ? .on : .off
        statusItem.button?.image = NSImage(systemSymbolName: prefs.listening ? "internaldrive.fill" : "internaldrive",
                                           accessibilityDescription: nil)
        statusItem.button?.setAccessibilityLabel("Plattersong, monitoring \(prefs.listening ? "on" : "off")")
        let hasDisk = disks.contains { prefs.mixes[$0.id]?.enabled == true }
        status.stringValue = !prefs.listening ? "Monitoring off." : (hasDisk ? "Monitoring on." : "Monitoring on. No enabled disk is connected.")
    }
    private func refreshLogin() {
        login.state = (!uiSmoke && SMAppService.mainApp.status == .enabled) ? .on : .off
    }
    private func message(_ text: String) {
        status.stringValue = text
        NSAccessibility.post(element: window.isVisible ? window as Any : NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc private func selectionChanged() { refreshSelection() }
    @objc private func mixChanged() {
        guard let id = diskID else { return }
        prefs.mixes[id] = Mix(enabled: enabled.state == .on, volume: volume.integerValue, pan: pan.integerValue,
                              bass: bass.integerValue, mid: mid.integerValue, treble: treble.integerValue)
        updateValues()
        refreshStatus()
        save()
        configure()
    }
    @objc private func tryRead() { preview(write: false) }
    @objc private func tryWrite() { preview(write: true) }
    private func preview(write: Bool) {
        guard let id = diskID else { return }
        monitor.preview(prefs.mixes[id] ?? Mix(), write: write)
    }
    @objc private func resetMix() {
        guard let id = diskID else { return }
        prefs.mixes[id] = Mix(enabled: enabled.state == .on)
        refreshSelection()
        configure()
        save()
        message("Mix reset.")
    }
    @objc private func toggleMonitoring() {
        prefs.listening.toggle()
        save()
        configure()
        refreshStatus()
        let text = prefs.listening ? "Disk monitoring on." : "Disk monitoring off."
        if prefs.feedback == 0 {
            speech.stopSpeaking(at: .immediate)
            speech.speak(AVSpeechUtterance(string: text))
        } else if prefs.feedback == 1 {
            NSSound(named: prefs.listening ? "Glass" : "Pop")?.play()
        }
    }
    @objc private func feedbackChanged() { prefs.feedback = feedback.indexOfSelectedItem; save() }
    @objc private func loginChanged() {
        guard !uiSmoke else { return }
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                message("Approve Plattersong in System Settings, General, Login Items.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { message("Could not change Open at login. Install Plattersong in Applications and try again.") }
        refreshLogin()
    }
    @objc private func changeShortcut() {
        recordingShortcut = true
        refreshShortcut()
        window.makeFirstResponder(shortcut)
        message("Press a global shortcut with at least two modifiers. Escape cancels.")
    }
    @objc private func clearShortcut() {
        _ = global.install(nil)
        prefs.shortcut = nil
        recordingShortcut = false
        shortcutAvailable = false
        refreshShortcut()
        save()
        message("Global toggle hotkey cleared.")
    }
    private func capture(_ event: NSEvent) -> Bool {
        guard recordingShortcut else { return false }
        guard event.type == .keyDown else { return false }
        if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Tab) {
            recordingShortcut = false; refreshShortcut(); refreshStatus()
            return event.keyCode == UInt16(kVK_Escape)
        }
        let options: [(NSEvent.ModifierFlags, Int, String)] =
            [(.control, controlKey, "Control"), (.option, optionKey, "Option"),
             (.shift, shiftKey, "Shift"), (.command, cmdKey, "Command")]
        let selected = options.filter { event.modifierFlags.contains($0.0) }
        guard selected.count >= 2,
              let chars = event.charactersIgnoringModifiers?.uppercased(),
              chars.count == 1, let scalar = chars.unicodeScalars.first else {
            message("Use at least two modifiers and a letter, number or function key."); return true
        }
        let key: String
        if (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(scalar.value) {
            key = "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
        } else if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) { key = chars }
        else { message("Choose a letter, number or function key."); return true }
        let next = Shortcut(key: UInt32(event.keyCode), modifiers: UInt32(selected.reduce(0) { $0 | $1.1 }),
                            display: (selected.map { $0.2 } + [key]).joined(separator: "+"))
        guard (next == prefs.shortcut && shortcutAvailable) || global.install(next) else {
            message("That global shortcut is unavailable. Try a different combination."); return true
        }
        shortcutAvailable = true
        prefs.shortcut = next
        save()
        recordingShortcut = false
        refreshShortcut()
        message("Global toggle hotkey set to \(next.display).")
        return true
    }
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !noFocus { window.makeFirstResponder(diskPicker); noFocus = true }
        if prefs.shortcut != nil && !shortcutAvailable && !uiSmoke { message("The saved global hotkey is in use. Choose another in Settings.") }
    }
    @objc private func hideWindow() { recordingShortcut = false; refreshShortcut(); window.orderOut(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openProject() { NSWorkspace.shared.open(projectURL) }
    @objc private func donate() { NSWorkspace.shared.open(URL(string: "https://onj.me/donate")!) }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func manual() {
        if let url = Bundle.main.url(forResource: "Manual", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    private func focusedHelp() {
        if recordingShortcut { return }
        let focus = (NSApp.accessibilityFocusedUIElement as? NSView) ?? (window.firstResponder as? NSView)
        let alert = NSAlert()
        alert.messageText = focus?.accessibilityLabel() ?? "Plattersong Help"
        alert.informativeText = focus?.accessibilityHelp() ?? "Use the manual for keyboard shortcuts and monitoring instructions."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open Manual")
        alert.beginSheetModal(for: window) { [weak self, weak focus] response in
            if let focus { self?.window.makeFirstResponder(focus) }
            if response == .alertSecondButtonReturn { self?.manual() }
        }
    }
    @objc private func checkUpdates() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                let release = try await Updater.latest()
                guard let release else { showAlert("No Update Available", "You are running the latest available version."); return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Plattersong \(release.version) is available"
                alert.informativeText = String(release.notes.prefix(2000))
                alert.addButton(withTitle: "Install Update")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await Updater.install(release)
            } catch { showAlert("Could Not Update Plattersong", error.localizedDescription) }
        }
    }
    private func showAlert(_ title: String, _ details: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runUISmoke() throws {
        let fixture = Disk(id: "fixture", bsd: "disk99", model: "Test Disk")
        updateDisks([fixture])
        try require(window.focusOrder.count == 16, "16 controls in key order")
        for control in window.focusOrder {
            try require(!(control.accessibilityLabel() ?? "").isEmpty, "label for \(type(of: control))")
            try require(!(control.accessibilityHelp() ?? "").isEmpty, "hint for \(type(of: control))")
        }
        try require(diskPicker.accessibilityRole() == .popUpButton, "physical disk pop-up role: \(diskPicker.accessibilityRole()?.rawValue ?? "missing")")
        try require(volume.accessibilityRole() == .slider, "volume slider role: \(volume.accessibilityRole()?.rawValue ?? "missing")")
        try require(enabled.accessibilityRole() == .checkBox, "enable checkbox role: \(enabled.accessibilityRole()?.rawValue ?? "missing")")
        try require(window.makeFirstResponder(diskPicker), "initial keyboard focus")
        func key(_ key: Int, flags: NSEvent.ModifierFlags = []) {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                             keyCode: UInt16(key))!)
        }
        for expected in window.focusOrder.dropFirst() {
            key(kVK_Tab)
            try require(window.firstResponder === expected, "Tab to \(expected.accessibilityLabel() ?? "unlabelled control")")
        }
        key(kVK_Tab); try require(window.firstResponder === diskPicker, "Tab wraps")
        key(kVK_Tab, flags: .shift); try require(window.firstResponder === window.focusOrder.last, "Shift-Tab wraps")
        try require(window.makeFirstResponder(volume), "focus Volume")
        key(kVK_UpArrow)
        try require(volume.integerValue == 31 && volume.accessibilityValueDescription() == "31 percent", "spoken slider value")
        updateDisks([fixture])
        try require(window.firstResponder === volume && diskID == fixture.id, "unchanged refresh preserves focus and selection")
        let testShortcut = Shortcut(key: UInt32(kVK_F18), modifiers: UInt32(controlKey | shiftKey | cmdKey),
                                    display: "Control+Shift+Command+F18")
        try require(global.install(testShortcut), "register global shortcut")
        let contender = GlobalShortcut()
        try require(!contender.install(testShortcut), "detect shortcut conflict")
        contender.close()
        try require(global.install(nil), "unregister global shortcut")
        key(kVK_ANSI_W, flags: .command)
        try require(!window.isVisible, "Command+W closes settings")
        print("PASS: 16 control names, native roles, Tab, Shift-Tab, slider keyboard value and refresh focus")
        print("PASS: global shortcut reservation, collision and release; Command+W hides settings")
        global.close()
        exit(0)
    }
}
