import Foundation
import IOKit
import IOKit.usb

extension Notification.Name {
    static let usbDeviceConnected = Notification.Name("usbDeviceConnected")
    static let usbDeviceDisconnected = Notification.Name("usbDeviceDisconnected")
}

/// Monitors USB device connections and disconnections using IOKit.
///
/// When a USB device is plugged in whose name matches a profile's configured
/// `usbDeviceName`, the corresponding profile's trigger fires. Likewise for
/// disconnections.
class USBMonitor {
    static let shared = USBMonitor()

    /// The set of USB device names currently connected. Updated on every
    /// add/remove event. Thread-safe -- only mutated on the main queue.
    private(set) var connectedDeviceNames: Set<String> = []

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var isMonitoring = false

    private init() {}

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Take a snapshot of currently connected USB devices so we only fire
        // triggers for NEW connections, not devices already plugged in at
        // launch.
        connectedDeviceNames = currentUSBDeviceNames()
        print("[OBScene] USB monitor started. Currently connected: \(connectedDeviceNames)")

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else {
            print("[OBScene] Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            print("[OBScene] Failed to create USB matching dictionary")
            return
        }

        // Register for USB device added notifications
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchingDict as CFDictionary,
            usbDeviceAddedCallback,
            selfPtr,
            &addedIterator
        )

        if addResult != KERN_SUCCESS {
            print("[OBScene] Failed to register for USB add notifications: \(addResult)")
        }

        // Drain the initial iterator -- IOKit requires us to iterate existing
        // matches before notifications start flowing. We already snapshot'd
        // connectedDeviceNames above so we don't fire triggers for these.
        drainIterator(addedIterator)

        // Re-create the matching dict for removal (IOKit consumes it).
        guard let removalMatchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            print("[OBScene] Failed to create USB removal matching dictionary")
            return
        }

        let removeResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            removalMatchingDict as CFDictionary,
            usbDeviceRemovedCallback,
            selfPtr,
            &removedIterator
        )

        if removeResult != KERN_SUCCESS {
            print("[OBScene] Failed to register for USB removal notifications: \(removeResult)")
        }

        // Drain the initial removal iterator too.
        drainIterator(removedIterator)
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    /// Returns the set of USB device product names currently connected.
    private func currentUSBDeviceNames() -> Set<String> {
        var names = Set<String>()
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else { return names }
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return names }

        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let name = deviceName(for: device) {
                names.insert(name)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return names
    }

    /// Extract the product name from an IOService device.
    private func deviceName(for device: io_service_t) -> String? {
        // Try USB Product Name first, fall back to IORegistry name.
        if let productName = IORegistryEntryCreateCFProperty(
            device,
            "USB Product Name" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !productName.isEmpty {
            return productName
        }

        var name = [CChar](repeating: 0, count: 256)
        let kr = IORegistryEntryGetName(device, &name)
        if kr == KERN_SUCCESS {
            let ioName = String(cString: name)
            if ioName != "IOUSBHostDevice" && !ioName.isEmpty {
                return ioName
            }
        }
        return nil
    }

    /// Drain an iterator without doing anything -- required by IOKit after
    /// registering a notification so that future events are delivered.
    private func drainIterator(_ iterator: io_iterator_t) {
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
    }

    // MARK: - IOKit Callbacks

    /// Called by IOKit when a USB device is added. Rescans the connected set
    /// and posts a notification for any newly-appeared device names.
    fileprivate func handleDeviceAdded(iterator: io_iterator_t) {
        var newNames = Set<String>()

        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let name = deviceName(for: device) {
                newNames.insert(name)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        let previousNames = connectedDeviceNames
        connectedDeviceNames = connectedDeviceNames.union(newNames)

        let addedNames = newNames.subtracting(previousNames)
        for name in addedNames {
            print("[OBScene] USB device connected: \(name)")
            ActivityLog.shared.log(.usbDeviceConnected, "USB device connected: \(name)")
            NotificationCenter.default.post(
                name: .usbDeviceConnected,
                object: nil,
                userInfo: ["deviceName": name]
            )
        }
    }

    /// Called by IOKit when a USB device is removed. Rescans the connected set
    /// and posts a notification for any disappeared device names.
    fileprivate func handleDeviceRemoved(iterator: io_iterator_t) {
        // We need to drain the iterator to keep receiving notifications.
        var device = IOIteratorNext(iterator)
        while device != 0 {
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        // Re-scan to get the accurate current state, because the removed
        // iterator may not give us names reliably for terminated services.
        let currentNames = currentUSBDeviceNames()
        let disappeared = connectedDeviceNames.subtracting(currentNames)
        connectedDeviceNames = currentNames

        for name in disappeared {
            print("[OBScene] USB device disconnected: \(name)")
            ActivityLog.shared.log(.usbDeviceDisconnected, "USB device disconnected: \(name)")
            NotificationCenter.default.post(
                name: .usbDeviceDisconnected,
                object: nil,
                userInfo: ["deviceName": name]
            )
        }
    }
}

// MARK: - C-compatible callbacks

/// IOKit callback for device addition. Bridged to the USBMonitor instance via
/// the refCon pointer.
private func usbDeviceAddedCallback(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else { return }
    let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.handleDeviceAdded(iterator: iterator)
    }
}

/// IOKit callback for device removal.
private func usbDeviceRemovedCallback(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else { return }
    let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.handleDeviceRemoved(iterator: iterator)
    }
}
