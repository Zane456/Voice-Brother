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
    /// Optional mouse button (3, 4, …) for mouse-side-button triggers. When set,
    /// the listener watches `.otherMouseDown` / `.otherMouseUp` for this button
    /// instead of (or in addition to) the keyboard trigger.
    private var triggerMouseButton: Int?
    private var pressed = false
    private var spaceSwallowed = false
    /// Written from MainActor (MeetingService), read from CGEventTap background
    /// thread. Must be accessed via `isMeetingActive` to route through the lock.
    private var _meetingActive = false
    private let stateLock = NSLock()

    // Both-Command hold detection (hold both Cmd keys for 0.5s to toggle meeting)
    private var cmdLPressed = false
    private var cmdRPressed = false
    private var bothCmdStartTime: TimeInterval = 0
    private var meetingTriggeredWhileHeld = false

    // Delayed voice recording start (prevents conflict with double-Command meeting gesture).
    // Only Cmd triggers can collide with the dual-Cmd gesture; Option/Control/Shift have
    // no equivalent ambiguity, so they fire on the next run-loop tick (~25–50ms).
    // Cmd_R/Cmd_L use 80ms — measurable real-world double-Cmd presses land within 30–60ms
    // of each other, so 80ms still wins the intentional gesture while being snappier than
    // the original 150ms. This 70ms savings matters most for Bluetooth (AirPods) where
    // every millisecond before the SCO link starts warming = a millisecond of speech the
    // user has to delay or risk losing.
    private var pressPendingTime: TimeInterval = 0
    private var pressDelay: TimeInterval {
        // Cmd_R = 0x36, Cmd_L = 0x37
        return (triggerKey == 0x36 || triggerKey == 0x37) ? 0.08 : 0.0
    }

    // Event signaling. Release is dispatched directly from the CGEventTap
    // callback (see handleEvent) so it no longer goes through the polling
    // tick — only cancel and meeting-toggle still need the run-loop hop.
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
        triggerMouseButton: Int? = nil,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onReposition: @escaping () -> Void,
        onMeetingToggle: @escaping () -> Void
    ) {
        self.triggerKey = triggerKey
        self.flagMask = flagMask
        self.triggerMouseButton = triggerMouseButton
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
        // Reset transient press state so a stop()-then-start() (e.g. user
        // changes trigger key while holding a mouse side button or modifier)
        // doesn't leave us with `pressed = true` baked in. Without this, the
        // next genuine button-down would be a no-op (we treat it as "already
        // pressed") and the user has to release+press twice to recover.
        pressed = false
        spaceSwallowed = false
        pressPendingTime = 0
        cmdLPressed = false
        cmdRPressed = false
        bothCmdStartTime = 0
        meetingTriggeredWhileHeld = false
        cancelPending = false
        meetingTogglePending = false
        if let runLoop = runLoop {
            CFRunLoopStop(runLoop)
        }
        listenerThread = nil
    }

    func updateTriggerKey(_ keyCode: CGKeyCode, flagMask: CGEventFlags, mouseButton: Int? = nil) {
        self.triggerKey = keyCode
        self.flagMask = flagMask
        self.triggerMouseButton = mouseButton
    }

    /// When true, single-key press/release callbacks are suppressed.
    /// Crosses the MainActor ↔ CGEventTap thread boundary, so serialize via lock.
    var isMeetingActive: Bool {
        get { stateLock.withLock { _meetingActive } }
        set { stateLock.withLock { _meetingActive = newValue } }
    }

    // MARK: - Run Loop (background thread)

    private func runEventListener() {
        // Always include mouse events — the user may switch to a mouse-button
        // trigger at runtime via `updateTriggerKey`, and re-creating the tap
        // would require tearing down the run loop. Cost of extra events is
        // negligible since handleEvent fast-paths anything that isn't our
        // configured button.
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Tap creation fails when Accessibility permission is missing or
            // was revoked. The listener thread exits here — the hotkey looks
            // configured in Settings but silently does nothing. Permission
            // Manager surfaces the missing permission separately; this log
            // makes the tap-side failure itself diagnosable.
            DebugLog.write("[KeyboardListener] Failed to create event tap — Accessibility permission missing or revoked")
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
                    ASRLogger.shared.event(.meetingGestureDetected,
                                           props: ["hold_ms": Int(elapsed * 1000)])
                }
            }

            if cancelPending {
                cancelPending = false
                let callback = onCancel
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

        // Mouse-side-button trigger. Mouse buttons give us explicit down/up events
        // (no flagsChanged-style ambiguity), so we don't need the 80ms dual-Cmd
        // delay — fire press/release immediately. We swallow the event when it
        // matches our configured button so the system's default back/forward
        // navigation doesn't double-fire while the user is recording.
        if eventType == .otherMouseDown || eventType == .otherMouseUp {
            guard let myButton = triggerMouseButton, !isMeetingActive else {
                return Unmanaged.passRetained(event)
            }
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard buttonNumber == myButton else {
                return Unmanaged.passRetained(event)
            }
            // Disruptive modifier guard: if the user is holding any modifier
            // (Cmd/Shift/Option/Control) when they click the side button,
            // they're probably triggering an OS-level shortcut (Cmd+back-button
            // is a common power-user gesture), not voice input. Mirror the
            // keyboard-trigger UX: don't start, and cancel any in-flight
            // recording. We let the event through so the OS shortcut still works.
            let mouseModifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
            let hasModifier = !event.flags.intersection(mouseModifiers).isEmpty
            if hasModifier {
                if pressed {
                    pressed = false
                    cancelPending = true
                }
                return Unmanaged.passRetained(event)
            }
            if eventType == .otherMouseDown {
                if !pressed {
                    pressed = true
                    let callback = onPress
                    DispatchQueue.global(qos: .userInitiated).async {
                        callback()
                    }
                }
            } else {  // .otherMouseUp
                if pressed {
                    pressed = false
                    // Direct dispatch (mirrors the press path above) — bypasses
                    // the 50 ms run-loop tick so the overlay hides the instant
                    // the user releases the button.
                    let callback = onRelease
                    DispatchQueue.global(qos: .userInitiated).async {
                        callback()
                    }
                }
            }
            return nil  // swallow so back/forward navigation doesn't fire
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
                    if isMeetingActive {
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

        // Detect any *disruptive* modifier held right now — i.e. a modifier that
        // isn't itself the user's configured trigger. If the user picks ⌘ as
        // the trigger, Shift/Option/Control are disruptive; if they pick ⌥,
        // only Shift/Control are. Without this subtraction, picking Option as
        // the trigger would instantly cancel itself because maskAlternate
        // matches the "other modifier" set.
        var disruptiveMask: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
        disruptiveMask.subtract(flagMask)
        let hasOtherModifier = !flags.intersection(disruptiveMask).isEmpty

        // If a non-Command modifier just appeared during a pending / active
        // recording, tear it down immediately. Covers: user presses ⌘ first,
        // then ⇧4 a beat later.
        if hasOtherModifier {
            if pressPendingTime > 0 {
                pressPendingTime = 0
            }
            if pressed {
                pressed = false
                cancelPending = true
            }
        }

        // Non-Command modifier trigger (Shift 0x38/0x3C, Option 0x3A/0x3D, Control 0x3B/0x3E).
        // Only the keycode chosen by the user in settings is treated as a trigger —
        // e.g. selecting "Left Option" will NOT fire on Right Option. We still rely
        // on the modifier flag bit to tell press from release, since flagsChanged
        // doesn't carry an explicit up/down marker.
        let isNonCmdModifierKeycode = (keycode == 0x38 || keycode == 0x3C   // shift L/R
                                    || keycode == 0x3A || keycode == 0x3D   // option L/R
                                    || keycode == 0x3B || keycode == 0x3E)  // control L/R
        if isNonCmdModifierKeycode && Int64(triggerKey) == keycode && !isMeetingActive {
            let isPressed = flags.contains(flagMask)
            if isPressed && !pressed && pressPendingTime == 0 && !hasOtherModifier {
                pressPendingTime = CACurrentMediaTime()
            } else if !isPressed {
                if pressPendingTime > 0 {
                    pressPendingTime = 0
                } else if pressed {
                    pressed = false
                    // Direct dispatch — bypass the 50 ms run-loop tick so the
                    // overlay hides the instant the modifier is released.
                    let callback = onRelease
                    DispatchQueue.global(qos: .userInitiated).async {
                        callback()
                    }
                }
            }
            return Unmanaged.passRetained(event)
        }

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
                    // Direct dispatch — see other release sites.
                    let callback = onRelease
                    DispatchQueue.global(qos: .userInitiated).async {
                        callback()
                    }
                }
            } else {
                bothCmdStartTime = 0
                meetingTriggeredWhileHeld = false
            }

            // Meeting active → suppress single-key events (but dual-command detection above still runs)
            if isMeetingActive {
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

                if isPressed && !pressed && pressPendingTime == 0 && !hasOtherModifier {
                    // Don't start recording immediately — delay to distinguish from meeting gesture
                    // and from modifier-heavy shortcuts like ⌘⇧4.
                    pressPendingTime = CACurrentMediaTime()
                } else if !isPressed {
                    if pressPendingTime > 0 {
                        // Key released before delay elapsed — discard (too short to be useful)
                        pressPendingTime = 0
                    } else if pressed {
                        // Normal release — stop recording and transcribe.
                        // Direct dispatch from the CGEventTap callback bypasses
                        // the 50 ms run-loop polling tick, so the overlay starts
                        // hiding the instant the user lifts the key.
                        pressed = false
                        let callback = onRelease
                        DispatchQueue.global(qos: .userInitiated).async {
                            callback()
                        }
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}
