import AppKit
import ApplicationServices
import ServiceManagement
import ScreenCaptureKit
import AVFoundation
import Accelerate
import AudioToolbox
import CoreGraphics

@MainActor
final class MenuBarVisualizerApp: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?
    private var audioCapture: AudioCapture?
    private var statusItem: NSStatusItem?
    private var settings: SettingsStore?
    private var settingsWindowController: SettingsWindowController?
    private var isVisualizerVisible = true
    private var didShowAccessibilityAlert = false
    private var didShowScreenRecordingAlert = false
    private var shouldResumeAudioCapture = false
    private var isSessionActive = true
    private var audioRestartTimer: Timer?
    private let accessibilityPromptKey = "didPromptAccessibility"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        self.settings = settings

        let overlay = OverlayController(barCount: settings.barCount, settings: settings)
        self.overlay = overlay

        let audioCapture = AudioCapture(
            bandCount: settings.barCount,
            threshold: Float(settings.threshold),
            smoothFrequencyEnabled: settings.smoothFrequencyEnabled,
            smoothFrequencyRadius: settings.smoothFrequencyRadius
        )
        audioCapture.onBands = { [weak overlay] bands in
            Task { @MainActor in
                overlay?.updateLevels(bands)
            }
        }
        audioCapture.onError = { [weak self] message in
            Task { @MainActor in
                self?.handleAudioCaptureError(message)
            }
        }
        self.audioCapture = audioCapture
        startAudioCaptureIfNeeded(forceAlert: true)

        settings.onChange = { [weak self] in
            guard let self, let settings = self.settings else { return }
            self.overlay?.applySettings()
            self.audioCapture?.updateSettings(
                bandCount: settings.barCount,
                threshold: Float(settings.threshold),
                smoothFrequencyEnabled: settings.smoothFrequencyEnabled,
                smoothFrequencyRadius: settings.smoothFrequencyRadius
            )
        }

        setupStatusItem()
        setupSystemObservers()
        requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCapture?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Visualizer")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Hide Visualizer", action: #selector(toggleVisualizer(_:)), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let accessibilityItem = NSMenuItem(title: "Enable Accessibility…", action: #selector(requestAccessibility(_:)), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let screenRecordingItem = NSMenuItem(title: "Enable Screen Recording…", action: #selector(requestScreenRecording(_:)), keyEquivalent: "")
        screenRecordingItem.target = self
        menu.addItem(screenRecordingItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleVisualizer(_ sender: NSMenuItem) {
        guard let overlay else { return }
        if isVisualizerVisible {
            overlay.setUserVisible(false)
            sender.title = "Show Visualizer"
        } else {
            overlay.setUserVisible(true)
            sender.title = "Hide Visualizer"
        }
        isVisualizerVisible.toggle()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let settings else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings)
        }
        settingsWindowController?.show()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        requestAccessibilityIfNeeded(forceAlert: true)
    }

    @objc private func requestScreenRecording(_ sender: NSMenuItem) {
        startAudioCaptureIfNeeded(forceAlert: true)
    }

    private func requestAccessibilityIfNeeded(forceAlert: Bool = false) {
        guard AXIsProcessTrusted() == false else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: accessibilityPromptKey) == false {
            let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            defaults.set(true, forKey: accessibilityPromptKey)
        }
        if forceAlert || didShowAccessibilityAlert == false {
            didShowAccessibilityAlert = true
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "To hide the visualizer during full screen, allow MenuBarVisualizer in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Not Now")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleAudioCaptureError(_ message: String) {
        shouldResumeAudioCapture = true
        if isScreenRecordingAuthorized() == false {
            requestScreenRecordingIfNeeded()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Audio Capture Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        scheduleAudioCaptureRetry()
    }

    private func setupSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(handleSessionDidResignActive(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleSessionDidBecomeActive(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func handleWillSleep(_ notification: Notification) {
        shouldResumeAudioCapture = true
        audioCapture?.stop()
    }

    @objc private func handleDidWake(_ notification: Notification) {
        if isSessionActive {
            resumeAudioCaptureIfNeeded()
        } else {
            shouldResumeAudioCapture = true
        }
    }

    @objc private func handleSessionDidResignActive(_ notification: Notification) {
        isSessionActive = false
        shouldResumeAudioCapture = true
        audioCapture?.stop()
    }

    @objc private func handleSessionDidBecomeActive(_ notification: Notification) {
        isSessionActive = true
        resumeAudioCaptureIfNeeded()
    }

    private func resumeAudioCaptureIfNeeded() {
        guard shouldResumeAudioCapture else { return }
        shouldResumeAudioCapture = false
        startAudioCaptureIfNeeded()
    }

    private func startAudioCaptureIfNeeded(forceAlert: Bool = false) {
        guard isSessionActive else {
            shouldResumeAudioCapture = true
            return
        }
        guard let audioCapture, audioCapture.isActive == false else { return }
        if isScreenRecordingAuthorized() {
            audioCapture.start()
        } else {
            requestScreenRecordingIfNeeded(forceAlert: forceAlert)
        }
    }

    private func requestScreenRecordingIfNeeded(forceAlert: Bool = false) {
        guard isScreenRecordingAuthorized() == false else { return }
        guard forceAlert || didShowScreenRecordingAlert == false else { return }
        didShowScreenRecordingAlert = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "To capture audio, allow MenuBarVisualizer in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func isScreenRecordingAuthorized() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    private func scheduleAudioCaptureRetry() {
        guard audioRestartTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.audioRestartTimer = nil
            self?.startAudioCaptureIfNeeded()
        }
        audioRestartTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
final class SettingsStore {
    private enum Key {
        static let barHeight = "barHeight"
        static let backgroundAlpha = "backgroundAlpha"
        static let barCount = "barCount"
        static let threshold = "threshold"
        static let barAlpha = "barAlpha"
        static let barColorRed = "barColorRed"
        static let barColorGreen = "barColorGreen"
        static let barColorBlue = "barColorBlue"
        static let reverseDirection = "reverseDirection"
        static let smoothBarHeight = "smoothBarHeight"
        static let smoothFrequencyEnabled = "smoothFrequencyEnabled"
        static let smoothFrequencyRadius = "smoothFrequencyRadius"
        static let hideWhenSilent = "hideWhenSilent"
    }

    private let defaults = UserDefaults.standard
    private var _barHeight: CGFloat
    private var _backgroundAlpha: CGFloat
    private var _barCount: Int
    private var _threshold: CGFloat
    private var _barAlpha: CGFloat
    private var _barColor: NSColor
    private var _reverseDirection: Bool
    private var _smoothBarHeight: Bool
    private var _smoothFrequencyEnabled: Bool
    private var _smoothFrequencyRadius: Int
    private var _hideWhenSilent: Bool

    var onChange: (() -> Void)?

    var barHeight: CGFloat {
        get { _barHeight }
        set {
            let clamped = clampBarHeight(newValue)
            guard clamped != _barHeight else { return }
            _barHeight = clamped
            defaults.set(Double(clamped), forKey: Key.barHeight)
            onChange?()
        }
    }

    var backgroundAlpha: CGFloat {
        get { _backgroundAlpha }
        set {
            let clamped = clampAlpha(newValue)
            guard clamped != _backgroundAlpha else { return }
            _backgroundAlpha = clamped
            defaults.set(Double(clamped), forKey: Key.backgroundAlpha)
            onChange?()
        }
    }

    var barCount: Int {
        get { _barCount }
        set {
            let clamped = clampBarCount(newValue)
            guard clamped != _barCount else { return }
            _barCount = clamped
            defaults.set(clamped, forKey: Key.barCount)
            onChange?()
        }
    }

    var threshold: CGFloat {
        get { _threshold }
        set {
            let clamped = clampThreshold(newValue)
            guard clamped != _threshold else { return }
            _threshold = clamped
            defaults.set(Double(clamped), forKey: Key.threshold)
            onChange?()
        }
    }

    var barAlpha: CGFloat {
        get { _barAlpha }
        set {
            let clamped = clampBarAlpha(newValue)
            guard clamped != _barAlpha else { return }
            _barAlpha = clamped
            defaults.set(Double(clamped), forKey: Key.barAlpha)
            onChange?()
        }
    }

    var reverseDirection: Bool {
        get { _reverseDirection }
        set {
            guard newValue != _reverseDirection else { return }
            _reverseDirection = newValue
            defaults.set(newValue, forKey: Key.reverseDirection)
            onChange?()
        }
    }

    var smoothBarHeight: Bool {
        get { _smoothBarHeight }
        set {
            guard newValue != _smoothBarHeight else { return }
            _smoothBarHeight = newValue
            defaults.set(newValue, forKey: Key.smoothBarHeight)
            onChange?()
        }
    }

    var smoothFrequencyEnabled: Bool {
        get { _smoothFrequencyEnabled }
        set {
            guard newValue != _smoothFrequencyEnabled else { return }
            _smoothFrequencyEnabled = newValue
            defaults.set(newValue, forKey: Key.smoothFrequencyEnabled)
            onChange?()
        }
    }

    var smoothFrequencyRadius: Int {
        get { _smoothFrequencyRadius }
        set {
            let clamped = Self.clampFrequencyRadius(newValue)
            guard clamped != _smoothFrequencyRadius else { return }
            _smoothFrequencyRadius = clamped
            defaults.set(clamped, forKey: Key.smoothFrequencyRadius)
            onChange?()
        }
    }

    var hideWhenSilent: Bool {
        get { _hideWhenSilent }
        set {
            guard newValue != _hideWhenSilent else { return }
            _hideWhenSilent = newValue
            defaults.set(newValue, forKey: Key.hideWhenSilent)
            onChange?()
        }
    }

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    var barColor: NSColor {
        get { _barColor }
        set {
            let normalized = normalizedColor(newValue)
            _barColor = normalized
            let (r, g, b) = rgbComponents(from: normalized)
            defaults.set(Double(r), forKey: Key.barColorRed)
            defaults.set(Double(g), forKey: Key.barColorGreen)
            defaults.set(Double(b), forKey: Key.barColorBlue)
            onChange?()
        }
    }

    static var minBarHeight: CGFloat { 4 }
    static var maxBarHeight: CGFloat { max(120, NSStatusBar.system.thickness * 2) }
    static var minBarCount: Int { 12 }
    static var maxBarCount: Int { 480 }
    static var minThreshold: CGFloat { -0.8 }
    static var maxThreshold: CGFloat { 0.5 }
    static var minBarAlpha: CGFloat { 0.0 }
    static var maxBarAlpha: CGFloat { 1.0 }
    static var minFrequencySmoothingRadius: Int { 1 }
    static var maxFrequencySmoothingRadius: Int { 8 }
    static var defaultBarColor: NSColor { NSColor(calibratedHue: 0.58, saturation: 0.85, brightness: 0.95, alpha: 1) }

    var minBarHeight: CGFloat { Self.minBarHeight }
    var maxBarHeight: CGFloat { Self.maxBarHeight }

    init() {
        let savedHeight = defaults.object(forKey: Key.barHeight) as? Double
        let savedAlpha = defaults.object(forKey: Key.backgroundAlpha) as? Double
        let savedBarCount = defaults.object(forKey: Key.barCount) as? Int
        let savedThreshold = defaults.object(forKey: Key.threshold) as? Double
        let savedBarAlpha = defaults.object(forKey: Key.barAlpha) as? Double
        let savedBarColorR = defaults.object(forKey: Key.barColorRed) as? Double
        let savedBarColorG = defaults.object(forKey: Key.barColorGreen) as? Double
        let savedBarColorB = defaults.object(forKey: Key.barColorBlue) as? Double
        let savedReverse = defaults.object(forKey: Key.reverseDirection) as? Bool
        let savedSmoothBarHeight = defaults.object(forKey: Key.smoothBarHeight) as? Bool
        let savedSmoothFrequencyEnabled = defaults.object(forKey: Key.smoothFrequencyEnabled) as? Bool
        let savedSmoothFrequencyRadius = defaults.object(forKey: Key.smoothFrequencyRadius) as? Int
        let savedHideWhenSilent = defaults.object(forKey: Key.hideWhenSilent) as? Bool
        let defaultHeight: CGFloat = 30
        let defaultAlpha: CGFloat = 0.0
        let defaultBarCount = 160
        let defaultThreshold: CGFloat = -0.33
        let defaultBarAlpha: CGFloat = 0.2
        let defaultSmoothBarHeight = true
        let defaultSmoothFrequencyEnabled = true
        let defaultSmoothFrequencyRadius = 2
        let defaultHideWhenSilent = false

        let minValue = Self.minBarHeight
        let maxValue = Self.maxBarHeight
        let heightValue = CGFloat(savedHeight ?? Double(defaultHeight))
        _barHeight = min(max(heightValue, minValue), maxValue)

        let alphaValue = CGFloat(savedAlpha ?? Double(defaultAlpha))
        _backgroundAlpha = min(max(alphaValue, 0), 1)

        let minCount = Self.minBarCount
        let maxCount = Self.maxBarCount
        let countValue = savedBarCount ?? defaultBarCount
        _barCount = min(max(countValue, minCount), maxCount)

        let minThreshold = Self.minThreshold
        let maxThreshold = Self.maxThreshold
        let thresholdValue = CGFloat(savedThreshold ?? Double(defaultThreshold))
        _threshold = min(max(thresholdValue, minThreshold), maxThreshold)

        let minBarAlpha = Self.minBarAlpha
        let maxBarAlpha = Self.maxBarAlpha
        let barAlphaValue = CGFloat(savedBarAlpha ?? Double(defaultBarAlpha))
        _barAlpha = min(max(barAlphaValue, minBarAlpha), maxBarAlpha)

        if let r = savedBarColorR, let g = savedBarColorG, let b = savedBarColorB {
            _barColor = NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        } else {
            _barColor = Self.defaultBarColor
        }

        _reverseDirection = savedReverse ?? false
        _smoothBarHeight = savedSmoothBarHeight ?? defaultSmoothBarHeight
        _smoothFrequencyEnabled = savedSmoothFrequencyEnabled ?? defaultSmoothFrequencyEnabled
        _smoothFrequencyRadius = Self.clampFrequencyRadius(savedSmoothFrequencyRadius ?? defaultSmoothFrequencyRadius)
        _hideWhenSilent = savedHideWhenSilent ?? defaultHideWhenSilent
    }

    private func clampBarHeight(_ value: CGFloat) -> CGFloat {
        let minValue = minBarHeight
        let maxValue = maxBarHeight
        return min(max(value, minValue), maxValue)
    }

    private func clampAlpha(_ value: CGFloat) -> CGFloat {
        return min(max(value, 0), 1)
    }

    private static func clampFrequencyRadius(_ value: Int) -> Int {
        let minValue = Self.minFrequencySmoothingRadius
        let maxValue = Self.maxFrequencySmoothingRadius
        return min(max(value, minValue), maxValue)
    }

    private func clampBarCount(_ value: Int) -> Int {
        return min(max(value, Self.minBarCount), Self.maxBarCount)
    }

    private func clampThreshold(_ value: CGFloat) -> CGFloat {
        return min(max(value, Self.minThreshold), Self.maxThreshold)
    }

    private func clampBarAlpha(_ value: CGFloat) -> CGFloat {
        return min(max(value, Self.minBarAlpha), Self.maxBarAlpha)
    }

    private func normalizedColor(_ color: NSColor) -> NSColor {
        if let rgb = color.usingColorSpace(.deviceRGB) {
            return rgb
        }
        return Self.defaultBarColor
    }

    private func rgbComponents(from color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = normalizedColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }
}

@MainActor
final class OverlayController: NSObject {
    private var window: NSWindow
    private let visualizerView: VisualizerView
    private let settings: SettingsStore
    private var userVisible = true
    private var fullscreenHidden = false
    private var silenceHidden = false
    private var lastNonSilentTime = CFAbsoluteTimeGetCurrent()
    private let silenceThreshold: Float = 0.02
    private let silenceHold: CFTimeInterval = 1.2

    init(barCount: Int, settings: SettingsStore) {
        self.settings = settings
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = OverlayController.frame(for: screen, barHeight: settings.barHeight)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        self.window = window
        let view = VisualizerView(
            barCount: barCount,
            backgroundAlpha: settings.backgroundAlpha,
            barAlpha: settings.barAlpha,
            barColor: settings.barColor,
            reverseDirection: settings.reverseDirection,
            smoothBarHeight: settings.smoothBarHeight
        )
        view.autoresizingMask = [.width, .height]
        self.visualizerView = view

        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        view.frame = window.contentLayoutRect
        refreshVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        evaluateFullscreen()
        startVisibilityTimer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func updateLevels(_ levels: [Float]) {
        visualizerView.updateLevels(levels)
        evaluateSilence(with: levels)
    }

    func applySettings() {
        visualizerView.updateAppearance(
            backgroundAlpha: settings.backgroundAlpha,
            barAlpha: settings.barAlpha,
            barColor: settings.barColor,
            reverseDirection: settings.reverseDirection,
            smoothBarHeight: settings.smoothBarHeight
        )
        visualizerView.updateBarCount(settings.barCount)
        reposition()
    }

    func setUserVisible(_ visible: Bool) {
        userVisible = visible
        refreshVisibility()
    }

    private func setFullscreenHidden(_ hidden: Bool) {
        fullscreenHidden = hidden
        refreshVisibility()
    }

    private func setSilenceHidden(_ hidden: Bool) {
        guard hidden != silenceHidden else { return }
        silenceHidden = hidden
        refreshVisibility()
    }

    private func refreshVisibility() {
        if userVisible && !fullscreenHidden && !silenceHidden {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    @objc private func handleScreenChange(_ notification: Notification) {
        reposition()
        evaluateFullscreen()
    }

    @objc private func handleActiveSpaceChanged(_ notification: Notification) {
        evaluateFullscreen()
    }

    private func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = OverlayController.frame(for: screen, barHeight: settings.barHeight)
        window.setFrame(frame, display: true)
        visualizerView.needsDisplay = true
    }

    private func evaluateSilence(with levels: [Float]) {
        guard settings.hideWhenSilent else {
            lastNonSilentTime = CFAbsoluteTimeGetCurrent()
            setSilenceHidden(false)
            return
        }
        let maxLevel = levels.max() ?? 0
        let now = CFAbsoluteTimeGetCurrent()
        if maxLevel > silenceThreshold {
            lastNonSilentTime = now
            setSilenceHidden(false)
            return
        }
        if now - lastNonSilentTime >= silenceHold {
            setSilenceHidden(true)
        }
    }

    private func evaluateFullscreen() {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let hidden = OverlayController.isMenuBarHidden(on: screen)
        setFullscreenHidden(hidden)
    }

    private func startVisibilityTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateFullscreen()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func frame(for screen: NSScreen?, barHeight: CGFloat) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: 400, height: barHeight)
        }
        let clampedHeight = min(max(barHeight, SettingsStore.minBarHeight), SettingsStore.maxBarHeight)
        let fullFrame = screen.frame
        let x = fullFrame.minX
        let y = fullFrame.maxY - clampedHeight
        return NSRect(x: x, y: y, width: fullFrame.width, height: clampedHeight)
    }

    private static func isMenuBarHidden(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        if let fullscreen = isFrontmostAppFullscreen(on: screen), fullscreen {
            return true
        }
        if NSMenu.menuBarVisible() == false {
            return true
        }
        if let visible = isMenuBarWindowVisible(on: screen) {
            return !visible
        }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let diff = frame.maxY - visible.maxY
        let threshold = NSStatusBar.system.thickness * 0.5
        return diff < threshold
    }

    private static func isFrontmostAppFullscreen(on screen: NSScreen) -> Bool? {
        if let axFullscreen = isFrontmostAppFullscreenViaAX() {
            return axFullscreen
        }
        return isFrontmostAppFullscreenByWindowBounds(on: screen)
    }

    private static func isFrontmostAppFullscreenViaAX() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(frontmostPid)
        var windowValue: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        if result != .success || windowValue == nil {
            result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue)
        }
        guard result == .success, let windowValue else { return nil }
        guard CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let windowElement = unsafeDowncast(windowValue, to: AXUIElement.self)
        for attribute in ["AXFullScreen", "AXFullscreen"] {
            var fullscreenValue: CFTypeRef?
            let attrResult = AXUIElementCopyAttributeValue(windowElement, attribute as CFString, &fullscreenValue)
            guard attrResult == .success, let value = fullscreenValue else {
                continue
            }
            if let boolValue = value as? Bool {
                return boolValue
            }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
            }
        }
        return nil
    }

    private static func isFrontmostAppFullscreenByWindowBounds(on screen: NSScreen) -> Bool? {
        guard let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let tolerance: CGFloat = 3
        var sawFrontmostWindow = false

        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == frontmostPid else {
                continue
            }
            sawFrontmostWindow = true
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            for candidate in candidateBounds(from: bounds, scale: scale, referenceWidth: screenFrame.width) {
                if abs(candidate.width - screenFrame.width) > tolerance { continue }
                if abs(candidate.height - screenFrame.height) > tolerance { continue }
                if abs(candidate.minX - screenFrame.minX) > tolerance { continue }
                if abs(candidate.minY - screenFrame.minY) > tolerance { continue }
                return true
            }
        }
        return sawFrontmostWindow ? false : nil
    }

    private static func isMenuBarWindowVisible(on screen: NSScreen) -> Bool? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let screenFrame = screen.frame
        let menuBarHeight = NSStatusBar.system.thickness
        let topBand = CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - menuBarHeight - 8,
            width: screenFrame.width,
            height: menuBarHeight + 16
        )
        let minWidth = screenFrame.width * 0.6
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let scale = screen.backingScaleFactor
        var sawCandidate = false

        for info in infoList {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                if pid == currentPid { continue }
                if let frontmostPid, pid == frontmostPid { continue }
            }
            if let owner = info[kCGWindowOwnerName as String] as? String {
                let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalizedOwner.isEmpty == false {
                    let isSystemOwner = normalizedOwner == "window server"
                        || normalizedOwner == "windowserver"
                        || normalizedOwner == "systemuiserver"
                    if isSystemOwner == false {
                        continue
                    }
                }
            }
            let isOnscreen: Bool = {
                if let onscreen = info[kCGWindowIsOnscreen as String] as? Bool {
                    return onscreen
                }
                if let onscreenNumber = info[kCGWindowIsOnscreen as String] as? NSNumber {
                    return onscreenNumber.boolValue
                }
                return true
            }()
            let alphaValue: Double = {
                if let alpha = info[kCGWindowAlpha as String] as? Double {
                    return alpha
                }
                if let alphaNumber = info[kCGWindowAlpha as String] as? NSNumber {
                    return alphaNumber.doubleValue
                }
                return 1.0
            }()
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            for candidate in candidateBounds(from: bounds, scale: scale, referenceWidth: screenFrame.width) {
                if candidate.width < minWidth { continue }
                if candidate.height > menuBarHeight * 2.5 { continue }
                if candidate.intersects(topBand) == false { continue }
                if abs(candidate.maxY - screenFrame.maxY) > menuBarHeight { continue }
                sawCandidate = true
                if isOnscreen && alphaValue > 0.05 {
                    return true
                }
                break
            }
        }
        return sawCandidate ? false : nil
    }

    private static func candidateBounds(from bounds: CGRect, scale: CGFloat, referenceWidth: CGFloat) -> [CGRect] {
        guard scale != 1 else { return [bounds] }
        let scaled = CGRect(
            x: bounds.origin.x / scale,
            y: bounds.origin.y / scale,
            width: bounds.size.width / scale,
            height: bounds.size.height / scale
        )
        let rawDistance = abs(bounds.width - referenceWidth)
        let scaledDistance = abs(scaled.width - referenceWidth)
        if scaledDistance < rawDistance {
            return [scaled, bounds]
        }
        return [bounds, scaled]
    }
}

@MainActor
final class VisualizerView: NSView {
    private var barCount: Int
    private var levels: [CGFloat]
    private var smoothed: [CGFloat]
    private var backgroundAlpha: CGFloat
    private var barAlpha: CGFloat
    private var barColor: NSColor
    private var reverseDirection: Bool
    private var smoothBarHeight: Bool

    init(barCount: Int, backgroundAlpha: CGFloat, barAlpha: CGFloat, barColor: NSColor, reverseDirection: Bool, smoothBarHeight: Bool) {
        self.barCount = barCount
        self.levels = Array(repeating: 0, count: barCount)
        self.smoothed = Array(repeating: 0, count: barCount)
        self.backgroundAlpha = backgroundAlpha
        self.barAlpha = barAlpha
        self.barColor = barColor
        self.reverseDirection = reverseDirection
        self.smoothBarHeight = smoothBarHeight
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func updateLevels(_ newLevels: [Float]) {
        guard !newLevels.isEmpty else { return }
        if newLevels.count != barCount {
            levels = Array(repeating: 0, count: barCount)
            smoothed = Array(repeating: 0, count: barCount)
        }

        let sampleCount = min(barCount, newLevels.count)
        for index in 0..<barCount {
            let source = index < sampleCount ? newLevels[index] : 0
            let target = CGFloat(max(0, min(1, source)))
            levels[index] = target
            if smoothBarHeight {
                let current = smoothed[index]
                let attack: CGFloat = 0.6
                let decay: CGFloat = 0.88
                if target > current {
                    smoothed[index] = current + (target - current) * attack
                } else {
                    smoothed[index] = current * decay
                }
            } else {
                smoothed[index] = target
            }
        }
        needsDisplay = true
    }

    func updateAppearance(backgroundAlpha: CGFloat, barAlpha: CGFloat, barColor: NSColor, reverseDirection: Bool, smoothBarHeight: Bool) {
        self.backgroundAlpha = backgroundAlpha
        self.barAlpha = barAlpha
        self.barColor = barColor
        self.reverseDirection = reverseDirection
        if self.smoothBarHeight != smoothBarHeight {
            self.smoothBarHeight = smoothBarHeight
            smoothed = levels
        }
        needsDisplay = true
    }

    func updateBarCount(_ newValue: Int) {
        guard newValue != barCount else { return }
        barCount = newValue
        levels = Array(repeating: 0, count: barCount)
        smoothed = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(bounds)

        let background = NSColor(calibratedWhite: 0.1, alpha: backgroundAlpha)
        context.setFillColor(background.cgColor)
        context.fill(bounds)

        let gap: CGFloat = 2
        let width = bounds.width
        let height = bounds.height
        let barWidth = max(1, (width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))
        let verticalInset = max(1, height * 0.15)
        let maxHeight = max(2, height - verticalInset * 2)

        for index in 0..<barCount {
            let level = smoothed[index]
            let barHeight = max(2, maxHeight * level)
            let x = bounds.minX + CGFloat(index) * (barWidth + gap)
            let y: CGFloat
            if reverseDirection {
                y = bounds.maxY - verticalInset - barHeight
            } else {
                y = bounds.minY + verticalInset
            }
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            let base = barColor.usingColorSpace(.deviceRGB) ?? barColor
            let color = base.withAlphaComponent(barAlpha)

            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            context.setFillColor(color.cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let heightSlider: NSSlider
    private let heightValueLabel: NSTextField
    private let opacitySlider: NSSlider
    private let opacityValueLabel: NSTextField
    private let barCountSlider: NSSlider
    private let barCountValueLabel: NSTextField
    private let thresholdSlider: NSSlider
    private let thresholdValueLabel: NSTextField
    private let barOpacitySlider: NSSlider
    private let barOpacityValueLabel: NSTextField
    private let barColorWell: NSColorWell
    private let barColorValueLabel: NSTextField
    private let reverseDirectionButton: NSButton
    private let smoothBarHeightButton: NSButton
    private let launchAtLoginButton: NSButton
    private let hideWhenSilentButton: NSButton
    private let showAdvancedButton: NSButton
    private let smoothFrequencyButton: NSButton
    private let smoothFrequencySlider: NSSlider
    private let smoothFrequencyValueLabel: NSTextField
    private let advancedStack: NSStackView
    private let mainStack: NSStackView

    init(settings: SettingsStore) {
        self.settings = settings

        let heightSlider = NSSlider(value: Double(settings.barHeight), minValue: Double(settings.minBarHeight), maxValue: Double(settings.maxBarHeight), target: nil, action: nil)
        heightSlider.isContinuous = true
        self.heightSlider = heightSlider
        self.heightValueLabel = NSTextField(labelWithString: "")

        let opacitySlider = NSSlider(value: Double(settings.backgroundAlpha), minValue: 0, maxValue: 1, target: nil, action: nil)
        opacitySlider.isContinuous = true
        self.opacitySlider = opacitySlider
        self.opacityValueLabel = NSTextField(labelWithString: "")

        let barOpacitySlider = NSSlider(value: Double(settings.barAlpha), minValue: Double(SettingsStore.minBarAlpha), maxValue: Double(SettingsStore.maxBarAlpha), target: nil, action: nil)
        barOpacitySlider.isContinuous = true
        self.barOpacitySlider = barOpacitySlider
        self.barOpacityValueLabel = NSTextField(labelWithString: "")

        let barColorWell = NSColorWell()
        barColorWell.color = settings.barColor
        barColorWell.isBordered = true
        barColorWell.isContinuous = true
        self.barColorWell = barColorWell
        self.barColorValueLabel = NSTextField(labelWithString: "")

        let reverseButton = NSButton(checkboxWithTitle: "Reverse Direction (Top -> Down)", target: nil, action: nil)
        reverseButton.state = settings.reverseDirection ? .on : .off
        self.reverseDirectionButton = reverseButton

        let smoothButton = NSButton(checkboxWithTitle: "Smooth Bar Height", target: nil, action: nil)
        smoothButton.state = settings.smoothBarHeight ? .on : .off
        self.smoothBarHeightButton = smoothButton

        let launchButton = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
        launchButton.state = settings.launchAtLoginEnabled ? .on : .off
        self.launchAtLoginButton = launchButton

        let hideWhenSilentButton = NSButton(checkboxWithTitle: "Hide When Silent", target: nil, action: nil)
        hideWhenSilentButton.state = settings.hideWhenSilent ? .on : .off
        self.hideWhenSilentButton = hideWhenSilentButton

        let showAdvancedButton = NSButton(checkboxWithTitle: "Show Advanced Settings", target: nil, action: nil)
        showAdvancedButton.state = .off
        self.showAdvancedButton = showAdvancedButton

        let smoothFrequencyButton = NSButton(checkboxWithTitle: "Enable Frequency Smoothing", target: nil, action: nil)
        smoothFrequencyButton.state = settings.smoothFrequencyEnabled ? .on : .off
        self.smoothFrequencyButton = smoothFrequencyButton

        let smoothFrequencySlider = NSSlider(
            value: Double(settings.smoothFrequencyRadius),
            minValue: Double(SettingsStore.minFrequencySmoothingRadius),
            maxValue: Double(SettingsStore.maxFrequencySmoothingRadius),
            target: nil,
            action: nil
        )
        smoothFrequencySlider.isContinuous = true
        self.smoothFrequencySlider = smoothFrequencySlider
        self.smoothFrequencyValueLabel = NSTextField(labelWithString: "")

        let advancedStack = NSStackView()
        advancedStack.orientation = .vertical
        advancedStack.spacing = 6
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        self.advancedStack = advancedStack

        let barCountSlider = NSSlider(value: Double(settings.barCount), minValue: Double(SettingsStore.minBarCount), maxValue: Double(SettingsStore.maxBarCount), target: nil, action: nil)
        barCountSlider.isContinuous = true
        self.barCountSlider = barCountSlider
        self.barCountValueLabel = NSTextField(labelWithString: "")

        let thresholdSlider = NSSlider(value: Double(settings.threshold), minValue: Double(SettingsStore.minThreshold), maxValue: Double(SettingsStore.maxThreshold), target: nil, action: nil)
        thresholdSlider.isContinuous = true
        self.thresholdSlider = thresholdSlider
        self.thresholdValueLabel = NSTextField(labelWithString: "")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Visualizer Settings"
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        self.mainStack = stack

        super.init(window: window)

        heightSlider.target = self
        heightSlider.action = #selector(heightChanged(_:))
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        barOpacitySlider.target = self
        barOpacitySlider.action = #selector(barOpacityChanged(_:))
        barColorWell.target = self
        barColorWell.action = #selector(barColorChanged(_:))
        reverseButton.target = self
        reverseButton.action = #selector(reverseDirectionChanged(_:))
        smoothButton.target = self
        smoothButton.action = #selector(smoothBarHeightChanged(_:))
        launchButton.target = self
        launchButton.action = #selector(launchAtLoginChanged(_:))
        hideWhenSilentButton.target = self
        hideWhenSilentButton.action = #selector(hideWhenSilentChanged(_:))
        showAdvancedButton.target = self
        showAdvancedButton.action = #selector(showAdvancedChanged(_:))
        smoothFrequencyButton.target = self
        smoothFrequencyButton.action = #selector(smoothFrequencyChanged(_:))
        smoothFrequencySlider.target = self
        smoothFrequencySlider.action = #selector(smoothFrequencyRadiusChanged(_:))
        barCountSlider.target = self
        barCountSlider.action = #selector(barCountChanged(_:))
        thresholdSlider.target = self
        thresholdSlider.action = #selector(thresholdChanged(_:))

        applyUIStyles()
        configureContent()
        refreshLabels()
        updateAdvancedVisibility()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show() {
        guard let window else { return }
        launchAtLoginButton.state = settings.launchAtLoginEnabled ? .on : .off
        hideWhenSilentButton.state = settings.hideWhenSilent ? .on : .off
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        mainStack.addArrangedSubview(sectionLabel("Bar Height"))
        mainStack.addArrangedSubview(heightSlider)
        mainStack.addArrangedSubview(heightValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Bar Count"))
        mainStack.addArrangedSubview(barCountSlider)
        mainStack.addArrangedSubview(barCountValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Smoothing"))
        mainStack.addArrangedSubview(smoothBarHeightButton)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Visibility"))
        mainStack.addArrangedSubview(hideWhenSilentButton)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Background Opacity"))
        mainStack.addArrangedSubview(opacitySlider)
        mainStack.addArrangedSubview(opacityValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Bar Opacity"))
        mainStack.addArrangedSubview(barOpacitySlider)
        mainStack.addArrangedSubview(barOpacityValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Bar Color"))
        mainStack.addArrangedSubview(barColorWell)
        mainStack.addArrangedSubview(barColorValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(reverseDirectionButton)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Startup"))
        mainStack.addArrangedSubview(launchAtLoginButton)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Threshold"))
        mainStack.addArrangedSubview(thresholdSlider)
        mainStack.addArrangedSubview(thresholdValueLabel)
        mainStack.addArrangedSubview(sectionSeparator())
        mainStack.addArrangedSubview(sectionLabel("Advanced Settings"))
        mainStack.addArrangedSubview(showAdvancedButton)
        mainStack.addArrangedSubview(advancedStack)

        advancedStack.addArrangedSubview(sectionLabel("Frequency Smoothing"))
        advancedStack.addArrangedSubview(smoothFrequencyButton)
        advancedStack.addArrangedSubview(smoothFrequencySlider)
        advancedStack.addArrangedSubview(smoothFrequencyValueLabel)

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
    }

    private func applyUIStyles() {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueLabels = [
            heightValueLabel,
            opacityValueLabel,
            barCountValueLabel,
            barOpacityValueLabel,
            barColorValueLabel,
            thresholdValueLabel,
            smoothFrequencyValueLabel
        ]
        for label in valueLabels {
            label.font = valueFont
            label.textColor = .secondaryLabelColor
            label.alignment = .right
        }

        let sliders = [
            heightSlider,
            opacitySlider,
            barOpacitySlider,
            barCountSlider,
            thresholdSlider,
            smoothFrequencySlider
        ]
        for slider in sliders {
            slider.controlSize = .small
            slider.cell?.controlSize = .small
        }

        let buttons = [
            reverseDirectionButton,
            smoothBarHeightButton,
            launchAtLoginButton,
            hideWhenSilentButton,
            showAdvancedButton,
            smoothFrequencyButton
        ]
        for button in buttons {
            button.controlSize = .small
            button.cell?.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 12)
        }
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func sectionSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func refreshLabels() {
        heightValueLabel.stringValue = String(format: "%.0f px", settings.barHeight)
        opacityValueLabel.stringValue = String(format: "%.0f %%", settings.backgroundAlpha * 100)
        barCountValueLabel.stringValue = "\(settings.barCount) bars"
        barOpacityValueLabel.stringValue = String(format: "%.0f %%", settings.barAlpha * 100)
        barColorValueLabel.stringValue = hexString(for: settings.barColor)
        thresholdValueLabel.stringValue = String(format: "%+.0f %%", settings.threshold * 100)
        if settings.smoothFrequencyEnabled {
            smoothFrequencyValueLabel.stringValue = "\(settings.smoothFrequencyRadius) bands"
        } else {
            smoothFrequencyValueLabel.stringValue = "Off"
        }
    }

    @objc private func heightChanged(_ sender: NSSlider) {
        settings.barHeight = CGFloat(sender.doubleValue)
        refreshLabels()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.backgroundAlpha = CGFloat(sender.doubleValue)
        refreshLabels()
    }

    @objc private func barOpacityChanged(_ sender: NSSlider) {
        settings.barAlpha = CGFloat(sender.doubleValue)
        refreshLabels()
    }

    @objc private func barColorChanged(_ sender: NSColorWell) {
        settings.barColor = sender.color
        refreshLabels()
    }

    @objc private func reverseDirectionChanged(_ sender: NSButton) {
        settings.reverseDirection = (sender.state == .on)
        refreshLabels()
    }

    @objc private func smoothBarHeightChanged(_ sender: NSButton) {
        settings.smoothBarHeight = (sender.state == .on)
    }

    @objc private func hideWhenSilentChanged(_ sender: NSButton) {
        settings.hideWhenSilent = (sender.state == .on)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try settings.setLaunchAtLoginEnabled(enabled)
        } catch {
            sender.state = settings.launchAtLoginEnabled ? .on : .off
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Failed to update Login Item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func showAdvancedChanged(_ sender: NSButton) {
        updateAdvancedVisibility()
    }

    @objc private func smoothFrequencyChanged(_ sender: NSButton) {
        settings.smoothFrequencyEnabled = (sender.state == .on)
        smoothFrequencySlider.isEnabled = settings.smoothFrequencyEnabled
        refreshLabels()
    }

    @objc private func smoothFrequencyRadiusChanged(_ sender: NSSlider) {
        let rounded = Int(sender.doubleValue.rounded())
        sender.doubleValue = Double(rounded)
        settings.smoothFrequencyRadius = rounded
        refreshLabels()
    }

    @objc private func barCountChanged(_ sender: NSSlider) {
        let rounded = Int(sender.doubleValue.rounded())
        sender.doubleValue = Double(rounded)
        settings.barCount = rounded
        refreshLabels()
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        settings.threshold = CGFloat(sender.doubleValue)
        refreshLabels()
    }

    private func hexString(for color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func updateAdvancedVisibility() {
        advancedStack.isHidden = (showAdvancedButton.state == .off)
        smoothFrequencySlider.isEnabled = settings.smoothFrequencyEnabled
        resizeWindowToFit()
    }

    private func resizeWindowToFit() {
        guard let window, let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let targetHeight = max(360, fitting.height)
        let currentHeight = window.contentLayoutRect.height
        let delta = targetHeight - currentHeight
        if abs(delta) < 1 { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
    }
}

final class AudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private var bandCount: Int
    private var threshold: Float
    private var smoothFrequencyEnabled: Bool
    private var smoothFrequencyRadius: Int
    private let queue = DispatchQueue(label: "menubar.visualizer.audio")
    private var stream: SCStream?
    private var isStarting = false
    private var startGeneration = 0
    private var analyzer: SpectrumAnalyzer?
    var onBands: (([Float]) -> Void)?
    var onError: ((String) -> Void)?
    var isActive: Bool {
        return isStarting || stream != nil
    }

    init(bandCount: Int, threshold: Float, smoothFrequencyEnabled: Bool, smoothFrequencyRadius: Int) {
        self.bandCount = bandCount
        self.threshold = threshold
        self.smoothFrequencyEnabled = smoothFrequencyEnabled
        self.smoothFrequencyRadius = smoothFrequencyRadius
        super.init()
    }

    func start() {
        guard isStarting == false, stream == nil else { return }
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { self.isStarting = false }
            do {
                let stream = try await self.startCapture()
                guard generation == self.startGeneration else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
            } catch {
                guard generation == self.startGeneration else { return }
                self.stream = nil
                let message = "ScreenCaptureKitの起動に失敗しました。\nSystem Settings > Privacy & Security > Screen Recording で実行元アプリを許可してください。\n詳細: \(error.localizedDescription)"
                self.onError?(message)
            }
        }
    }

    func stop() {
        startGeneration += 1
        isStarting = false
        let current = stream
        stream = nil
        analyzer = nil
        Task { [weak current] in
            try? await current?.stopCapture()
        }
    }

    private func startCapture() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MenuBarVisualizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        return stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let asbd = asbdPtr.pointee
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        if frameCount == 0 { return }

        let sampleRate = Float(asbd.mSampleRate)
        if analyzer == nil {
            let analyzer = SpectrumAnalyzer(
                bandCount: bandCount,
                fftSize: 2048,
                sampleRate: sampleRate,
                threshold: threshold,
                smoothFrequencyEnabled: smoothFrequencyEnabled,
                smoothFrequencyRadius: smoothFrequencyRadius
            )
            analyzer.onBands = { [weak self] bands in
                self?.onBands?(bands)
            }
            self.analyzer = analyzer
        }

        guard let samples = extractMonoSamples(sampleBuffer: sampleBuffer, asbd: asbd, frameCount: frameCount) else {
            return
        }
        analyzer?.consume(samples)
    }

    func updateSettings(
        bandCount: Int,
        threshold: Float,
        smoothFrequencyEnabled: Bool,
        smoothFrequencyRadius: Int
    ) {
        if bandCount != self.bandCount {
            self.bandCount = bandCount
            analyzer = nil
        }
        if threshold != self.threshold {
            self.threshold = threshold
            analyzer?.threshold = threshold
        }
        if smoothFrequencyEnabled != self.smoothFrequencyEnabled {
            self.smoothFrequencyEnabled = smoothFrequencyEnabled
            analyzer?.frequencySmoothingEnabled = smoothFrequencyEnabled
        }
        if smoothFrequencyRadius != self.smoothFrequencyRadius {
            self.smoothFrequencyRadius = smoothFrequencyRadius
            analyzer?.frequencySmoothingRadius = smoothFrequencyRadius
        }
    }

    private func extractMonoSamples(sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription, frameCount: Int) -> [Float]? {
        let channelCount = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let bufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * max(0, channelCount - 1)
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferList.pointee.mNumberBuffers = 0

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        if status != noErr {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let bufferCount = buffers.count
        if bufferCount == 0 { return nil }

        var mono = [Float](repeating: 0, count: frameCount)

        if isFloat {
            if !isNonInterleaved, let data = buffers[0].mData {
                let ptr = data.bindMemory(to: Float.self, capacity: frameCount * channelCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += ptr[frame * channelCount + channel]
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            } else {
                for channel in 0..<bufferCount {
                    guard let data = buffers[channel].mData else { continue }
                    let ptr = data.bindMemory(to: Float.self, capacity: frameCount)
                    for frame in 0..<frameCount {
                        mono[frame] += ptr[frame]
                    }
                }
                let inv = 1.0 / Float(max(1, bufferCount))
                vDSP_vsmul(mono, 1, [inv], &mono, 1, vDSP_Length(frameCount))
            }
        } else {
            let scale = 1.0 / Float(Int16.max)
            if !isNonInterleaved, let data = buffers[0].mData {
                let ptr = data.bindMemory(to: Int16.self, capacity: frameCount * channelCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += Float(ptr[frame * channelCount + channel]) * scale
                    }
                    mono[frame] = sum / Float(channelCount)
                }
            } else {
                for channel in 0..<bufferCount {
                    guard let data = buffers[channel].mData else { continue }
                    let ptr = data.bindMemory(to: Int16.self, capacity: frameCount)
                    for frame in 0..<frameCount {
                        mono[frame] += Float(ptr[frame]) * scale
                    }
                }
                let inv = 1.0 / Float(max(1, bufferCount))
                vDSP_vsmul(mono, 1, [inv], &mono, 1, vDSP_Length(frameCount))
            }
        }

        return mono
    }
}

final class SpectrumAnalyzer {
    private let bandCount: Int
    private let fftSize: Int
    private let hopSize: Int
    private let sampleRate: Float
    private let window: [Float]
    private let fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    var threshold: Float
    var frequencySmoothingEnabled: Bool
    var frequencySmoothingRadius: Int

    private var pending: [Float] = []
    private var pendingIndex: Int = 0

    var onBands: (([Float]) -> Void)?

    init(
        bandCount: Int,
        fftSize: Int,
        sampleRate: Float,
        threshold: Float,
        smoothFrequencyEnabled: Bool,
        smoothFrequencyRadius: Int
    ) {
        self.bandCount = bandCount
        self.fftSize = fftSize
        self.hopSize = fftSize / 2
        self.sampleRate = sampleRate
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        self.threshold = threshold
        self.frequencySmoothingEnabled = smoothFrequencyEnabled
        self.frequencySmoothingRadius = smoothFrequencyRadius
        let computedLog2 = vDSP_Length(round(log2(Float(fftSize))))
        self.log2n = computedLog2
        let isPowerOfTwo = (1 << Int(computedLog2)) == fftSize
        self.fftSetup = isPowerOfTwo ? vDSP_create_fftsetup(computedLog2, FFTRadix(kFFTRadix2)) : nil
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func consume(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        pending.append(contentsOf: samples)

        while pending.count - pendingIndex >= fftSize {
            let start = pendingIndex
            let end = pendingIndex + fftSize
            let frame = Array(pending[start..<end])
            pendingIndex += hopSize
            if pendingIndex > fftSize * 4 {
                pending.removeFirst(pendingIndex)
                pendingIndex = 0
            }

            let bands = analyze(frame)
            if !bands.isEmpty {
                onBands?(bands)
            }
        }
    }

    private func analyze(_ frame: [Float]) -> [Float] {
        guard let fftSetup else {
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            let level = min(max(rms * 10, 0), 1)
            return Array(repeating: level, count: bandCount)
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = windowed
        var imag = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { magPtr in
                    guard let magBase = magPtr.baseAddress else { return }
                    vDSP_zvabs(&split, 1, magBase, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        return bandLevels(from: magnitudes)
    }

    private func bandLevels(from magnitudes: [Float]) -> [Float] {
        let binCount = magnitudes.count
        let nyquist = sampleRate / 2
        let minFreq: Float = 40
        let maxFreq: Float = min(16_000, nyquist)
        let range = maxFreq / minFreq

        var bands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let low = minFreq * powf(range, Float(band) / Float(bandCount))
            let high = minFreq * powf(range, Float(band + 1) / Float(bandCount))
            let lowBin = max(0, Int(low / nyquist * Float(binCount)))
            let highBin = min(binCount - 1, Int(high / nyquist * Float(binCount)))
            if highBin <= lowBin { continue }

            var sum: Float = 0
            for i in lowBin..<highBin {
                sum += magnitudes[i]
            }
            let avg = sum / Float(highBin - lowBin)
            let db = 20 * log10f(avg + 1e-6)
            let normalized = min(max((db + 60) / 60, 0), 1)
            let sensitivityScale: Float = threshold < 0 ? max(0, 1 + threshold) : 1
            let adjusted = normalized * sensitivityScale
            let gate = max(0, threshold)
            let gated: Float
            if gate <= 0 {
                gated = adjusted
            } else if adjusted <= gate {
                gated = 0
            } else {
                gated = (adjusted - gate) / (1 - gate)
            }
            bands[band] = powf(gated, 0.7)
        }
        if frequencySmoothingEnabled {
            return smoothBands(bands, radius: frequencySmoothingRadius)
        }
        return bands
    }

    private func smoothBands(_ bands: [Float], radius: Int) -> [Float] {
        guard bands.count > 1 else { return bands }
        let clampedRadius = min(max(1, radius), bands.count - 1)
        var output = bands
        for index in 0..<bands.count {
            let start = max(0, index - clampedRadius)
            let end = min(bands.count - 1, index + clampedRadius)
            var sum: Float = 0
            var weight: Float = 0
            for j in start...end {
                let distance = abs(j - index)
                let w = Float(clampedRadius - distance + 1)
                sum += bands[j] * w
                weight += w
            }
            output[index] = weight > 0 ? sum / weight : bands[index]
        }
        return output
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
