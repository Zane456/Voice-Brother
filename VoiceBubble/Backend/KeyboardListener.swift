import CoreGraphics
import Foundation
import QuartzCore

/// Global keyboard listener using CGEventTap.
///
/// Key design: the CGEventTap callback must return quickly, otherwise macOS disables the tap.
/// Therefore, the callback only sets flags and signals; heavy work (on_release, on_meeting_toggle)
/// is dispatched to a background thread via the run loop iteration check.
final class KeyboardListener {

    // MARK: - Callbacks

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let onReposition: () -> Void
    private let onMeetingToggle: () -> Void

    // MARK: - State

    private var triggerKey: CGKeyCode
    private var flagMask: CGEventFlags
    private var pressed = false
    private var spaceSwallowed = false
    private var meetingActive = false

    // Both-Command hold detection (hold both Cmd keys for 0.5s to toggle meeting)
    private var cmdLPressed = false
    private var cmdRPressed = false
    private var bothCmdStartTime: TimeInterval = 0
    private var meetingTriggeredWhileHeld = false

    // Delayed voice recording start (prevents conflict with meeting gesture)
    private var pressPendingTime: TimeInterval = 0
    private let pressDelay: TimeInterval = 0.15

    // Event signaling
    private var releasePending = false
    private var cancelPending = false
    private var meetingTogglePending = false

    // CGEventTap resources
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var listenerThread: Thread?
    private var stopped = false

    // MARK: - Init

    init(
        triggerKey: CGKeyCode,
        flagMask: CGEventFlags,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onReposition: @escaping () -> Void,
        onMeetingToggle: @escaping () -> Void
    ) {
        self.triggerKey = triggerKey
        self.flagMask = flagMask
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onReposition = onReposition
        self.onMeetingToggle = onMeetingToggle
    }

    // MARK: - Public API

    func start() {
        stopped = false
        pressed = false
        releasePending = false
        cancelPending = false
        meetingTogglePending = false
        cmdLPressed = false
        cmdRPressed = false
        bothCmdStartTime = 0
        meetingTriggeredWhileHeld = false
        pressPendingTime = 0

        let thread = Thread { [weak self] in
            self?.runEventListener()
        }
        thread.name = "KeyboardListener"
        thread.qualityOfService = .userInteractive
        listenerThread = thread
        thread.start()
    }

    func stop() {
        stopped = true
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
        }
        listenerThread = nil
    }

    func updateTriggerKey(_ keyCode: CGKeyCode, flagMask: CGEventFlags) {
        self.triggerKey = keyCode
        self.flagMask = flagMask
    }

    /// When true, single-key press/release callbacks are suppressed.
    var isMeetingActive: Bool {
        get { meetingActive }
        set { meetingActive = newValue }
    }

    // MARK: - Run Loop (background thread)

    private func runEventListener() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[KeyboardListener] Failed to create event tap. Accessibility permission required.")
            return
        }

        self.eventTap = tap
        self.runLoop = CFRunLoopGetCurrent()

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        while !stopped {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)

            let now = CACurrentMediaTime()

            // Delayed voice recording start:
            // Wait 0.15s before starting — if both Commands are pressed in that window,
            // cancel the pending start (it's a meeting gesture, not voice recording).
            if pressPendingTime > 0 {
                if cmdLPressed && cmdRPressed {
                    // Both commands pressed — cancel pending voice recording
                    pressPendingTime = 0
                } else if now - pressPendingTime >= pressDelay {
                    // Delay elapsed, no second command — start voice recording
                    pressPendingTime = 0
                    pressed = true
                    let callback = onPress
                    DispatchQueue.global(qos: .userInitiated).async {
                        callback()
                    }
                }
            }

            // Check if both Command keys have been held for 0.5 seconds
            if bothCmdStartTime > 0 && !meetingTriggeredWhileHeld {
                let elapsed = now - bothCmdStartTime
                if elapsed >= 0.5 {
                    meetingTriggeredWhileHeld = true
                    meetingTogglePending = true
                }
            }

            if cancelPending {
                cancelPending = false
                let callback = onCancel
                DispatchQueue.global(qos: .userInitiated).async {
                    callback()
                }
            }

            if releasePending {
                releasePending = false
                let callback = onRelease
                DispatchQueue.global(qos: .userInitiated).async {
                    callback()
                }
            }

            if meetingTogglePending {
                meetingTogglePending = false
                let callback = onMeetingToggle
                DispatchQueue.global(qos: .userInitiated).async {
                    callback()
                }
            }
        }

        // Cleanup
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = runLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        self.runLoop = nil
    }

    // MARK: - CGEventTap Callback

    private static let keyboardCallback: CGEventTapCallBack = { proxy, eventType, event, refcon -> Unmanaged<CGEvent>? in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let listener = Unmanaged<KeyboardListener>.fromOpaque(refcon).takeUnretainedValue()
        return listener.handleEvent(eventType: eventType, event: event)
    }

    private func handleEvent(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // ESC key cancels recording
        if eventType == .keyDown && keycode == 0x35 { // ESC
            if pressed {
                pressed = false
                pressPendingTime = 0
                cancelPending = true
                return nil // swallow ESC
            }
            return Unmanaged.passRetained(event)
        }

        // Space key handling during recording
        if eventType == .keyDown || eventType == .keyUp {
            if pressed && keycode == 0x31 { // space
                if eventType == .keyDown {
                    if meetingActive {
                        return Unmanaged.passRetained(event)
                    }
                    onReposition()
                    spaceSwallowed = true
                    return nil
                } else if eventType == .keyUp && spaceSwallowed {
                    spaceSwallowed = false
                    return nil
                }
            }
            return Unmanaged.passRetained(event)
        }

        // Modifier key state changes (flagsChanged)
        let flags = event.flags

        if keycode == 0x36 || keycode == 0x37 { // cmd_r or cmd_l
            // Use device-specific flags to distinguish left vs right Command.
            // Generic .maskCommand can't tell which key changed — causes stale state bugs.
            // NX_DEVICELCMDKEYMASK = 0x08, NX_DEVICERCMDKEYMASK = 0x10
            if keycode == 0x36 {
                cmdRPressed = flags.rawValue & 0x10 != 0
            } else {
                cmdLPressed = flags.rawValue & 0x08 != 0
            }

            // Track when both Command keys are held simultaneously
            if cmdLPressed && cmdRPressed {
                if bothCmdStartTime == 0 {
                    bothCmdStartTime = CACurrentMediaTime()
                    meetingTriggeredWhileHeld = false
                }
                // Cancel any pending or active voice recording
                pressPendingTime = 0
                if pressed {
                    pressed = false
                    releasePending = true
                }
            } else {
                bothCmdStartTime = 0
                meetingTriggeredWhileHeld = false
            }

            // Meeting active → suppress single-key events (but dual-command detection above still runs)
            if meetingActive {
                return Unmanaged.passRetained(event)
            }

            // Single trigger key handling (voice recording)
            if keycode == triggerKey && !(cmdLPressed && cmdRPressed) {
                // Use device-specific flag to check if THIS key is pressed
                let isPressed: Bool
                if triggerKey == 0x36 {
                    isPressed = flags.rawValue & 0x10 != 0  // right Command
                } else {
                    isPressed = flags.rawValue & 0x08 != 0  // left Command
                }

                if isPressed && !pressed && pressPendingTime == 0 {
                    // Don't start recording immediately — delay to distinguish from meeting gesture
                    pressPendingTime = CACurrentMediaTime()
                } else if !isPressed {
                    if pressPendingTime > 0 {
                        // Key released before delay elapsed — discard (too short to be useful)
                        pressPendingTime = 0
                    } else if pressed {
                        // Normal release — stop recording and transcribe
                        pressed = false
                        releasePending = true
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}
