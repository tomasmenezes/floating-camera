// FloatingCamera.swift
// Floating Camera — macOS floating camera overlay
//
// Copyright (c) 2026 Tomás Menezes @tomasmenezes
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import AVFoundation
import CoreMedia
import Carbon.HIToolbox

// MARK: - Persistence

private enum Pref {
    static let frameX         = "cam.frameX"
    static let frameY         = "cam.frameY"
    static let frameW         = "cam.frameW"
    static let frameH         = "cam.frameH"
    static let cornerRadius   = "cam.cornerRadius"
    static let opacity        = "cam.opacity"
    static let isMirrored     = "cam.isMirrored"
    static let isAspectLocked      = "cam.isAspectLocked"
    static let hoverOpacityEnabled  = "cam.hoverOpacityEnabled"
    static let hoverOpacity         = "cam.hoverOpacity"
    static let panelVisible         = "cam.panelVisible"
    // Hotkey prefs — stored as [keyCode: UInt32, modifiers: UInt32]
    static let cameraHotkeyCode = "cam.hotkey.camera.code"
    static let cameraHotkeyMods = "cam.hotkey.camera.mods"
    static let panelHotkeyCode  = "cam.hotkey.panel.code"
    static let panelHotkeyMods  = "cam.hotkey.panel.mods"

    // Default hotkeys
    static var defaultCameraCode: UInt32 { UInt32(kVK_ANSI_H) }
    static var defaultCameraMods: UInt32 { UInt32(controlKey | optionKey) }
    static var defaultPanelCode:  UInt32 { 0 }   // 0 = not set
    static var defaultPanelMods:  UInt32 { 0 }

    static func saveFrame(_ f: NSRect) {
        let d = UserDefaults.standard
        d.set(Double(f.origin.x),    forKey: frameX)
        d.set(Double(f.origin.y),    forKey: frameY)
        d.set(Double(f.size.width),  forKey: frameW)
        d.set(Double(f.size.height), forKey: frameH)
    }

    static func restoreFrame() -> NSRect? {
        let d = UserDefaults.standard
        guard d.object(forKey: frameX) != nil else { return nil }
        let r = NSRect(
            x: d.double(forKey: frameX), y: d.double(forKey: frameY),
            width:  max(120, d.double(forKey: frameW)),
            height: max(90,  d.double(forKey: frameH)))
        let onScreen = NSScreen.screens.contains {
            $0.visibleFrame.intersection(r).width  > 60 &&
            $0.visibleFrame.intersection(r).height > 60
        }
        return onScreen ? r : nil
    }
}

// MARK: - Models

struct CameraDeviceInfo {
    let uniqueID:      String
    let localizedName: String
    let aspectRatio:   CGSize
}

struct CameraLaunchConfiguration {
    let previewLayer: AVCaptureVideoPreviewLayer
    let deviceInfo:   CameraDeviceInfo
}

struct OverlayState {
    var cameraName:        String
    var cameraAspectRatio: CGSize
    var previewSize:       CGSize
    var previewOrigin:     CGPoint
    var isLocked:       Bool
    var isAspectLocked: Bool
    var isMirrored:     Bool
    var cornerRadius:   CGFloat
    var opacity:        Float
    var edgeTop:    CGFloat
    var edgeBottom: CGFloat
    var edgeLeft:   CGFloat
    var edgeRight:  CGFloat
    var hoverOpacityEnabled: Bool
    var hoverOpacity:        Float
    var isAtNativeAspect: Bool   // current size matches camera native ratio
    var isAtDefaults:     Bool   // all appearance settings are at defaults
}

// MARK: - App Delegate

final class FloatingCameraScriptApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    // AppKit calls this before showing a menu item. Without it, AppKit ignores
    // isEnabled and auto-enables any item whose target responds to the action.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openEffects(_:)) {
            return activeDeviceSupportsEffectsCache
        }
        return true
    }


    // lazy: defers AVFoundation init until applicationDidFinishLaunching
    // (i.e., after the run loop is active), eliminating pre-run-loop IPC blocking
    private lazy var captureManager = CameraCaptureManager()
    private var previewController:      PreviewWindowController?
    fileprivate var previewScreen: NSScreen? { previewController?.window?.screen }
    private var controlPanelController: ControlPanelWindowController?
    // Cached: true when the active camera supports video effects (non-built-in).
    // Updated in presentOverlay and switchToCamera where device info is available.
    private var activeDeviceSupportsEffectsCache: Bool = false

    private var cameraHotKeyRef: EventHotKeyRef?
    private var panelHotKeyRef:  EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var shortcutsController: ShortcutsWindowController?
    // Keep a legacy alias so existing code doesn't break
    private var hotKeyRef: EventHotKeyRef? {
        get { cameraHotKeyRef } set { cameraHotKeyRef = newValue }
    }

    private var statusItem:         NSStatusItem!
    private var statusMenu:         NSMenu!
    private var cameraSubmenuItem:  NSMenuItem!
    private var showPanelMenuItem:  NSMenuItem!
    private var effectsMenuItem:    NSMenuItem!
    private var hideCameraMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Kick off camera setup on the background queue as early as possible.
        // buildStatusMenu and registerGlobalHotKey run while the camera
        // pipeline is already initialising in parallel.
        captureManager.start { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let cfg): self?.presentOverlay(with: cfg)
                case .failure(let err): self?.showErrorAlert(err)
                }
            }
        }

        buildStatusMenu()
        registerGlobalHotKey()
    }

    // MARK: – Global Hot Key  ⌃⌥H

    private func registerGlobalHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  OSType(kEventHotKeyPressed))
        if eventHandlerRef == nil {
            var ref: EventHandlerRef?
            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let ptr = userData, let event else {
                        return OSStatus(eventNotHandledErr)
                    }
                    var hkID = EventHotKeyID()
                    GetEventParameter(event,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                    let me = Unmanaged<FloatingCameraScriptApp>.fromOpaque(ptr).takeUnretainedValue()
                    DispatchQueue.main.async {
                        switch hkID.id {
                        case 1: me.toggleCameraVisibility()
                        case 2: me.togglePanel(nil)
                        default: break
                        }
                    }
                    return noErr
                },
                1, &eventSpec,
                Unmanaged.passUnretained(self).toOpaque(), &ref)
            eventHandlerRef = ref
        }
        reregisterHotKeys()
    }

    func reregisterHotKeys() {
        let d = UserDefaults.standard
        // Camera visibility hotkey (id=1)
        if let ref = cameraHotKeyRef { UnregisterEventHotKey(ref) }
        cameraHotKeyRef = nil
        let camCode = d.object(forKey: Pref.cameraHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyCode)) : Pref.defaultCameraCode
        let camMods = d.object(forKey: Pref.cameraHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyMods)) : Pref.defaultCameraMods
        if camCode > 0 {
            let hkID = EventHotKeyID(signature: OSType(0x4643414D), id: 1)
            RegisterEventHotKey(camCode, camMods, hkID,
                                GetApplicationEventTarget(), 0, &cameraHotKeyRef)
        }
        // Panel toggle hotkey (id=2) — not set by default
        if let ref = panelHotKeyRef { UnregisterEventHotKey(ref) }
        panelHotKeyRef = nil
        let panCode = d.object(forKey: Pref.panelHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyCode)) : Pref.defaultPanelCode
        let panMods = d.object(forKey: Pref.panelHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyMods)) : Pref.defaultPanelMods
        if panCode > 0 {
            let hkID = EventHotKeyID(signature: OSType(0x4643414D), id: 2)
            RegisterEventHotKey(panCode, panMods, hkID,
                                GetApplicationEventTarget(), 0, &panelHotKeyRef)
        }
        // Update menu labels to reflect current shortcuts
        updateShortcutLabels()
    }

    func updateShortcutLabels() {
        let d = UserDefaults.standard
        let camCode = d.object(forKey: Pref.cameraHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyCode)) : Pref.defaultCameraCode
        let camMods = d.object(forKey: Pref.cameraHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyMods)) : Pref.defaultCameraMods
        let panCode = d.object(forKey: Pref.panelHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyCode)) : Pref.defaultPanelCode
        let panMods = d.object(forKey: Pref.panelHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyMods)) : Pref.defaultPanelMods

        let camLabel = camCode > 0 ? "  " + ShortcutsWindowController.formatShortcut(code: camCode, mods: camMods) : ""
        let panLabel = panCode > 0 ? "  " + ShortcutsWindowController.formatShortcut(code: panCode, mods: panMods) : ""

        let camVis = previewController?.window?.isVisible ?? false
        hideCameraMenuItem?.title = (camVis ? "Hide Camera" : "Show Camera") + camLabel
        let panVis = controlPanelController?.isVisible ?? false
        showPanelMenuItem?.title  = (panVis ? "Hide Control Panel" : "Show Control Panel") + panLabel
    }

    @objc func toggleCameraVisibility() {
        guard let win = previewController?.window else { return }
        if win.isVisible { win.orderOut(nil) } else { win.makeKeyAndOrderFront(nil) }
        syncMenuTitles()
    }

    // MARK: – Status Menu

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.aperture",
                                           accessibilityDescription: "Floating Camera Overlay")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: 16, weight: .medium, scale: .medium))
        statusMenu = NSMenu()
        statusMenu.delegate = self

        cameraSubmenuItem         = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraSubmenuItem.submenu = NSMenu(title: "Camera")

        effectsMenuItem           = NSMenuItem(title: "Camera Effects…",
                                               action: #selector(openEffects(_:)), keyEquivalent: "")
        effectsMenuItem.target    = self
        effectsMenuItem.isEnabled = false  // enabled later by updateEffectsCache

        showPanelMenuItem         = NSMenuItem(title: "Show Control Panel",
                                               action: #selector(togglePanel(_:)), keyEquivalent: "")
        showPanelMenuItem.target  = self

        hideCameraMenuItem        = NSMenuItem(title: "Hide Camera  ⌃⌥H",
                                               action: #selector(toggleCameraVisibility), keyEquivalent: "")
        hideCameraMenuItem.target = self

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self

        let shortcutsItem = NSMenuItem(title: "Shortcuts…",
                                           action: #selector(openShortcuts(_:)), keyEquivalent: "")
        shortcutsItem.target = self

        statusMenu.addItem(cameraSubmenuItem)
        statusMenu.addItem(effectsMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(showPanelMenuItem)
        statusMenu.addItem(hideCameraMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(shortcutsItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(quit)
        statusItem.menu = statusMenu
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildCameraSubmenu(); syncMenuTitles() }

    private func rebuildCameraSubmenu() {
        // Discover devices off the main thread — AVCaptureDevice.DiscoverySession
        // can block for 200-400 ms when Continuity Camera is in the list.
        // Read activeID on the background thread too (avoids queue.sync on main).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let activeID = self.captureManager.activeDeviceUniqueID()
            let devs = CameraCaptureManager.discoverDevices()
            DispatchQueue.main.async {
                let sub = NSMenu(title: "Camera")
                if devs.isEmpty {
                    let item = NSMenuItem(title: "No Cameras Found", action: nil, keyEquivalent: "")
                    item.isEnabled = false; sub.addItem(item)
                } else {
                    for dev in devs {
                        let item = NSMenuItem(title: dev.localizedName,
                                              action: #selector(self.pickCamera(_:)), keyEquivalent: "")
                        item.target = self; item.representedObject = dev.uniqueID
                        item.state  = (dev.uniqueID == activeID) ? .on : .off
                        sub.addItem(item)
                    }
                }
                self.cameraSubmenuItem.submenu = sub
                self.controlPanelController?.refreshCameras(devs, activeID: activeID)
            }
        }
    }

    private func syncMenuTitles() {
        effectsMenuItem.isEnabled = activeDeviceSupportsEffectsCache
        updateShortcutLabels()
    }

    // Update the effects-supported cache directly from a known device UID.
    // Call this whenever the active device changes (presentOverlay, switchToCamera).
    private func updateEffectsCache(uid: String) {
        guard let dev = AVCaptureDevice(uniqueID: uid) else {
            activeDeviceSupportsEffectsCache = false; return
        }
        // builtInWideAngleCamera = FaceTime HD built-in; no video effects support
        activeDeviceSupportsEffectsCache = (dev.deviceType != .builtInWideAngleCamera)
        effectsMenuItem.isEnabled = activeDeviceSupportsEffectsCache
    }

    // MARK: – Overlay Setup

    private func presentOverlay(with cfg: CameraLaunchConfiguration) {
        let preview = PreviewWindowController(
            cameraName:        cfg.deviceInfo.localizedName,
            cameraAspectRatio: cfg.deviceInfo.aspectRatio,
            previewLayer:      cfg.previewLayer)

        let panel = ControlPanelWindowController()

        preview.onStateChanged = { [weak self, weak preview, weak panel] in
            guard let self, let preview, let panel else { return }
            let state = preview.currentState()
            panel.update(with: state)
            panel.positionRelative(to: preview.window?.frame ?? .zero, on: preview.window?.screen)
            self.syncMenuTitles()
        }

        panel.onDidClose      = { [weak self] in self?.syncMenuTitles() }
        panel.onToggleLock    = { [weak preview] in preview?.toggleLock() }
        panel.onToggleAspect  = { [weak preview] in preview?.toggleAspectLock() }
        panel.onResetAspect   = { [weak preview] in preview?.resetAspect() }
        panel.onReset         = { [weak preview] in preview?.resetDefaults() }
        panel.onCenter        = { [weak preview] in preview?.centerOverlay() }
        panel.onToggleMirror  = { [weak preview] in preview?.toggleMirror() }
        panel.onSetRadius     = { [weak preview] r    in preview?.setCornerRadius(r) }
        panel.onSetOpacity    = { [weak preview] v    in preview?.setOpacity(v) }
        panel.onApplySize     = { [weak preview] w, h in preview?.applySize(width: w, height: h) }
        panel.onApplyPosition = { [weak preview] x, y in preview?.applyOrigin(x: x, y: y) }
        panel.onHidePanel     = { [weak self] in self?.controlPanelController?.toggleVisibility(); self?.syncMenuTitles() }
        panel.onSelectCamera  = { [weak self] uid in self?.switchToCamera(uid: uid) }
        panel.onApplyMargin         = { [weak preview] edge, pts in preview?.applyMargin(edge: edge, pts: pts) }
        panel.onSnapCorner          = { [weak preview] token in
            // Token format: "TL", "TR", "BL", "BR" (current screen)
            // or "TL:N", "TR:N" etc. where N is screen index
            let parts = token.components(separatedBy: ":")
            let corner = parts[0]
            let screen: NSScreen?
            if parts.count > 1, let idx = Int(parts[1]) {
                screen = NSScreen.screens.indices.contains(idx) ? NSScreen.screens[idx] : nil
            } else {
                screen = nil
            }
            preview?.snapToCorner(corner, on: screen)
        }
        panel.onToggleHoverOpacity  = { [weak preview] in preview?.toggleHoverOpacity() }
        panel.onSetHoverOpacity     = { [weak preview] v in preview?.setHoverOpacity(v) }
        panel.onOpenShortcuts       = { [weak self] in self?.openShortcuts(nil) }

        previewController      = preview
        controlPanelController = panel

        preview.onContextMenu = { [weak self] in self?.buildPreviewContextMenu() ?? NSMenu() }

        preview.present()
        // Restore panel visibility from last session
        if UserDefaults.standard.object(forKey: Pref.panelVisible) == nil
            || UserDefaults.standard.bool(forKey: Pref.panelVisible) {
            panel.present()  // default: show on first launch
        }

        let state = preview.currentState()
        panel.update(with: state)
        panel.positionRelative(to: preview.window?.frame ?? .zero, on: preview.window?.screen)
        rebuildCameraSubmenu()
        updateEffectsCache(uid: cfg.deviceInfo.uniqueID)
        syncMenuTitles()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPreviewContextMenu() -> NSMenu {
        let menu   = NSMenu()
        // Use cached submenu devices to avoid blocking discoverDevices() on right-click
        let devs   = (cameraSubmenuItem.submenu?.items ?? []).compactMap { item -> AVCaptureDevice? in
            guard let uid = item.representedObject as? String else { return nil }
            return AVCaptureDevice(uniqueID: uid)
        }
        let active = captureManager.activeDeviceUniqueID()
        if !devs.isEmpty {
            let hdr = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
            hdr.isEnabled = false; menu.addItem(hdr)
            for dev in devs {
                let item = NSMenuItem(title: dev.localizedName, action: #selector(pickCamera(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = dev.uniqueID
                item.state = (dev.uniqueID == active) ? .on : .off
                item.indentationLevel = 1; menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let isLocked     = previewController?.isLocked ?? false
        let isPanelVis   = controlPanelController?.isVisible ?? false
        let isCamVis     = previewController?.window?.isVisible ?? true
        func item(_ t: String, _ sel: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; return i
        }
        menu.addItem(item(isLocked ? "Unlock Position" : "Lock Position", #selector(ctxToggleLock)))
        menu.addItem(item("Toggle Mirror",   #selector(ctxMirror)))
        menu.addItem(item("Center on Screen", #selector(ctxCenter)))
        menu.addItem(.separator())
        menu.addItem(item(isCamVis ? "Hide Camera  ⌃⌥H" : "Show Camera  ⌃⌥H", #selector(toggleCameraVisibility)))
        menu.addItem(item(isPanelVis ? "Hide Control Panel" : "Show Control Panel", #selector(togglePanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quitApp(_:))))
        return menu
    }

    // MARK: – Actions

    @objc private func pickCamera(_ s: NSMenuItem) {
        guard let uid = s.representedObject as? String else { return }
        switchToCamera(uid: uid)
    }

    private func switchToCamera(uid: String) {
        captureManager.switchCamera(to: uid) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    self?.previewController?.updateCamera(info.localizedName, aspectRatio: info.aspectRatio)
                    self?.rebuildCameraSubmenu()
                    self?.updateEffectsCache(uid: info.uniqueID)
                    if let p = self?.previewController, let panel = self?.controlPanelController {
                        panel.update(with: p.currentState())
                    }
                case .failure(let err): self?.showErrorAlert(err)
                }
            }
        }
    }

    @objc private func openEffects(_ sender: Any?) {
        guard activeDeviceSupportsEffectsCache else { return }
        // Match the working approach from the original version:
        // just activate and call showSystemUserInterface after one run-loop tick.
        // setActivationPolicy must NOT be used — reverting it closes the panel.
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 12.0, *) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AVCaptureDevice.showSystemUserInterface(.videoEffects)
            }
        } else {
            self.showErrorAlert(NSError(domain: "FloatingCamera", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Camera Effects requires macOS 12 or later."]))
        }
    }

    @objc private func togglePanel(_ s: Any?)     { controlPanelController?.toggleVisibility(); syncMenuTitles() }

    @objc private func openShortcuts(_ sender: Any?) {
        if shortcutsController == nil {
            shortcutsController = ShortcutsWindowController(app: self)
        }
        // Position centred over the control panel (or the preview if no panel)
        if let shortWin = shortcutsController?.window {
            let anchor: NSRect
            if let panelWin = controlPanelController?.window, panelWin.isVisible {
                anchor = panelWin.frame
            } else if let previewWin = previewController?.window {
                anchor = previewWin.frame
            } else {
                anchor = NSScreen.main?.visibleFrame ?? .zero
            }
            let x = anchor.midX - shortWin.frame.width  / 2
            let y = anchor.midY - shortWin.frame.height / 2
            shortWin.setFrameOrigin(NSPoint(x: x, y: y))
        }
        shortcutsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func ctxToggleLock()             { previewController?.toggleLock() }
    @objc private func ctxMirror()                 { previewController?.toggleMirror() }
    @objc private func ctxCenter()                 { previewController?.centerOverlay() }
    @objc private func quitApp(_ s: Any?)          { NSApp.terminate(nil) }

    private func showErrorAlert(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Camera Overlay Error"; a.informativeText = error.localizedDescription
        a.alertStyle = .warning; a.addButton(withTitle: "OK"); a.runModal()
    }
}

// MARK: - Capture Errors

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable, inputCreationFailed, cannotAddInput, permissionDenied, deviceNotFound
    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:   return "No camera was found on this device."
        case .inputCreationFailed: return "Could not create the camera input."
        case .cannotAddInput:      return "Could not add the camera input to the capture session."
        case .permissionDenied:    return "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
        case .deviceNotFound:      return "The selected camera could not be found."
        }
    }
}

// MARK: - Camera Capture Manager

final class CameraCaptureManager {

    // AVCaptureSession is created lazily on the background capture queue.
    // This is the critical fix: creating AVCaptureSession() on the main thread
    // before app.run() sends IPC to mediaserverd without a running run loop,
    // causing a synchronous spin that blocks for 1–3 seconds. By deferring
    // creation to the background queue (where the run loop is irrelevant to
    // the Mach messaging), the block is completely eliminated.
    private var _session:   AVCaptureSession?
    private let queue     = DispatchQueue(label: "camera.capture.q", qos: .userInteractive)
    private var _activeID: String?
    private let activeIDLock = NSLock()

    // NO background discovery warm-up in init().
    // The previous code touched VDCAssistant from a background thread during init,
    // racing with configureSession's own VDCAssistant calls and doubling wait time.
    // Device discovery now happens lazily only when switchCamera or the menu is used.
    init() {}

    deinit {
        queue.sync { _session?.stopRunning() }
    }

    // The session is only ever accessed on `queue` (serial), so this is thread-safe.
    private func captureSession() -> AVCaptureSession {
        if _session == nil { _session = AVCaptureSession() }
        return _session!
    }

    static func discoverDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) }
        else                          { types.append(.externalUnknown) }
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// Non-blocking read: `queue` also runs startRunning() (1–3 s), so reading this
    /// under queue.sync would beachball any main-thread caller for that long.
    func activeDeviceUniqueID() -> String? {
        activeIDLock.lock(); defer { activeIDLock.unlock() }
        return _activeID
    }

    private func setActiveID(_ id: String?) {
        activeIDLock.lock(); _activeID = id; activeIDLock.unlock()
    }


    func start(completion: @escaping (Result<CameraLaunchConfiguration, Error>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureSession(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureSession(completion: completion) }
                else       { completion(.failure(CameraCaptureError.permissionDenied)) }
            }
        default: completion(.failure(CameraCaptureError.permissionDenied))
        }
    }

    func switchCamera(to uid: String, completion: @escaping (Result<CameraDeviceInfo, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // Discovery only runs here, on the background queue, when the user
            // explicitly switches cameras — completely off the startup critical path.
            let devices = Self.discoverDevices()
            guard let dev = devices.first(where: { $0.uniqueID == uid }) else {
                completion(.failure(CameraCaptureError.deviceNotFound)); return
            }
            let session = self.captureSession()
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                session.beginConfiguration()
                // Removal must precede canAddInput() — a session won't take two video
                // inputs — so keep the old inputs and restore them if the new one fails.
                let previousInputs = session.inputs
                previousInputs.forEach { session.removeInput($0) }
                guard session.canAddInput(input) else {
                    previousInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
                    session.commitConfiguration()
                    completion(.failure(CameraCaptureError.cannotAddInput)); return
                }
                session.addInput(input); session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                self.setActiveID(dev.uniqueID)
                completion(.success(Self.makeInfo(dev)))
            } catch { completion(.failure(CameraCaptureError.inputCreationFailed)) }
        }
    }

    private func configureSession(completion: @escaping (Result<CameraLaunchConfiguration, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // AVCaptureSession() is created here, on the background queue, with
            // the run loop already active — mediaserverd IPC completes normally.
            let session = self.captureSession()

            // AVCaptureDevice.default is an O(1) CoreMedia registry lookup.
            // No VDCAssistant contact needed; avoids all device-enumeration cost
            // on the startup critical path.
            guard let dev = AVCaptureDevice.default(for: .video) else {
                completion(.failure(CameraCaptureError.cameraUnavailable)); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                session.beginConfiguration()
                session.sessionPreset = .high   // highest quality (1920×1080)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    completion(.failure(CameraCaptureError.cannotAddInput)); return
                }
                session.addInput(input)
                session.commitConfiguration()

                let layer = AVCaptureVideoPreviewLayer(session: session)
                layer.videoGravity = .resizeAspectFill
                self.setActiveID(dev.uniqueID)

                // Deliver result to main thread BEFORE startRunning() so the
                // overlay window appears immediately (~commit latency, ~150ms).
                // startRunning() fills the preview layer with frames asynchronously.
                completion(.success(CameraLaunchConfiguration(
                    previewLayer: layer, deviceInfo: Self.makeInfo(dev))))

                session.startRunning()
            } catch {
                // The only throwing call — AVCaptureDeviceInput(device:) — runs before
                // beginConfiguration(), so there is no open configuration to commit here.
                completion(.failure(CameraCaptureError.inputCreationFailed))
            }
        }
    }

    private static func makeInfo(_ dev: AVCaptureDevice) -> CameraDeviceInfo {
        let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        return CameraDeviceInfo(uniqueID: dev.uniqueID, localizedName: dev.localizedName,
            aspectRatio: CGSize(width: max(1, Int(d.width)), height: max(1, Int(d.height))))
    }
}

// MARK: - Preview Window

final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Preview Window Controller

final class PreviewWindowController: NSWindowController, NSWindowDelegate {

    private let previewLayer:      AVCaptureVideoPreviewLayer
    private let contentView =      PreviewContentView(frame: .zero)

    private var cameraName:        String
    private var cameraAspectRatio: CGSize
    private(set) var isLocked:     Bool    = false
    private var isAspectLocked:    Bool    = true
    private var isMirrored:        Bool    = false
    private var cornerRadiusValue:   CGFloat = 16
    private var hoverOpacityEnabled: Bool    = false
    private var hoverOpacityValue:   Float   = 0.15
    private var isDragging:          Bool    = false

    var onStateChanged: (() -> Void)?
    var onContextMenu:  (() -> NSMenu)?

    init(cameraName: String, cameraAspectRatio: CGSize, previewLayer: AVCaptureVideoPreviewLayer) {
        self.cameraName        = cameraName
        self.cameraAspectRatio = cameraAspectRatio
        self.previewLayer      = previewLayer

        let d = UserDefaults.standard
        if d.object(forKey: Pref.cornerRadius)   != nil { cornerRadiusValue = CGFloat(d.double(forKey: Pref.cornerRadius)) }
        if d.object(forKey: Pref.isMirrored)     != nil { isMirrored        = d.bool(forKey: Pref.isMirrored) }
        if d.object(forKey: Pref.isAspectLocked)     != nil { isAspectLocked     = d.bool(forKey: Pref.isAspectLocked) }
        if d.object(forKey: Pref.hoverOpacityEnabled) != nil { hoverOpacityEnabled = d.bool(forKey: Pref.hoverOpacityEnabled) }
        if d.object(forKey: Pref.hoverOpacity)        != nil { hoverOpacityValue   = d.float(forKey: Pref.hoverOpacity) }

        let initialFrame: NSRect = {
            if let saved = Pref.restoreFrame() { return saved }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let ratio  = max(0.001, cameraAspectRatio.width / cameraAspectRatio.height)
            let w: CGFloat = min(480, screen.visibleFrame.width * 0.35)
            let h: CGFloat = (w / ratio).rounded()
            return NSRect(x: screen.visibleFrame.midX - w / 2,
                          y: screen.visibleFrame.midY - h / 2 + screen.visibleFrame.height * 0.12,
                          width: w, height: h)
        }()

        let win = PreviewWindow(contentRect: initialFrame, styleMask: [.borderless, .resizable],
                                backing: .buffered, defer: false)
        super.init(window: win)

        win.delegate                    = self
        win.level                       = .floating
        win.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isOpaque                    = false
        win.backgroundColor             = .clear
        win.hasShadow                   = true
        win.isMovableByWindowBackground = true
        win.minSize                     = NSSize(width: 120, height: 90)
        win.isReleasedWhenClosed        = false
        win.contentView                 = contentView

        contentView.attachPreviewLayer(previewLayer)

        if d.object(forKey: Pref.opacity) != nil {
            win.alphaValue = CGFloat(d.float(forKey: Pref.opacity))
        }

        contentView.onContextMenu = { [weak self] in self?.onContextMenu?() ?? NSMenu() }
        contentView.onMouseUp     = { [weak self] in
            self?.isDragging = false
            self?.contentView.setEdgeBadgesVisible(false)
        }

        // Wire hover overlay callbacks
        contentView.onHoverLock   = { [weak self] in self?.toggleLock() }
        contentView.onHoverMirror = { [weak self] in self?.toggleMirror() }
        contentView.onHoverCenter = { [weak self] in self?.centerOverlay() }
        contentView.onHoverHide   = { [weak self] in
            self?.window?.orderOut(nil)
            self?.onStateChanged?()
        }

        applyAspectConstraint()
        applyLockState()
        applyCornerRadius()
        applyMirrorTransform()
        syncHoverOverlay()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func present() { window?.makeKeyAndOrderFront(nil) }

    func currentState() -> OverlayState {
        let f  = window?.frame ?? .zero
        let sf = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Read opacity from the persisted preference, NOT from window.alphaValue.
        // window.alphaValue may be at a transient hover-dim value when an animation
        // is in progress, causing the panel's opacity slider to jump erroneously.
        let d = UserDefaults.standard
        let persistedOpacity: Float = d.object(forKey: Pref.opacity) != nil
            ? d.float(forKey: Pref.opacity)
            : Float(window?.alphaValue ?? 1)
        return OverlayState(cameraName: cameraName, cameraAspectRatio: cameraAspectRatio, previewSize: f.size, previewOrigin: f.origin,
            isLocked: isLocked, isAspectLocked: isAspectLocked, isMirrored: isMirrored,
            cornerRadius: cornerRadiusValue, opacity: persistedOpacity,
            edgeTop:    max(0, sf.maxY - f.maxY),
            edgeBottom: max(0, f.minY  - sf.minY),
            edgeLeft:   max(0, f.minX  - sf.minX),
            edgeRight:  max(0, sf.maxX - f.maxX),
            hoverOpacityEnabled: hoverOpacityEnabled,
            hoverOpacity:        hoverOpacityValue,
            isAtNativeAspect: isAtNativeAspect,
            isAtDefaults:     isAtDefaults)
    }

    // MARK: Public API

    func updateCamera(_ name: String, aspectRatio: CGSize) {
        cameraName = name; cameraAspectRatio = aspectRatio
        applyAspectConstraint()
        if isAspectLocked { fitHeightToAspect() }
        syncHoverOverlay(); onStateChanged?()
    }

    func toggleLock() {
        isLocked.toggle(); applyLockState()
        syncHoverOverlay(); onStateChanged?()
    }

    func toggleAspectLock() {
        isAspectLocked.toggle(); applyAspectConstraint()
        UserDefaults.standard.set(isAspectLocked, forKey: Pref.isAspectLocked)
        onStateChanged?()
    }

    /// Reset aspect ratio to camera native with minimum dimension adjustment.
    /// Keeps the larger dimension unchanged and adjusts the smaller one.
    func resetAspect() {
        guard let win = window else { return }
        let ratio = cameraAspectRatio.width / max(1, cameraAspectRatio.height)
        let f = win.frame
        // Compute both candidate sizes
        let hFromW = (f.width / ratio).rounded()
        let wFromH = (f.height * ratio).rounded()
        // Pick whichever requires the smaller total change
        let changeW = abs(wFromH - f.width)
        let changeH = abs(hFromW - f.height)
        let (newW, newH): (CGFloat, CGFloat)
        if changeW <= changeH {
            // Adjust width, keep height
            newW = max(120, wFromH)
            newH = max(90,  f.height)
        } else {
            // Adjust height, keep width
            newW = max(120, f.width)
            newH = max(90,  hFromW)
        }
        isAspectLocked = true; applyAspectConstraint()
        win.setFrame(NSRect(x: f.minX, y: f.minY, width: newW, height: newH), display: true)
        UserDefaults.standard.set(true, forKey: Pref.isAspectLocked)
        persistFrame(); onStateChanged?()
    }

    /// True when the current window aspect ratio already matches the camera's native ratio
    var isAtNativeAspect: Bool {
        guard let win = window else { return true }
        let f = win.frame
        let native = cameraAspectRatio.width / max(1, cameraAspectRatio.height)
        let current = f.width / max(1, f.height)
        return abs(native - current) < 0.01
    }

    /// Reset all appearance settings to defaults, including size to camera native aspect ratio.
    func resetDefaults() {
        setCornerRadius(16)
        setOpacity(1.0)
        if isMirrored { toggleMirror() }
        if hoverOpacityEnabled { toggleHoverOpacity() }
        // Reset size to a sensible default at the native camera aspect ratio
        let ratio = cameraAspectRatio.width / max(1, cameraAspectRatio.height)
        let defaultW: CGFloat = 360
        let defaultH = (defaultW / ratio).rounded()
        guard let win = window else { onStateChanged?(); return }
        let f = win.frame
        // Unlock first so setFrame works without aspect constraints
        isAspectLocked = false; applyAspectConstraint()
        win.setFrame(NSRect(x: f.minX, y: f.minY, width: defaultW, height: defaultH), display: true)
        // Now lock at native ratio
        isAspectLocked = true
        win.contentAspectRatio = NSSize(width: cameraAspectRatio.width, height: cameraAspectRatio.height)
        UserDefaults.standard.set(true, forKey: Pref.isAspectLocked)
        persistFrame(); onStateChanged?()
    }

    /// True when all appearance settings are already at their defaults.
    var isAtDefaults: Bool {
        let sizeOk: Bool
        if let f = window?.frame {
            let ratio = cameraAspectRatio.width / max(1, cameraAspectRatio.height)
            let expectedH = (360.0 / ratio).rounded()
            sizeOk = abs(f.width - 360) < 1 && abs(f.height - expectedH) < 1
        } else {
            sizeOk = true
        }
        return cornerRadiusValue == 0
            && isAspectLocked
            && isAtNativeAspect
            && !isMirrored
            && !hoverOpacityEnabled
            && abs((window?.alphaValue ?? 1.0) - 1.0) < 0.01
            && sizeOk
    }

    func centerOverlay() { window?.center(); persistFrame(); onStateChanged?() }

    func toggleMirror() {
        isMirrored.toggle(); applyMirrorTransform()
        UserDefaults.standard.set(isMirrored, forKey: Pref.isMirrored)
        syncHoverOverlay(); onStateChanged?()
    }

    func setCornerRadius(_ v: CGFloat) {
        // Cap at half the smallest side so we never exceed a perfect circle.
        // 9999 is treated as "use the cap" (Full mode).
        let halfMin: CGFloat
        if let f = window?.frame { halfMin = min(f.width, f.height) / 2 }
        else                     { halfMin = 9999 }
        cornerRadiusValue = min(max(0, v), halfMin); applyCornerRadius()
        UserDefaults.standard.set(Double(cornerRadiusValue), forKey: Pref.cornerRadius)
        onStateChanged?()
    }

    func setOpacity(_ v: Float) {
        let c = max(0.05, min(1.0, v))
        window?.alphaValue = CGFloat(c)
        UserDefaults.standard.set(c, forKey: Pref.opacity)
        onStateChanged?()
    }

    func applySize(width: CGFloat, height: CGFloat) {
        guard let win = window else { return }
        let ratio = max(0.001, cameraAspectRatio.width / cameraAspectRatio.height)
        var w = max(120, width)
        var h: CGFloat
        if isAspectLocked {
            // If the caller passed width unchanged but a new height, derive width
            // from the new height so the height stepper has a visible effect.
            let currentW = win.frame.width
            let heightChanged = abs(height - win.frame.height) > 0.5
            let widthUnchanged = abs(width - currentW) < 0.5
            if heightChanged && widthUnchanged {
                // Height-driven resize: compute width from requested height
                let hClamped = max(90, height)
                w = max(120, (hClamped * ratio).rounded())
                h = (w / ratio).rounded()
            } else {
                // Width-driven resize (normal path)
                h = (w / ratio).rounded()
            }
        } else {
            h = max(90, height)
        }
        let f = win.frame
        win.setFrame(NSRect(x: f.minX, y: f.minY, width: w, height: h), display: true)
        persistFrame(); onStateChanged?()
    }

    func applyOrigin(x: CGFloat, y: CGFloat) {
        guard let win = window else { return }
        let f = win.frame
        win.setFrame(NSRect(x: x, y: y, width: f.width, height: f.height), display: true)
        persistFrame(); onStateChanged?()
    }

    /// Snap to a named corner ("TL", "TR", "BL", "BR") preserving the current
    /// distance from each relevant edge. E.g. "BR" keeps the bottom and right margins.
    /// Snap the window to a named corner ("TL","TR","BL","BR").
    /// Uses the current padding from the two relevant edges, clamped to 20pt so
    /// the window always ends up visually near the corner regardless of where it was.
    func snapToCorner(_ corner: String, on targetScreen: NSScreen? = nil) {
        guard let win = window else { return }
        let screen = targetScreen ?? win.screen ?? NSScreen.main
        guard let screen else { return }
        let sf = screen.visibleFrame
        let f  = win.frame
        // Use a constant 10pt margin — clean, predictable, no edge-case collapses.
        let pad: CGFloat = 10
        let newX, newY: CGFloat
        switch corner {
        case "TL": newX = sf.minX + pad;              newY = sf.maxY - f.height - pad
        case "TR": newX = sf.maxX - f.width - pad;    newY = sf.maxY - f.height - pad
        case "BL": newX = sf.minX + pad;              newY = sf.minY + pad
        case "BR": newX = sf.maxX - f.width - pad;    newY = sf.minY + pad
        default:   newX = f.minX; newY = f.minY
        }
        win.setFrame(NSRect(x: newX, y: newY, width: f.width, height: f.height), display: true)
        persistFrame(); onStateChanged?()
    }

    func toggleHoverOpacity() {
        hoverOpacityEnabled.toggle()
        UserDefaults.standard.set(hoverOpacityEnabled, forKey: Pref.hoverOpacityEnabled)
        applyLockState()
        syncHoverOverlay()   // keeps _hoverOpacityEnabled in contentView in sync
        onStateChanged?()
    }

    func setHoverOpacity(_ v: Float) {
        hoverOpacityValue = max(0.0, min(1.0, v))
        UserDefaults.standard.set(hoverOpacityValue, forKey: Pref.hoverOpacity)
        onStateChanged?()
    }

    /// Move window so the specified edge is `pts` points from the screen boundary.
    func applyMargin(edge: String, pts: CGFloat) {
        guard let win = window else { return }
        let sf = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var f  = win.frame
        switch edge {
        case "top":    f.origin.y = sf.maxY - f.height - pts
        case "bottom": f.origin.y = sf.minY + pts
        case "left":   f.origin.x = sf.minX + pts
        case "right":  f.origin.x = sf.maxX - f.width - pts
        default: break
        }
        win.setFrame(f, display: true)
        persistFrame(); onStateChanged?()
    }

    // MARK: Private

    private func applyLockState() {
        guard let win = window else { return }
        if isLocked {
            win.styleMask.remove(.resizable)
            win.isMovableByWindowBackground = false
            // Always ignoresMouse when locked — the only reliable way to pass
            // clicks through to windows below at the OS level.
            win.ignoresMouseEvents = true

            // Hover-opacity tracking uses a global NSEvent monitor so that
            // mouse-entered/exited events still reach us while ignoresMouse=true.
            if hoverOpacityEnabled {
                installMouseMonitor()
            } else {
                removeMouseMonitor()
                // Restore persisted opacity — may be hover-dimmed regardless of
                // isMouseOverWindow if monitor was removed before mouse exited
                restorePersistedOpacity()
            }
        } else {
            win.styleMask.insert(.resizable)
            win.isMovableByWindowBackground = true
            win.ignoresMouseEvents          = false
            removeMouseMonitor()
            // Always restore persisted opacity on unlock — the window may be
            // hover-dimmed regardless of isMouseOverWindow state.
            restorePersistedOpacity()
        }
    }

    // MARK: Global mouse monitor for locked hover-opacity

    private var mouseMonitor: Any?
    private var isMouseOverWindow = false

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            self?.evaluateMousePosition()
        }
        // Also check immediately in case cursor is already over the window
        evaluateMousePosition()
    }

    private func removeMouseMonitor() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        isMouseOverWindow = false
    }

    private func evaluateMousePosition() {
        guard isLocked, hoverOpacityEnabled, let win = window else { return }
        let over = win.frame.contains(NSEvent.mouseLocation)
        guard over != isMouseOverWindow else { return }
        isMouseOverWindow = over
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            if over {
                // Snapshot current opacity before dimming so we can restore exactly
                self._storedOpacity = Float(win.alphaValue)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    win.animator().alphaValue = CGFloat(self.hoverOpacityValue)
                }
            } else {
                let target = self._storedOpacity
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    win.animator().alphaValue = CGFloat(target)
                }
            }
        }
    }

    // Base opacity = persisted opacity (not the hover value)
    // Snapshot of the window's opacity before hover-dimming, so we restore
    // to exactly what it was rather than guessing.
    private var _storedOpacity: Float = 1.0

    // Restore opacity after mouse exits (only if we were hover-dimmed)
    private func restoreBaseOpacity() {
        guard isMouseOverWindow else { return }
        isMouseOverWindow = false
        guard let win = window else { return }
        let target = _storedOpacity
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            win.animator().alphaValue = CGFloat(target)
        }
    }

    // Restore to the user-set (persisted) opacity on unlock.
    // Called unconditionally — the window may be hover-dimmed even if
    // isMouseOverWindow is false (race between removeMouseMonitor and unlock).
    private func restorePersistedOpacity() {
        guard let win = window else { return }
        isMouseOverWindow = false
        // Read the persisted value; fall back to current alphaValue if not set
        let d = UserDefaults.standard
        let target: CGFloat = d.object(forKey: Pref.opacity) != nil
            ? CGFloat(d.float(forKey: Pref.opacity))
            : CGFloat(_storedOpacity)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            win.animator().alphaValue = target
        }
    }

    private func applyAspectConstraint() {
        guard let win = window else { return }
        if isAspectLocked {
            // Lock to the CURRENT window ratio, not the camera native.
            // This allows the user to resize freely then lock at any shape.
            let f = win.frame
            let w = f.width.isFinite && f.width > 0 ? f.width : cameraAspectRatio.width
            let h = f.height.isFinite && f.height > 0 ? f.height : cameraAspectRatio.height
            win.contentAspectRatio = NSSize(width: w, height: h)
        } else {
            // Setting contentAspectRatio to .zero (0×0) causes a NaN divide
            // during live resize and crashes AppKit. Reset via resizeIncrements instead.
            win.contentAspectRatio = NSSize.zero
            win.resizeIncrements   = NSSize(width: 1, height: 1)
        }
    }

    private func applyCornerRadius() { contentView.cornerRadius = cornerRadiusValue }

    private func applyMirrorTransform() {
        previewLayer.transform = isMirrored
            ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
    }

    private func fitHeightToAspect() {
        guard let win = window else { return }
        let w = win.frame.width
        let h = (w / max(0.001, cameraAspectRatio.width / cameraAspectRatio.height)).rounded()
        let f = win.frame
        win.setFrame(NSRect(x: f.minX, y: f.minY, width: w, height: h), display: true)
    }

    private func persistFrame() {
        guard let f = window?.frame else { return }
        Pref.saveFrame(f)
    }

    private func syncHoverOverlay() {
        let wf = window?.frame ?? .zero
        let sf = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        contentView.updateHoverState(cameraName: cameraName, isLocked: isLocked,
                                     isMirrored: isMirrored, windowFrame: wf, screenFrame: sf,
                                     hoverOpacityEnabled: hoverOpacityEnabled,
                                     hoverOpacity: hoverOpacityValue)
    }

    // MARK: NSWindowDelegate
    func windowWillMove(_ n: Notification) {
        isDragging = true
        contentView.setEdgeBadgesVisible(true)
        syncHoverOverlay()
    }
    func windowDidMove(_ n: Notification) {
        persistFrame()
        syncHoverOverlay()
        onStateChanged?()
        // Hide badges shortly after movement stops
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isDragging else { return }
            self.contentView.setEdgeBadgesVisible(false)
        }
    }
    func windowDidEndLiveResize(_ n: Notification) {
        isDragging = false
        persistFrame(); syncHoverOverlay(); onStateChanged?()
    }
    func windowWillResize(_ sender: NSWindow, to newSize: NSSize) -> NSSize {
        // Elevate level above .floating so the camera controls panel can't
        // intercept mouse events during live resize.
        sender.level = .statusBar
        let w = newSize.width.isFinite  ? max(120, newSize.width)  : sender.frame.width
        let h = newSize.height.isFinite ? max(90,  newSize.height) : sender.frame.height
        return NSSize(width: w, height: h)
    }
    func windowDidResize(_ n: Notification) {
        window?.level = .floating   // restore normal level after resize
        persistFrame(); syncHoverOverlay(); onStateChanged?()
    }
    func windowDidBecomeKey(_ n: Notification) { isDragging = false }
}

// MARK: - Preview Content View

final class PreviewContentView: NSView {

    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private let hoverControls    = HoverControlsView()
    private var trackingArea:      NSTrackingArea?
    private var _isLocked          = false
    private var _hoverOpacityEnabled = false
    private var _hoverOpacity:     Float = 0.15
    // When true, hitTest returns nil so clicks fall through to windows below,
    // but NSTrackingArea still fires for opacity changes.

    // Callbacks for hover overlay buttons
    var onHoverLock:   (() -> Void)? { didSet { hoverControls.onLock   = onHoverLock } }
    var onHoverMirror: (() -> Void)? { didSet { hoverControls.onMirror = onHoverMirror } }
    var onHoverCenter: (() -> Void)? { didSet { hoverControls.onCenter = onHoverCenter } }
    var onHoverHide:   (() -> Void)? { didSet { hoverControls.onHide   = onHoverHide } }

    var onContextMenu: (() -> NSMenu)?

    var cornerRadius: CGFloat = 16 {
        didSet {
            layer?.cornerRadius         = cornerRadius
            layer?.masksToBounds        = true
            previewLayer?.cornerRadius  = cornerRadius
            previewLayer?.masksToBounds = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverControls.alphaValue = 0
        addSubview(hoverControls)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer {
        let l = CALayer()
        l.backgroundColor = NSColor.black.cgColor
        l.cornerRadius    = cornerRadius
        l.masksToBounds   = true
        return l
    }

    func attachPreviewLayer(_ avLayer: AVCaptureVideoPreviewLayer) {
        previewLayer?.removeFromSuperlayer()
        previewLayer = avLayer
        avLayer.videoGravity  = .resizeAspectFill
        avLayer.frame         = bounds
        avLayer.cornerRadius  = cornerRadius
        avLayer.masksToBounds = true
        self.layer!.insertSublayer(avLayer, at: 0)
    }

    func updateHoverState(cameraName: String, isLocked: Bool, isMirrored: Bool,
                          windowFrame: NSRect, screenFrame: NSRect,
                          hoverOpacityEnabled: Bool = false, hoverOpacity: Float = 0.15) {
        _isLocked              = isLocked
        _hoverOpacityEnabled   = hoverOpacityEnabled
        _hoverOpacity          = hoverOpacity
        // Run update() first — it may trigger implicit layer animations on buttons.
        // hideImmediately() must come AFTER so its removeAllAnimations() + alpha=0
        // is the final operation, not overridden by button tinting animations.
        hoverControls.update(cameraName: cameraName, isLocked: isLocked, isMirrored: isMirrored,
                             windowFrame: windowFrame, screenFrame: screenFrame)
        // Always hide hover buttons when locked — regardless of hover opacity setting.
        if isLocked { hoverControls.hideImmediately() }
    }

    override func layout() {
        super.layout()
        previewLayer?.frame        = bounds
        previewLayer?.cornerRadius = cornerRadius
        hoverControls.frame        = bounds
    }

    // MARK: Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        // Hover controls are only shown when unlocked.
        // Locked hover-opacity is handled by a global NSEvent monitor in
        // PreviewWindowController, which works even with ignoresMouseEvents=true.
        guard !_isLocked else { return }
        hoverControls.show()
    }

    override func mouseExited(with event: NSEvent) {
        guard !_isLocked else { return }
        hoverControls.hideAfterDelay()
    }

    func setEdgeBadgesVisible(_ visible: Bool) {
        hoverControls.setEdgeBadgesVisible(visible)
    }

    var onMouseUp: (() -> Void)?

    // Catch mouse-up after isMovableByWindowBackground drag ends
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
}

// MARK: - Hover Controls View
// Transparent full-bounds overlay shown on mouse-enter (unlocked only).
// Four individual circular buttons arranged in a horizontal row near the bottom,
// plus four edge-distance badges near each edge.
// hitTest restricts interactivity to the button circles and badges only.

final class HoverControlsView: NSView {

    var onLock:   (() -> Void)?
    var onMirror: (() -> Void)?
    var onCenter: (() -> Void)?
    var onHide:   (() -> Void)?

    // Individual circular action buttons (no shared container)
    private let lockBtn   = CircleHoverButton(symbol: "lock.fill",      size: 12, tip: "Lock / Unlock")
    private let mirrorBtn = CircleHoverButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", size: 12, tip: "Flip")
    private let centerBtn = CircleHoverButton(symbol: "dot.viewfinder", size: 12, tip: "Center")
    private let hideBtn   = CircleHoverButton(symbol: "eye.slash",      size: 12, tip: "Hide  ⌃⌥H")

    // Edge distance badges
    private let topBadge    = EdgeBadge()
    private let bottomBadge = EdgeBadge()
    private let leftBadge   = EdgeBadge()
    private let rightBadge  = EdgeBadge()

    private var hideTimer: DispatchWorkItem?

    // Badges start hidden; shown only during window drag
    private var edgeBadgesVisible = false

    func setEdgeBadgesVisible(_ visible: Bool) {
        edgeBadgesVisible = visible
        let badges: [EdgeBadge] = [topBadge, bottomBadge, leftBadge, rightBadge]
        let alpha: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.25
            badges.forEach { $0.animator().alphaValue = alpha }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Start all badges hidden — they appear only during drag
        [topBadge, bottomBadge, leftBadge, rightBadge].forEach { $0.alphaValue = 0 }

        lockBtn.action   = #selector(tapLock);   lockBtn.target   = self
        mirrorBtn.action = #selector(tapMirror); mirrorBtn.target = self
        centerBtn.action = #selector(tapCenter); centerBtn.target = self
        hideBtn.action   = #selector(tapHide);   hideBtn.target   = self

        for btn in [lockBtn, mirrorBtn, centerBtn, hideBtn] { addSubview(btn) }
        for badge in [topBadge, bottomBadge, leftBadge, rightBadge] { addSubview(badge) }
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        hideTimer?.cancel()
        hideTimer = nil
    }

    // MARK: Update

    func update(cameraName: String, isLocked: Bool, isMirrored: Bool,
                windowFrame: NSRect, screenFrame: NSRect) {
        let accent = NSColor(red: 0.38, green: 0.67, blue: 1.0, alpha: 1)
        lockBtn.contentTintColor   = isLocked  ? accent : .white
        lockBtn.image = NSImage(systemSymbolName: isLocked ? "lock.fill" : "lock.open.fill",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        mirrorBtn.contentTintColor = isMirrored ? accent : .white

        let eTop    = max(0, screenFrame.maxY - windowFrame.maxY)
        let eBottom = max(0, windowFrame.minY - screenFrame.minY)
        let eLeft   = max(0, windowFrame.minX - screenFrame.minX)
        let eRight  = max(0, screenFrame.maxX - windowFrame.maxX)
        topBadge.setText(Int(eTop))
        bottomBadge.setText(Int(eBottom))
        leftBadge.setText(Int(eLeft))
        rightBadge.setText(Int(eRight))

        needsLayout = true
    }

    // MARK: Show / Hide

    func show() {
        hideTimer?.cancel(); hideTimer = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func hideAfterDelay(_ delay: TimeInterval = 0.55) {
        let item = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self?.animator().alphaValue = 0
            }
        }
        hideTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func hideImmediately() {
        hideTimer?.cancel(); hideTimer = nil
        // Cancel any in-flight Core Animation (e.g. the fade-in from show())
        // before setting alpha directly. Without this, the presentation layer
        // can override the direct alphaValue = 0 assignment.
        layer?.removeAllAnimations()
        alphaValue = 0
    }

    // Only circles and badges receive clicks; blank space falls through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let interactive: [NSView] = [lockBtn, mirrorBtn, centerBtn, hideBtn,
                                      topBadge, bottomBadge, leftBadge, rightBadge]
        for v in interactive {
            if v.frame.contains(point) { return super.hitTest(point) }
        }
        return nil
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height

        // ── Circular action buttons — horizontal row, bottom-centred ──────────
        let btnSz:  CGFloat = 34    // circle diameter
        let btnGap: CGFloat = 10    // gap between circles
        let btns: [NSView]  = [lockBtn, mirrorBtn, centerBtn, hideBtn]
        let totalW = CGFloat(btns.count) * btnSz + CGFloat(btns.count - 1) * btnGap
        let startX = (W - totalW) / 2
        let btnY:  CGFloat = 18    // from bottom edge
        for (i, btn) in btns.enumerated() {
            btn.frame = CGRect(x: startX + CGFloat(i) * (btnSz + btnGap),
                               y: btnY, width: btnSz, height: btnSz)
        }

        // ── Edge distance badges ──────────────────────────────────────────────
        let badgeW: CGFloat = 52
        let badgeH: CGFloat = 20
        let edgePad: CGFloat = 10

        topBadge.frame    = CGRect(x: (W - badgeW) / 2, y: H - edgePad - badgeH,
                                   width: badgeW, height: badgeH)
        // bottom badge sits above the buttons row
        bottomBadge.frame = CGRect(x: (W - badgeW) / 2, y: btnY + btnSz + 8,
                                   width: badgeW, height: badgeH)
        leftBadge.frame   = CGRect(x: edgePad, y: (H - badgeH) / 2,
                                   width: badgeW, height: badgeH)
        rightBadge.frame  = CGRect(x: W - edgePad - badgeW, y: (H - badgeH) / 2,
                                   width: badgeW, height: badgeH)
    }

    @objc private func tapLock()   { onLock?() }
    @objc private func tapMirror() { onMirror?() }
    @objc private func tapCenter() { onCenter?() }
    @objc private func tapHide()   { onHide?() }
}

// MARK: - Circular Hover Button
// Dark circle with a system symbol icon. No shared container.
// Matches the style in the reference image: compact dark disc, icon centred, spacing via layout.

// CircleHoverButton — dark circular icon button.
// The icon is rendered at `iconSize` pt via SymbolConfiguration. The button
// diameter is fixed at 34pt, giving (34 - rendered_icon_pt) / 2 of visual
// padding on each side — so a 10pt icon has ~12pt of breathing room.
// imageScaling = .scaleNone preserves the exact SymbolConfiguration size
// without NSButton re-scaling it to fill the button bounds.
final class CircleHoverButton: NSButton {
    static let diameter: CGFloat = 34

    init(symbol: String, size: CGFloat, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        let cfg      = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image        = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                           .withSymbolConfiguration(cfg)
        isBordered       = false
        imagePosition    = .imageOnly
        // .scaleNone preserves the SymbolConfiguration-specified size; the button
        // circle provides the padding around it automatically.
        imageScaling     = .scaleNone
        contentTintColor = .white
        toolTip          = tip
        wantsLayer       = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.76).cgColor
        layer?.cornerRadius    = Self.diameter / 2
        layer?.borderColor     = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.borderWidth     = 0.5
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 0.82).cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.76).cgColor
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.80).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.76).cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
}

// MARK: - Edge Distance Badge

final class EdgeBadge: NSView {
    // Use NSTextField with a known fixed height and vertically-centred baseline offset.
    // NSTextField in non-bezeled, non-editable mode draws text at the BOTTOM of its
    // frame by default (unlike a UILabel). We size the frame to the full badge height
    // and add a bottom inset so the glyph sits in the visual centre of the capsule.
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.68).cgColor
        layer?.cornerRadius    = 4
        label.textColor        = NSColor.white.withAlphaComponent(0.85)
        label.font             = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        label.alignment        = .center
        label.isBezeled        = false
        label.drawsBackground  = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ px: Int) {
        label.stringValue = "\(px) px"
    }

    override func layout() {
        super.layout()
        // Place the label frame to fill the badge, then apply a bottom offset so the
        // glyph body (cap-height centred) sits visually in the middle of the capsule.
        // AppKit draws NSTextField text starting at (frame.y + descender_offset) from
        // the bottom, so offsetting the frame upward by ~2 pt corrects for the descent.
        let font    = label.font ?? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let ascender  = font.ascender         //  positive, e.g.  8.0
        let descender = font.descender        //  negative, e.g. -2.0
        let lineH   = ceil(ascender - descender)          // total glyph box height
        let baseline = (bounds.height / 2) - (ascender - lineH / 2)  // y of baseline
        // Give the label the full width; height = lineH + 1 for antialiasing headroom
        label.frame = CGRect(x: 4, y: (baseline - (-descender)).rounded(),
                             width: bounds.width - 8, height: lineH + 1)
    }

    override func mouseDown(with event: NSEvent) {}
}

// MARK: - Hover Icon Button

final class HoverIconButton: NSButton {
    init(symbol: String, size: CGFloat, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let cfg      = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image        = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                           .withSymbolConfiguration(cfg)
        isBordered       = false
        imagePosition    = .imageOnly
        imageScaling     = .scaleProportionallyUpOrDown
        contentTintColor = .white
        toolTip          = tip
        wantsLayer       = true
        layer?.cornerRadius = 5
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
}

// MARK: - Control Panel Window

final class ControlPanelWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.characters?.lowercased() == "q" {
            NSApp.terminate(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Control Panel Window Controller

final class ControlPanelWindowController: NSWindowController, NSWindowDelegate {

    var onDidClose:      (() -> Void)?
    var onToggleLock:    (() -> Void)?
    var onToggleAspect:  (() -> Void)?
    var onResetAspect:   (() -> Void)?   // snap to native aspect ratio
    var onReset:         (() -> Void)?   // reset all appearance to defaults
    var onCenter:        (() -> Void)?
    var onToggleMirror:  (() -> Void)?
    var onSetRadius:     ((CGFloat) -> Void)?
    var onSetOpacity:    ((Float) -> Void)?
    var onApplySize:     ((CGFloat, CGFloat) -> Void)?
    var onApplyPosition: ((CGFloat, CGFloat) -> Void)?
    var onHidePanel:     (() -> Void)?
    var onSelectCamera:  ((String) -> Void)?
    var onApplyMargin:         ((String, CGFloat) -> Void)?  // edge "top"|"bottom"|"left"|"right", pts
    var onToggleHoverOpacity:  (() -> Void)?
    var onSetHoverOpacity:     ((Float) -> Void)?
    var onOpenShortcuts:       (() -> Void)?
    var onSnapCorner:          ((String) -> Void)?  // "TL"|"TR"|"BL"|"BR"

    private let content = ControlPanelContentView(frame: .zero)
    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        let panel = ControlPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 365),
            styleMask:   [.titled, .closable],
            backing:     .buffered, defer: false)
        super.init(window: panel)

        panel.title               = "Camera Controls"
        panel.delegate            = self
        panel.level               = .floating
        panel.collectionBehavior  = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.appearance          = NSAppearance(named: .darkAqua)
        panel.backgroundColor     = .windowBackgroundColor
        panel.contentView         = content

        wireActions()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil); onDidClose?(); return false
    }

    func windowDidBecomeVisible() {
        UserDefaults.standard.set(true,  forKey: "cam.panelVisible")
    }
    func windowDidResignKey(_ n: Notification) {}
    func windowDidChangeOcclusionState(_ n: Notification) {
        // Save visibility whenever it changes
        UserDefaults.standard.set(window?.isVisible ?? false, forKey: "cam.panelVisible")
    }

    private func wireActions() {
        content.lockButton.target     = self; content.lockButton.action     = #selector(tapLock)
        content.aspectButton.target   = self; content.aspectButton.action   = #selector(tapAspect)
        content.resetButton.target       = self; content.resetButton.action       = #selector(tapReset)
        content.resetAspectButton.target = self; content.resetAspectButton.action = #selector(tapResetAspect)
        content.centerButton.target   = self; content.centerButton.action   = #selector(tapCenter)
        content.mirrorButton.target   = self; content.mirrorButton.action   = #selector(tapMirror)
        content.hidePanelButton.target = self; content.hidePanelButton.action = #selector(tapHide)
        content.applySizeButton.target     = self; content.applySizeButton.action     = #selector(tapApplySize)
        content.applyPositionButton.target = self; content.applyPositionButton.action = #selector(tapApplyPos)
        content.xField.target = self; content.xField.action = #selector(fieldX(_:))
        content.yField.target = self; content.yField.action = #selector(fieldY(_:))
        content.radiusSlider.target   = self; content.radiusSlider.action   = #selector(sliderRadius(_:))
        content.radiusField.target    = self; content.radiusField.action    = #selector(fieldRadius(_:))
        content.opacitySlider.target  = self; content.opacitySlider.action  = #selector(sliderOpacity(_:))
        content.opacityField.target   = self; content.opacityField.action   = #selector(fieldOpacity(_:))
        content.cameraPopup.target    = self; content.cameraPopup.action    = #selector(popupCamera(_:))
        content.shortcutsButton.target = self; content.shortcutsButton.action = #selector(tapShortcuts)
        content.moveToButton.target = self; content.moveToButton.action = #selector(tapMoveToMenu(_:))
        content.applyMarginsButton.target      = self; content.applyMarginsButton.action      = #selector(tapApplyMargins)
        content.hoverOpacityToggle.target       = self; content.hoverOpacityToggle.action       = #selector(tapHoverOpacityToggle)
        content.hoverOpacitySlider.target       = self; content.hoverOpacitySlider.action       = #selector(sliderHoverOpacity(_:))
        content.hoverOpacityField.target        = self; content.hoverOpacityField.action        = #selector(fieldHoverOpacity(_:))
        // Steppers — each wired to its own @objc action
        content.radiusStepper.target  = self; content.radiusStepper.action  = #selector(stepRadius(_:))
        content.opacityStepper.target = self; content.opacityStepper.action = #selector(stepOpacity(_:))
        content.hoverOpacityStepper.target = self; content.hoverOpacityStepper.action = #selector(stepHoverOpacity(_:))
        content.widthStepper.target   = self; content.widthStepper.action   = #selector(stepWidth(_:))
        content.heightStepper.target  = self; content.heightStepper.action  = #selector(stepHeight(_:))
        content.xStepper.target       = self; content.xStepper.action       = #selector(stepX(_:))
        content.yStepper.target       = self; content.yStepper.action       = #selector(stepY(_:))
        content.edgeTopStepper.target    = self; content.edgeTopStepper.action    = #selector(stepEdgeTop(_:))
        content.edgeRightStepper.target  = self; content.edgeRightStepper.action  = #selector(stepEdgeRight(_:))
        content.edgeBottomStepper.target = self; content.edgeBottomStepper.action = #selector(stepEdgeBottom(_:))
        content.edgeLeftStepper.target   = self; content.edgeLeftStepper.action   = #selector(stepEdgeLeft(_:))
    }

    // MARK: Public

    func present()          { window?.makeKeyAndOrderFront(nil) }
    func toggleVisibility() {
        if isVisible { window?.orderOut(nil) } else { present() }
        UserDefaults.standard.set(isVisible, forKey: Pref.panelVisible)
    }

    func refreshCameras(_ devices: [AVCaptureDevice], activeID: String?) {
        let popup = content.cameraPopup
        popup.removeAllItems()
        if devices.isEmpty {
            popup.addItem(withTitle: "No Cameras Found"); popup.isEnabled = false
        } else {
            popup.isEnabled = true
            for dev in devices {
                popup.addItem(withTitle: dev.localizedName)
                popup.lastItem?.representedObject = dev.uniqueID
            }
            if let aid = activeID, let idx = devices.firstIndex(where: { $0.uniqueID == aid }) {
                popup.selectItem(at: idx)
            }
        }
    }

    func positionRelative(to previewFrame: NSRect, on screen: NSScreen?) {
        guard let win = window else { return }
        let vis = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let sz  = win.frame.size; let gap: CGFloat = 12
        var x = previewFrame.minX
        var y = previewFrame.minY - sz.height - gap
        if y < vis.minY              { y = previewFrame.maxY + gap }
        if y + sz.height > vis.maxY  { y = max(vis.minY, vis.maxY - sz.height) }
        if x + sz.width  > vis.maxX  { x = vis.maxX - sz.width }
        if x < vis.minX              { x = vis.minX }
        win.setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true, animate: false)
    }

    func update(with state: OverlayState) {
        // statusLabel removed — size/position shown inline in fields
        content.lockButton.title    = state.isLocked ? "Unlock" : "Lock"
        content.lockButton.isActive = state.isLocked
        content.aspectButton.isActive = state.isAspectLocked
        content.mirrorButton.isActive = state.isMirrored

        // Enable/disable context-sensitive buttons
        content.resetAspectButton.isEnabled = !state.isAtNativeAspect
        content.resetButton.isEnabled       = !state.isAtDefaults

        let halfMinDim = min(state.previewSize.width, state.previewSize.height) / 2
        content.radiusSlider.maxValue        = halfMinDim
        content.radiusSlider.doubleValue     = min(Double(state.cornerRadius), halfMinDim)
        content.radiusStepper.maxValue       = halfMinDim
        content.radiusStepper.doubleValue    = min(Double(state.cornerRadius), halfMinDim)
        content.radiusField.stringValue      = (state.cornerRadius >= halfMinDim && halfMinDim > 0) ? "Full" : "\(Int(state.cornerRadius))"
        content.opacitySlider.floatValue     = state.opacity
        content.opacityField.stringValue     = "\(Int(state.opacity * 100))%"
        content.opacityStepper.doubleValue   = Double(Int(state.opacity * 100))
        content.widthField.doubleValue       = Double(state.previewSize.width)
        content.widthStepper.doubleValue     = Double(state.previewSize.width)
        content.heightField.doubleValue      = Double(state.previewSize.height)
        content.heightStepper.doubleValue    = Double(state.previewSize.height)
        content.xField.doubleValue           = Double(state.previewOrigin.x)
        content.xStepper.doubleValue         = Double(state.previewOrigin.x)
        content.yField.doubleValue           = Double(state.previewOrigin.y)
        content.yStepper.doubleValue         = Double(state.previewOrigin.y)
        content.edgeTopField.stringValue     = "\(Int(state.edgeTop))"
        content.edgeTopStepper.doubleValue   = Double(state.edgeTop)
        content.edgeRightField.stringValue   = "\(Int(state.edgeRight))"
        content.edgeRightStepper.doubleValue = Double(state.edgeRight)
        content.edgeBottomField.stringValue  = "\(Int(state.edgeBottom))"
        content.edgeBottomStepper.doubleValue = Double(state.edgeBottom)
        content.edgeLeftField.stringValue    = "\(Int(state.edgeLeft))"
        content.edgeLeftStepper.doubleValue  = Double(state.edgeLeft)
        content.hoverOpacityToggle.state      = state.hoverOpacityEnabled ? .on : .off
        content.hoverOpacitySlider.isEnabled  = state.hoverOpacityEnabled
        content.hoverOpacityField.isEnabled   = state.hoverOpacityEnabled
        content.hoverOpacityStepper.isEnabled = state.hoverOpacityEnabled
        content.hoverOpacitySlider.floatValue = state.hoverOpacity
        content.hoverOpacityField.stringValue = "\(Int(state.hoverOpacity * 100))%"
        content.hoverOpacityStepper.doubleValue = Double(Int(state.hoverOpacity * 100))
    }

    // MARK: Actions

    @objc private func tapLock()    { onToggleLock?() }
    @objc private func tapAspect()  { onToggleAspect?() }
    @objc private func tapReset()       { onReset?() }
    @objc private func tapResetAspect() { onResetAspect?() }
    @objc private func tapCenter()  { onCenter?() }
    @objc private func tapMirror()  { onToggleMirror?() }
    @objc private func tapHide()    { onHidePanel?() }

    @objc private func sliderRadius(_ s: NSSlider) {
        let v = CGFloat(s.doubleValue)
        content.radiusField.stringValue = "\(Int(v))"
        onSetRadius?(v)
    }

    @objc private func fieldRadius(_ f: NSTextField) {
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if raw == "full" || raw == "max" || raw == "∞" {
            content.radiusSlider.doubleValue = content.radiusSlider.maxValue
            f.stringValue = "Full"
            onSetRadius?(9999); return
        }
        guard let v = Double(raw), v.isFinite else { shakeView(f); return }
        let c = CGFloat(max(0, v))
        content.radiusSlider.doubleValue = min(Double(c), content.radiusSlider.maxValue)
        f.stringValue = "\(Int(c))"
        onSetRadius?(c)
    }

    @objc private func sliderOpacity(_ s: NSSlider) {
        content.opacityField.stringValue = "\(Int(s.floatValue * 100))%"
        onSetOpacity?(s.floatValue)
    }

    @objc private func fieldOpacity(_ f: NSTextField) {
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
        guard let v = Double(raw), v.isFinite else { shakeView(f); return }
        let c = Float(max(5, min(100, v))) / 100.0
        content.opacitySlider.floatValue = c
        f.stringValue = "\(Int(c * 100))%"
        onSetOpacity?(c)
    }

    @objc private func tapApplySize() {
        guard let w = parseField(content.widthField),
              let h = parseField(content.heightField) else { shakeView(content.widthField); return }
        onApplySize?(w, h)
    }

    @objc private func tapApplyPos() {
        guard let x = parseField(content.xField),
              let y = parseField(content.yField) else { shakeView(content.xField); return }
        onApplyPosition?(x, y)
    }
    @objc private func fieldX(_ f: NSTextField) {
        guard let x = parseField(f), let y = parseField(content.yField) else { return }
        onApplyPosition?(x, y)
    }
    @objc private func fieldY(_ f: NSTextField) {
        guard let x = parseField(content.xField), let y = parseField(f) else { return }
        onApplyPosition?(x, y)
    }

    @objc private func tapHoverOpacityToggle() { onToggleHoverOpacity?() }

    @objc private func sliderHoverOpacity(_ s: NSSlider) {
        content.hoverOpacityField.stringValue = "\(Int(s.floatValue * 100))%"
        onSetHoverOpacity?(s.floatValue)
    }

    @objc private func fieldHoverOpacity(_ f: NSTextField) {
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let v = Double(raw), v.isFinite else { shakeView(f); return }
        let c = Float(max(0, min(100, v))) / 100.0
        content.hoverOpacitySlider.floatValue = c
        f.stringValue = "\(Int(c * 100))%"
        onSetHoverOpacity?(c)
    }

    // MARK: Stepper actions

    @objc private func stepRadius(_ s: NSStepper) {
        let v = CGFloat(s.doubleValue)
        content.radiusField.stringValue = v >= content.radiusSlider.maxValue ? "Full" : "\(Int(v))"
        content.radiusSlider.doubleValue = s.doubleValue
        onSetRadius?(v)
    }
    @objc private func stepOpacity(_ s: NSStepper) {
        let v = Float(s.doubleValue) / 100.0
        content.opacityField.stringValue  = "\(Int(s.doubleValue))%"
        content.opacitySlider.floatValue  = v
        onSetOpacity?(v)
    }
    @objc private func stepHoverOpacity(_ s: NSStepper) {
        let v = Float(s.doubleValue) / 100.0
        content.hoverOpacityField.stringValue  = "\(Int(s.doubleValue))%"
        content.hoverOpacitySlider.floatValue  = v
        onSetHoverOpacity?(v)
    }
    @objc private func stepWidth(_ s: NSStepper) {
        let w = CGFloat(s.doubleValue)
        content.widthField.stringValue = "\(Int(w))"
        // Pass current height from the stepper; applySize handles aspect lock internally
        onApplySize?(w, CGFloat(content.heightStepper.doubleValue))
    }
    @objc private func stepHeight(_ s: NSStepper) {
        let h = CGFloat(s.doubleValue)
        content.heightField.stringValue = "\(Int(h))"
        // When aspect is locked the preview controller will enforce the ratio,
        // but we still pass the requested height so the user can unlock & use it.
        // Also tell the controller to derive width from this height so the W
        // field & stepper stay consistent (handled in applySize via onApplySize).
        onApplySize?(CGFloat(content.widthStepper.doubleValue), h)
    }
    @objc private func stepX(_ s: NSStepper) {
        content.xField.stringValue = "\(Int(s.doubleValue))"
        if let y = Double(content.yField.stringValue) { onApplyPosition?(CGFloat(s.doubleValue), CGFloat(y)) }
    }
    @objc private func stepY(_ s: NSStepper) {
        content.yField.stringValue = "\(Int(s.doubleValue))"
        if let x = Double(content.xField.stringValue) { onApplyPosition?(CGFloat(x), CGFloat(s.doubleValue)) }
    }
    @objc private func stepEdgeTop(_ s: NSStepper) {
        content.edgeTopField.stringValue = "\(Int(s.doubleValue))"
        onApplyMargin?("top", CGFloat(s.doubleValue))
    }
    @objc private func stepEdgeRight(_ s: NSStepper) {
        content.edgeRightField.stringValue = "\(Int(s.doubleValue))"
        onApplyMargin?("right", CGFloat(s.doubleValue))
    }
    @objc private func stepEdgeBottom(_ s: NSStepper) {
        content.edgeBottomField.stringValue = "\(Int(s.doubleValue))"
        onApplyMargin?("bottom", CGFloat(s.doubleValue))
    }
    @objc private func stepEdgeLeft(_ s: NSStepper) {
        content.edgeLeftField.stringValue = "\(Int(s.doubleValue))"
        onApplyMargin?("left", CGFloat(s.doubleValue))
    }

    @objc private func tapApplyMargins() {
        // Snapshot field values BEFORE any applyMargin call, because each call
        // triggers onStateChanged → update(with:) which overwrites the fields.
        let top    = parseField(content.edgeTopField)
        let right  = parseField(content.edgeRightField)
        let bottom = parseField(content.edgeBottomField)
        let left   = parseField(content.edgeLeftField)
        if let v = top    { onApplyMargin?("top",    v) }
        if let v = right  { onApplyMargin?("right",  v) }
        if let v = bottom { onApplyMargin?("bottom", v) }
        if let v = left   { onApplyMargin?("left",   v) }
    }

    @objc private func tapShortcuts() { onOpenShortcuts?() }
    @objc private func tapMoveToMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let corners: [(String, String)] = [("↖  Top Left","TL"),("↗  Top Right","TR"),
                                            ("↙  Bottom Left","BL"),("↘  Bottom Right","BR")]
        let allScreens   = NSScreen.screens
        // Find the screen the preview window is currently on; put it first.
        let currentScreen = (NSApp.delegate as? FloatingCameraScriptApp)?.previewScreen ?? NSScreen.main
        var ordered = allScreens
        if let ci = ordered.firstIndex(where: { $0 == currentScreen }) {
            ordered.swapAt(0, ci)
        }

        if ordered.count > 1 {
            for (li, screen) in ordered.enumerated() {
                let isCurrentLabel = (li == 0) ? " (current)" : ""
                let header = NSMenuItem(title: screen.localizedName + isCurrentLabel,
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                // Find the real index in NSScreen.screens for the token
                let si = allScreens.firstIndex(of: screen) ?? li
                for (title, corner) in corners {
                    let token = "\(corner):\(si)"
                    let item = NSMenuItem(title: "   \(title)",
                                          action: #selector(tapMoveToCorner(_:)), keyEquivalent: "")
                    item.representedObject = token; item.target = self
                    menu.addItem(item)
                }
                if li < ordered.count - 1 { menu.addItem(.separator()) }
            }
        } else {
            for (title, corner) in corners {
                let item = NSMenuItem(title: title, action: #selector(tapMoveToCorner(_:)), keyEquivalent: "")
                item.representedObject = corner; item.target = self
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func tapMoveToCorner(_ item: NSMenuItem) {
        guard let token = item.representedObject as? String else { return }
        onSnapCorner?(token)
    }

    @objc private func popupCamera(_ sender: NSPopUpButton) {
        guard let uid = sender.selectedItem?.representedObject as? String else { return }
        onSelectCamera?(uid)
    }

    private func parseField(_ f: NSTextField) -> CGFloat? {
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v.isFinite else { return nil }
        return CGFloat(v)
    }

    private func shakeView(_ v: NSView) {
        v.wantsLayer = true
        let a = CAKeyframeAnimation(keyPath: "position.x")
        let x = v.frame.midX
        a.values = [x - 5, x + 5, x - 4, x + 4, x - 2, x + 2, x]; a.duration = 0.25
        v.layer?.add(a, forKey: "shake")
    }
}

// MARK: - Chip Button

final class ChipButton: NSButton {

    var isActive: Bool = false { didSet { applyStyle() } }

    convenience init(label: String) { self.init(frame: .zero); title = label }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; wantsLayer = true
        layer?.cornerRadius = 6
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var title: String { didSet { applyStyle() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyStyle() }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isActive {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
                layer?.borderColor     = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
                layer?.borderWidth     = 1.0
            } else {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
                layer?.borderColor     = NSColor.separatorColor.cgColor
                layer?.borderWidth     = 0.5
            }
        }
        let color:  NSColor       = isActive ? .controlAccentColor : .labelColor
        let weight: NSFont.Weight = isActive ? .medium             : .regular
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font:            NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: weight),
            .foregroundColor: color
        ])
    }
}


// MARK: - Section Header Label

private func makeSectionHeader(_ title: String) -> NSTextField {
    let f = NSTextField(labelWithString: title.uppercased())
    f.font      = .systemFont(ofSize: 9.5, weight: .semibold)
    f.textColor = NSColor(white: 0.50, alpha: 1)
    return f
}

// MARK: - Control Panel Content View

final class ControlPanelContentView: NSView {

    // ── Camera ───────────────────────────────────────────────────────────────
    let cameraPopup      = NSPopUpButton()
    let shortcutsButton  = NSButton(title: "Shortcuts…", target: nil, action: nil)

    // ── Toggles ──────────────────────────────────────────────────────────────
    // Order: Lock | Mirror | Aspect | Reset Aspect | Reset
    let lockButton        = ChipButton(label: "Lock")
    let mirrorButton      = ChipButton(label: "Mirror")
    let aspectButton      = ChipButton(label: "Aspect")
    let resetAspectButton = ChipButton(label: "Reset Aspect")
    let resetButton       = ChipButton(label: "Reset")
    // centerButton kept for API compat but hidden (zero frame)
    let centerButton      = ChipButton(label: "Center")

    // ── Appearance ────────────────────────────────────────────────────────────
    let radiusLabel    = ControlPanelContentView.rowLabel("Radius")
    let radiusSlider   = NSSlider(value: 16, minValue: 0, maxValue: 500, target: nil, action: nil)
    let radiusField    = ControlPanelContentView.editField("16")
    let radiusStepper  = ControlPanelContentView.makeStepper(min: 0, max: 500, inc: 1)
    let opacityLabel   = ControlPanelContentView.rowLabel("Opacity")
    let opacitySlider  = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let opacityField   = ControlPanelContentView.editField("100%")
    let opacityStepper = ControlPanelContentView.makeStepper(min: 5, max: 100, inc: 1)
    let hoverOpacityToggle  = NSButton(checkboxWithTitle: "Locked hover opacity", target: nil, action: nil)
    let hoverOpacitySlider  = NSSlider(value: 0.15, minValue: 0, maxValue: 1, target: nil, action: nil)
    let hoverOpacityField   = ControlPanelContentView.editField("15%")
    let hoverOpacityStepper = ControlPanelContentView.makeStepper(min: 0, max: 100, inc: 1)

    // ── Position / Size ───────────────────────────────────────────────────────
    let sizeLabel       = ControlPanelContentView.rowLabel("Size")
    let widthField      = ControlPanelContentView.editField("540")
    let widthStepper    = ControlPanelContentView.makeStepper(min: 120,   max: 9999, inc: 1)
    let heightField     = ControlPanelContentView.editField("360")
    let heightStepper   = ControlPanelContentView.makeStepper(min: 90,    max: 9999, inc: 1)
    let applySizeButton = ControlPanelContentView.applyBtn()
    let positionLabel       = ControlPanelContentView.rowLabel("Position")
    let xField              = ControlPanelContentView.editField("0")
    let xStepper            = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let yField              = ControlPanelContentView.editField("0")
    let yStepper            = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let applyPositionButton = ControlPanelContentView.applyBtn()
    // "Move to…" corner popup
    // Plain button that pops up a menu — more reliable than pullsDown NSPopUpButton
    let moveToButton: NSButton = {
        let b = NSButton(title: "Move to…", target: nil, action: nil)
        b.bezelStyle = .rounded; b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }()

    // ── Margins ───────────────────────────────────────────────────────────────
    let marginsLabel       = ControlPanelContentView.rowLabel("Margins")
    let edgeTopField       = ControlPanelContentView.editField("—")
    let edgeTopStepper     = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let edgeRightField     = ControlPanelContentView.editField("—")
    let edgeRightStepper   = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let edgeBottomField    = ControlPanelContentView.editField("—")
    let edgeBottomStepper  = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let edgeLeftField      = ControlPanelContentView.editField("—")
    let edgeLeftStepper    = ControlPanelContentView.makeStepper(min: -9999, max: 9999, inc: 1)
    let applyMarginsButton = ControlPanelContentView.applyBtn()

    // ── Footer ────────────────────────────────────────────────────────────────
    let hidePanelButton = NSButton(title: "Hide Control Panel", target: nil, action: nil)
    let statusLabel     = NSTextField(labelWithString: " ")   // retired

    private var separators:   [Int: NSView]       = [:]
    private var inlineLabels: [Int: NSTextField]  = [:]
    private var sectionHeaders: [Int: NSTextField] = [:]

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Factories

    static func rowLabel(_ t: String) -> NSTextField {
        let f = NSTextField(labelWithString: t)
        f.font = .systemFont(ofSize: 11); f.textColor = .secondaryLabelColor
        f.alignment = .right; return f
    }
    static func editField(_ v: String) -> NSTextField {
        let f = NSTextField(); f.stringValue = v
        f.isEditable = true; f.isBezeled = true; f.drawsBackground = true
        f.alignment = .right; f.controlSize = .small
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); return f
    }
    static func applyBtn() -> NSButton {
        let b = NSButton(title: "Apply", target: nil, action: nil)
        b.bezelStyle = .rounded; b.controlSize = .small
        b.font = .systemFont(ofSize: 11); return b
    }
    static func displayField(_ v: String) -> NSTextField {
        let f = NSTextField(); f.stringValue = v
        f.isEditable = false; f.isBezeled = false; f.drawsBackground = false
        f.alignment = .center; f.controlSize = .small
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor; return f
    }
    static func makeStepper(min: Double, max: Double, inc: Double) -> NSStepper {
        let s = NSStepper()
        s.minValue = min; s.maxValue = max; s.increment = inc
        s.controlSize = .small; s.autorepeat = true; s.valueWraps = false
        return s
    }
    func stepperBindings(target: AnyObject) -> [(NSStepper, NSTextField, Selector)] { return [] }

    // MARK: Setup

    private func setup() {
        // Layer-backed rendering: critical for correct slider rendering when the
        // window moves between screens with different backing scale factors.
        wantsLayer = true
        cameraPopup.controlSize = .small; cameraPopup.font = .systemFont(ofSize: 12)
        cameraPopup.pullsDown = false

        shortcutsButton.bezelStyle = .rounded; shortcutsButton.controlSize = .small
        shortcutsButton.font = .systemFont(ofSize: 11)

        // Use default (regular) control size for sliders — .small can glitch
        // on external screens when backing scale factor differs from main screen.
        radiusSlider.numberOfTickMarks     = 0
        opacitySlider.numberOfTickMarks    = 0
        hoverOpacitySlider.numberOfTickMarks = 0
        hoverOpacityToggle.font = .systemFont(ofSize: 11)


        for st in [radiusStepper, opacityStepper, hoverOpacityStepper,
                   widthStepper, heightStepper, xStepper, yStepper,
                   edgeTopStepper, edgeRightStepper, edgeBottomStepper, edgeLeftStepper] {
            st.controlSize = .small
        }

        hidePanelButton.bezelStyle = .rounded; hidePanelButton.controlSize = .small
        hidePanelButton.font = .systemFont(ofSize: 11)

        statusLabel.frame = .zero

        let all: [NSView] = [
            cameraPopup, shortcutsButton,
            lockButton, mirrorButton, aspectButton, resetAspectButton, resetButton, centerButton,
            radiusLabel, radiusSlider, radiusField, radiusStepper,
            opacityLabel, opacitySlider, opacityField, opacityStepper,
            hoverOpacityToggle, hoverOpacitySlider, hoverOpacityField, hoverOpacityStepper,
            sizeLabel, widthField, widthStepper, heightField, heightStepper, applySizeButton,
            positionLabel, xField, xStepper, yField, yStepper, applyPositionButton,
            moveToButton,
            marginsLabel, edgeTopField, edgeTopStepper, edgeRightField, edgeRightStepper,
            edgeBottomField, edgeBottomStepper, edgeLeftField, edgeLeftStepper, applyMarginsButton,
            hidePanelButton, statusLabel
        ]
        all.forEach { addSubview($0) }
    }

    // MARK: Layout
    //
    // Visual design targets the FineTune / macOS-modern aesthetic:
    //   • Dark background (#212121)
    //   • Rows have subtle rounded-rect inset panels (row backgrounds)
    //   • Section headers in small-caps secondary color
    //   • Thin sliders, compact controls
    //   • All controls vertically centred in their row

    override func layout() {
        super.layout()

        let W   = bounds.width
        let L: CGFloat  = 14     // left margin
        let R: CGFloat  = 14     // right margin
        let rH: CGFloat = 26     // row height
        let lbH: CGFloat = 13    // label height
        let fH: CGFloat  = 18    // field height
        let slH: CGFloat = 18    // slider height — regular size renders correctly across screens
        let stW: CGFloat = 15    // stepper width
        let stH: CGFloat = 21    // stepper height
        let bsH: CGFloat = 20    // small button height
        let fW: CGFloat  = 52    // numeric field width
        let lW: CGFloat  = 54    // row-label column
        let sp: CGFloat  = 8     // label gap
        let sliderRightX = W - R - fW - stW - 4
        let sliderW      = sliderRightX - 6 - (L + lW + sp)

        var y = bounds.height - 12

        // ── Camera row ───────────────────────────────────────────────────────
        y -= rH
        let shortBW: CGFloat = 82
        cameraPopup.frame     = CGRect(x: L,                    y: y + (rH - 20) / 2,
                                        width: W - L - R - shortBW - 6, height: 20)
        shortcutsButton.frame = CGRect(x: W - R - shortBW,      y: y + (rH - bsH) / 2,
                                        width: shortBW,           height: bsH)

        y -= 6; sep(1, y: &y, l: L, w: W - L - R); y -= 7

        // ── Toggles: Lock | Mirror | Aspect | Reset Aspect | Reset ──────────
        y -= rH
        let bGap: CGFloat = 4
        let bW = ((W - L - R) - bGap * 4) / 5
        for (i, btn) in [lockButton, mirrorButton, aspectButton, resetAspectButton, resetButton].enumerated() {
            btn.frame = CGRect(x: L + CGFloat(i) * (bW + bGap), y: y + (rH - bsH) / 2,
                               width: bW, height: bsH)
        }
        centerButton.frame = .zero   // hidden — functionality removed from panel

        y -= 6; sep(2, y: &y, l: L, w: W - L - R); y -= 7

        // ── Radius ───────────────────────────────────────────────────────────
        y -= rH
        radiusLabel.frame   = CGRect(x: L,              y: y + (rH - lbH) / 2, width: lW,      height: lbH)
        radiusSlider.frame  = CGRect(x: L + lW + sp,    y: y + (rH - slH) / 2, width: sliderW, height: slH)
        radiusField.frame   = CGRect(x: sliderRightX,   y: y + (rH - fH)  / 2, width: fW,      height: fH)
        radiusStepper.frame = CGRect(x: sliderRightX + fW + 2, y: y + (rH - stH) / 2, width: stW, height: stH)

        y -= 5
        // ── Opacity ──────────────────────────────────────────────────────────
        y -= rH
        opacityLabel.frame   = CGRect(x: L,              y: y + (rH - lbH) / 2, width: lW,      height: lbH)
        opacitySlider.frame  = CGRect(x: L + lW + sp,    y: y + (rH - slH) / 2, width: sliderW, height: slH)
        opacityField.frame   = CGRect(x: sliderRightX,   y: y + (rH - fH)  / 2, width: fW,      height: fH)
        opacityStepper.frame = CGRect(x: sliderRightX + fW + 2, y: y + (rH - stH) / 2, width: stW, height: stH)

        y -= 5
        // ── Locked hover opacity ─────────────────────────────────────────────
        y -= rH
        let togH: CGFloat = 15
        hoverOpacityToggle.frame  = CGRect(x: L,              y: y + (rH - togH) / 2, width: lW + sp - 2, height: togH)
        hoverOpacitySlider.frame  = CGRect(x: L + lW + sp,    y: y + (rH - slH) / 2, width: sliderW,     height: slH)
        hoverOpacityField.frame   = CGRect(x: sliderRightX,   y: y + (rH - fH)  / 2, width: fW,          height: fH)
        hoverOpacityStepper.frame = CGRect(x: sliderRightX + fW + 2, y: y + (rH - stH) / 2, width: stW, height: stH)

        y -= 6; sep(3, y: &y, l: L, w: W - L - R); y -= 7

        // ── Size  ────────────────────────────────────────────────────────────
        y -= rH
        let mLbW: CGFloat = 16
        let sepCW: CGFloat = 10
        let apBW: CGFloat  = 44
        let geomW = W - L - R - lW - sp - apBW - 6
        let sfW = min(72, (geomW - 2 * mLbW - 2 * stW - sepCW - 18) / 2)
        let lblGap: CGFloat = 6
        sizeLabel.frame = CGRect(x: L, y: y + (rH - lbH) / 2, width: lW, height: lbH)
        let sLbX = L + lW + sp
        inlinePunct("W", tag: 30).frame = CGRect(x: sLbX,                    y: y + (rH - lbH) / 2, width: mLbW, height: lbH)
        widthField.frame   = CGRect(x: sLbX + mLbW + lblGap,                 y: y + (rH - fH)  / 2, width: sfW,  height: fH)
        widthStepper.frame = CGRect(x: sLbX + mLbW + lblGap + sfW + 2,       y: y + (rH - stH) / 2, width: stW,  height: stH)
        let sxX = sLbX + mLbW + lblGap + sfW + stW + 4
        inlinePunct("×", tag: 10).frame = CGRect(x: sxX, y: y + (rH - lbH) / 2, width: sepCW, height: lbH)
        let sLbX2 = sxX + sepCW + 2
        inlinePunct("H", tag: 31).frame = CGRect(x: sLbX2,                   y: y + (rH - lbH) / 2, width: mLbW, height: lbH)
        heightField.frame   = CGRect(x: sLbX2 + mLbW + lblGap,               y: y + (rH - fH)  / 2, width: sfW,  height: fH)
        heightStepper.frame = CGRect(x: sLbX2 + mLbW + lblGap + sfW + 2,     y: y + (rH - stH) / 2, width: stW,  height: stH)
        applySizeButton.frame = CGRect(x: W - R - apBW, y: y + (rH - bsH) / 2, width: apBW, height: bsH)

        y -= 5
        // ── Position  —  X [f][st] · Y [f][st]   [Move to…] ─────────────────
        // X/Y fields use the same sfW as W/H. Move to… button is 76pt (narrower).
        // applyPositionButton hidden; position updates on Enter key press.
        y -= rH
        positionLabel.frame = CGRect(x: L, y: y + (rH - lbH) / 2, width: lW, height: lbH)
        let pLbX = L + lW + sp
        inlinePunct("X", tag: 32).frame = CGRect(x: pLbX,                    y: y + (rH - lbH) / 2, width: mLbW, height: lbH)
        xField.frame   = CGRect(x: pLbX + mLbW + lblGap,                     y: y + (rH - fH)  / 2, width: sfW,  height: fH)
        xStepper.frame = CGRect(x: pLbX + mLbW + lblGap + sfW + 2,           y: y + (rH - stH) / 2, width: stW,  height: stH)
        let pxX = pLbX + mLbW + lblGap + sfW + stW + 4
        inlinePunct("·", tag: 11).frame = CGRect(x: pxX, y: y + (rH - lbH) / 2, width: sepCW, height: lbH)
        let pLbX2 = pxX + sepCW + 2
        inlinePunct("Y", tag: 33).frame = CGRect(x: pLbX2,                   y: y + (rH - lbH) / 2, width: mLbW, height: lbH)
        yField.frame   = CGRect(x: pLbX2 + mLbW + lblGap,                    y: y + (rH - fH)  / 2, width: sfW,  height: fH)
        yStepper.frame = CGRect(x: pLbX2 + mLbW + lblGap + sfW + 2,          y: y + (rH - stH) / 2, width: stW,  height: stH)
        let moveBtnW: CGFloat = 76
        applyPositionButton.frame = .zero   // hidden; use Enter key
        moveToButton.frame = CGRect(x: W - R - moveBtnW, y: y + (rH - bsH) / 2, width: moveBtnW, height: bsH)

        y -= 7; sep(4, y: &y, l: L, w: W - L - R); y -= 7

        // ── Margins ───────────────────────────────────────────────────────────
        y -= rH
        marginsLabel.frame = CGRect(x: L, y: y + (rH - lbH) / 2, width: lW, height: lbH)
        let mfAvail = W - L - R - lW - sp - apBW - 6
        let mfUnit  = (mfAvail - 3 * 3) / 4
        let mfFW    = mfUnit - stW - 2
        let mHints  = ["T", "R", "B", "L"]
        let mFields:   [NSTextField] = [edgeTopField,    edgeRightField,  edgeBottomField, edgeLeftField]
        let mSteppers: [NSStepper]   = [edgeTopStepper,  edgeRightStepper, edgeBottomStepper, edgeLeftStepper]
        for i in 0..<4 {
            let bx = L + lW + sp + CGFloat(i) * (mfUnit + 3)
            mFields[i].frame   = CGRect(x: bx,             y: y + (rH - fH)  / 2, width: mfFW, height: fH)
            mSteppers[i].frame = CGRect(x: bx + mfFW + 2,  y: y + (rH - stH) / 2, width: stW, height: stH)
            inlinePunct(mHints[i], tag: 20 + i).frame = CGRect(x: bx, y: y - 12, width: mfUnit, height: 11)
        }
        applyMarginsButton.frame = CGRect(x: W - R - apBW, y: y + (rH - bsH) / 2, width: apBW, height: bsH)

        y -= 18
        sep(5, y: &y, l: L, w: W - L - R); y -= 8

        // ── Hide Panel button — equal spacing top and bottom ─────────────────
        // sep5_bottom ≈ 38, btn_h=22 → btn_y=(38-22)/2=8 → 8pt above and below
        let hW: CGFloat = 154
        hidePanelButton.frame = CGRect(x: (W - hW) / 2, y: 16, width: hW, height: 22)

        statusLabel.frame = .zero
    }

    // MARK: Helpers

    private func sep(_ tag: Int, y: inout CGFloat, l: CGFloat, w: CGFloat) {
        y -= 1
        if separators[tag] == nil {
            let b = NSBox(); b.boxType = .separator; addSubview(b); separators[tag] = b
        }
        separators[tag]!.frame = CGRect(x: l, y: y, width: w, height: 1)
    }

    private func inlinePunct(_ text: String, tag: Int) -> NSTextField {
        if let l = inlineLabels[tag] { return l }
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        l.alignment = .center; addSubview(l); inlineLabels[tag] = l; return l
    }
}

// MARK: - Shortcuts Window Controller

final class ShortcutsWindowController: NSWindowController, NSWindowDelegate {

    private weak var app: FloatingCameraScriptApp?
    private var capturingFor: String?   // "camera" | "panel"
    private var localMonitor: Any?

    // ── UI ────────────────────────────────────────────────────────────────────
    private let cameraRow = ShortcutRowView(label: "Show / Hide Camera")
    private let panelRow  = ShortcutRowView(label: "Show / Hide Control Panel")
    private let hintLabel = NSTextField(labelWithString: "Click a shortcut field, then press a combination. Esc cancels.")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(app: FloatingCameraScriptApp) {
        self.app = app
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 116),
            styleMask:   [.titled, .closable],
            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title              = "Shortcuts"
        panel.delegate           = self
        panel.isFloatingPanel    = true
        panel.level              = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate  = false
        panel.appearance       = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .windowBackgroundColor
        buildUI()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        hintLabel.font       = .systemFont(ofSize: 11)
        hintLabel.textColor  = .secondaryLabelColor
        hintLabel.isBezeled  = false; hintLabel.drawsBackground = false
        hintLabel.isEditable = false; hintLabel.isSelectable   = false

        doneButton.bezelStyle    = .rounded
        doneButton.controlSize   = .regular
        doneButton.font          = .systemFont(ofSize: 13)
        doneButton.keyEquivalent = "\r"
        doneButton.target = self; doneButton.action = #selector(tapDone)

        cameraRow.onTapField = { [weak self] in self?.startCapturing(for: "camera") }
        cameraRow.onClear    = { [weak self] in self?.clearShortcut(for: "camera") }
        panelRow.onTapField  = { [weak self] in self?.startCapturing(for: "panel") }
        panelRow.onClear     = { [weak self] in self?.clearShortcut(for: "panel") }

        [cameraRow, panelRow, hintLabel, doneButton].forEach { cv.addSubview($0) }
        layoutViews()
    }

    private func layoutViews() {
        guard let cv = window?.contentView else { return }
        let W = cv.bounds.width; let L: CGFloat = 16; let R: CGFloat = 16
        // Two columns side-by-side
        let colGap: CGFloat = 12
        let colW = (W - L - R - colGap) / 2
        let rowH: CGFloat = 44
        let topY = cv.bounds.height - 14 - rowH
        cameraRow.frame = CGRect(x: L,                 y: topY, width: colW, height: rowH)
        panelRow.frame  = CGRect(x: L + colW + colGap, y: topY, width: colW, height: rowH)

        // Hint + Done: 4pt gap between them, both pinned near the bottom
        let hintH: CGFloat = 13; let doneH: CGFloat = 22; let gap: CGFloat = 8
        hintLabel.frame  = CGRect(x: L, y: 8 + doneH + gap, width: W - L - R, height: hintH)
        // Done button flush against the right margin, 8pt from bottom
        let dbW: CGFloat = 64
        doneButton.frame = CGRect(x: W - R - dbW, y: 8, width: dbW, height: doneH)
    }

    // MARK: Data

    func refresh() {
        let d = UserDefaults.standard
        let camCode = d.object(forKey: Pref.cameraHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyCode)) : Pref.defaultCameraCode
        let camMods = d.object(forKey: Pref.cameraHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.cameraHotkeyMods)) : Pref.defaultCameraMods
        let panCode = d.object(forKey: Pref.panelHotkeyCode) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyCode)) : Pref.defaultPanelCode
        let panMods = d.object(forKey: Pref.panelHotkeyMods) != nil
            ? UInt32(d.integer(forKey: Pref.panelHotkeyMods)) : Pref.defaultPanelMods
        cameraRow.setShortcut(camCode > 0 ? Self.formatShortcut(code: camCode, mods: camMods) : nil)
        panelRow.setShortcut(panCode  > 0 ? Self.formatShortcut(code: panCode,  mods: panMods)  : nil)
    }

    // MARK: Capture

    private func startCapturing(for target: String) {
        // Stop any prior capture session
        stopCapturing()
        capturingFor = target
        let row = (target == "camera") ? cameraRow : panelRow
        row.setCapturing(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event); return nil
        }
    }

    private func stopCapturing() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        cameraRow.setCapturing(false)
        panelRow.setCapturing(false)
        capturingFor = nil
    }

    private func handleKey(_ event: NSEvent) {
        guard let target = capturingFor else { return }
        if event.keyCode == UInt16(kVK_Escape) { stopCapturing(); refresh(); return }
        let code = UInt32(event.keyCode)
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
        guard mods > 0 else { return }   // require at least one modifier
        let d = UserDefaults.standard
        d.set(Int(code), forKey: target == "camera" ? Pref.cameraHotkeyCode : Pref.panelHotkeyCode)
        d.set(Int(mods), forKey: target == "camera" ? Pref.cameraHotkeyMods : Pref.panelHotkeyMods)
        stopCapturing()
        refresh()
        app?.reregisterHotKeys()
    }

    private func clearShortcut(for target: String) {
        stopCapturing()
        let d = UserDefaults.standard
        d.set(0, forKey: target == "camera" ? Pref.cameraHotkeyCode : Pref.panelHotkeyCode)
        d.set(0, forKey: target == "camera" ? Pref.cameraHotkeyMods : Pref.panelHotkeyMods)
        refresh()
        app?.reregisterHotKeys()
    }

    // MARK: Actions

    @objc private func tapDone() { stopCapturing(); window?.orderOut(nil) }
    func windowWillClose(_ n: Notification) { stopCapturing() }

    // MARK: Formatting

    static func formatShortcut(code: UInt32, mods: UInt32) -> String {
        var r = ""
        if mods & UInt32(controlKey) != 0 { r += "⌃" }
        if mods & UInt32(optionKey)  != 0 { r += "⌥" }
        if mods & UInt32(shiftKey)   != 0 { r += "⇧" }
        if mods & UInt32(cmdKey)     != 0 { r += "⌘" }
        r += keyCodeString(code)
        return r
    }

    private static func keyCodeString(_ c: UInt32) -> String {
        let m: [UInt32: String] = [
            UInt32(kVK_ANSI_A):"A",UInt32(kVK_ANSI_B):"B",UInt32(kVK_ANSI_C):"C",
            UInt32(kVK_ANSI_D):"D",UInt32(kVK_ANSI_E):"E",UInt32(kVK_ANSI_F):"F",
            UInt32(kVK_ANSI_G):"G",UInt32(kVK_ANSI_H):"H",UInt32(kVK_ANSI_I):"I",
            UInt32(kVK_ANSI_J):"J",UInt32(kVK_ANSI_K):"K",UInt32(kVK_ANSI_L):"L",
            UInt32(kVK_ANSI_M):"M",UInt32(kVK_ANSI_N):"N",UInt32(kVK_ANSI_O):"O",
            UInt32(kVK_ANSI_P):"P",UInt32(kVK_ANSI_Q):"Q",UInt32(kVK_ANSI_R):"R",
            UInt32(kVK_ANSI_S):"S",UInt32(kVK_ANSI_T):"T",UInt32(kVK_ANSI_U):"U",
            UInt32(kVK_ANSI_V):"V",UInt32(kVK_ANSI_W):"W",UInt32(kVK_ANSI_X):"X",
            UInt32(kVK_ANSI_Y):"Y",UInt32(kVK_ANSI_Z):"Z",
            UInt32(kVK_ANSI_0):"0",UInt32(kVK_ANSI_1):"1",UInt32(kVK_ANSI_2):"2",
            UInt32(kVK_ANSI_3):"3",UInt32(kVK_ANSI_4):"4",UInt32(kVK_ANSI_5):"5",
            UInt32(kVK_ANSI_6):"6",UInt32(kVK_ANSI_7):"7",UInt32(kVK_ANSI_8):"8",
            UInt32(kVK_ANSI_9):"9",
            UInt32(kVK_Space):"Space",UInt32(kVK_Return):"Return",
            UInt32(kVK_Tab):"Tab",UInt32(kVK_Delete):"⌫",
            UInt32(kVK_F1):"F1",UInt32(kVK_F2):"F2",UInt32(kVK_F3):"F3",
            UInt32(kVK_F4):"F4",UInt32(kVK_F5):"F5",UInt32(kVK_F6):"F6",
            UInt32(kVK_F7):"F7",UInt32(kVK_F8):"F8",UInt32(kVK_F9):"F9",
            UInt32(kVK_F10):"F10",UInt32(kVK_F11):"F11",UInt32(kVK_F12):"F12",
        ]
        return m[c] ?? "?"
    }
}

// MARK: - Shortcut Row View

/// A single labelled row: "Show / Hide Camera   [⌃⌥H]  [Clear]"
/// Styled to match the Camera Controls utility panel.
final class ShortcutRowView: NSView {

    var onTapField: (() -> Void)?
    var onClear:    (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let badge = NSButton(title: "Not set", target: nil, action: nil)
    private let clear = NSButton(title: "Clear",   target: nil, action: nil)

    init(label text: String) {
        super.init(frame: .zero)
        label.stringValue    = text
        label.font           = .systemFont(ofSize: 11, weight: .regular)
        label.textColor      = .labelColor
        label.isBezeled      = false; label.drawsBackground = false
        label.isEditable     = false; label.isSelectable    = false

        badge.bezelStyle    = .rounded
        badge.controlSize   = .small
        badge.font          = .monospacedSystemFont(ofSize: 13, weight: .medium)
        badge.target        = self; badge.action = #selector(tapBadge)

        clear.bezelStyle    = .rounded
        clear.controlSize   = .small
        clear.font          = .systemFont(ofSize: 11)
        clear.target        = self; clear.action = #selector(tapClear)

        [label, badge, clear].forEach { addSubview($0) }
        applyStyle(capturing: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setShortcut(_ text: String?) {
        badge.title = text ?? "Not set"
    }

    func setCapturing(_ on: Bool) {
        applyStyle(capturing: on)
        if on { badge.title = "Press keys…" }
    }

    private func applyStyle(capturing: Bool) {
        if capturing {
            badge.wantsLayer = true
            badge.layer?.borderWidth = 1.5
            badge.layer?.borderColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 5
            badge.contentTintColor = .controlAccentColor
        } else {
            badge.wantsLayer = true
            badge.layer?.borderWidth = 0
            badge.contentTintColor = .labelColor
        }
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        let lH: CGFloat = 14; let bH: CGFloat = 20; let clrW: CGFloat = 44; let bW: CGFloat = 90
        label.frame = CGRect(x: 0, y: bounds.height - lH - 2, width: W,      height: lH)
        badge.frame = CGRect(x: 0, y: 0,                       width: bW,     height: bH)
        clear.frame = CGRect(x: bW + 8, y: 0,                  width: clrW,   height: bH)
    }

    @objc private func tapBadge() { onTapField?() }
    @objc private func tapClear() { onClear?() }
}

// MARK: - Bootstrap

let app      = NSApplication.shared
let delegate = FloatingCameraScriptApp()
app.delegate = delegate
app.run()
