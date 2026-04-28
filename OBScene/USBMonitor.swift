import Foundation
import IOKit
import IOKit.usb
import DiskArbitration

extension Notification.Name {
    static let usbDeviceConnected = Notification.Name("usbDeviceConnected")
    static let usbDeviceDisconnected = Notification.Name("usbDeviceDisconnected")
    /// Emitted when DiskArbitration resolves volume labels for a device that
    /// was already announced via `.usbDeviceConnected` (which fires at IOKit
    /// first-match, often before the filesystem is mounted). Subscribers MUST
    /// match on `volumeLabels` only — not `deviceName` — to avoid
    /// double-firing profiles that already matched by hardware name.
    static let usbDeviceVolumeLabelsResolved = Notification.Name("usbDeviceVolumeLabelsResolved")
}

/// Metadata for a currently-connected USB device, used by the Settings picker.
struct USBDeviceInfo: Hashable, Identifiable {
    let name: String
    let vendorName: String?
    let vendorID: UInt?
    let productID: UInt?
    /// IOKit locationID (if available). Stable per-port identifier used as a
    /// cache key in `USBMonitor` so disconnect handlers can look up the
    /// volume labels of a disk that has already been unmounted.
    let locationID: UInt?
    /// Volume labels (as set by the user in Finder/Disk Utility) for any
    /// filesystems on this USB device. A single USB may expose zero, one, or
    /// multiple mounted volumes. These are the human-recognisable names
    /// ("Public", "Backup", …) as opposed to the generic USB firmware
    /// descriptor in `name` (e.g. "USB Flash Disk").
    let volumeLabels: [String]

    var id: String {
        // Include locationID so identical devices on different ports don't
        // collapse into one SwiftUI row or one currentUSBDevices() entry.
        if let locationID {
            return "\(name)|\(vendorID ?? 0)|\(productID ?? 0)|\(locationID)"
        }
        // Fall back to vendor/product IDs when IOKit doesn't expose a port key.
        return "\(name)|\(vendorID ?? 0)|\(productID ?? 0)"
    }

    /// Human-readable label for the picker.
    /// Prefers the volume label(s) the user actually chose in Finder, falling
    /// back to the generic USB firmware descriptor plus vendor.
    var displayLabel: String {
        if !volumeLabels.isEmpty {
            let labels = volumeLabels.joined(separator: ", ")
            // Show e.g. "Public (USB Flash Disk)" so the user can still see
            // the hardware identity if it helps them disambiguate.
            return "\(labels) (\(name))"
        }
        if let vendor = vendorName, !vendor.isEmpty {
            return "\(name) — \(vendor)"
        }
        return name
    }

    /// All strings a user-typed "custom name" may legitimately match against.
    /// Used by the trigger matcher to fire on either hardware name or volume
    /// label (case-insensitive substring match).
    var matchableNames: [String] { [name] + volumeLabels }
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

    /// Source of truth for USB presence. Names are not unique, so connect and
    /// disconnect detection must use the same per-port key as the info cache.
    private var connectedDeviceKeys: Set<String> = []

    /// Cache of full `USBDeviceInfo` keyed by a stable identifier (locationID
    /// when available, else name+vendor+product). Populated on connect so that
    /// disconnect handlers can recover the user-visible volume labels AFTER
    /// the disk has already been unmounted (DiskArbitration can no longer
    /// resolve them at that point).
    private var deviceInfoCache: [String: USBDeviceInfo] = [:]

    /// Cache keys for which we've already posted a
    /// `.usbDeviceVolumeLabelsResolved` follow-up notification. Cleared only
    /// on disconnect for that key. Prevents duplicate "labels resolved" posts
    /// when the cache happens to already contain labels at retry time (e.g.
    /// because they resolved between first-match and the first retry fire).
    private var volumeLabelsResolvedKeys: Set<String> = []

    private var notifyPort: IONotificationPortRef?
    private var notificationRunLoopSource: CFRunLoopSource?
    private var notificationRunLoop: CFRunLoop?
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
        // launch. Also seed the deviceInfo cache so the picker + any immediate
        // disconnect event can see full metadata.
        deviceInfoCache.removeAll()
        connectedDeviceKeys.removeAll()
        volumeLabelsResolvedKeys.removeAll()

        let initialDevices = currentUSBDevices()
        connectedDeviceNames = Set(initialDevices.map { $0.name })
        for info in initialDevices {
            let key = Self.cacheKey(for: info)
            connectedDeviceKeys.insert(key)
            deviceInfoCache[key] = info
            // Devices already mounted at launch don't need a labels-resolved
            // follow-up — mark them so no retry ever reposts.
            if !info.volumeLabels.isEmpty {
                volumeLabelsResolvedKeys.insert(key)
            }
        }
        print("[OBScene] USB monitor started. Currently connected: \(connectedDeviceNames)")

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else {
            print("[OBScene] Failed to create IONotificationPort")
            isMonitoring = false
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        notificationRunLoopSource = runLoopSource
        notificationRunLoop = runLoop

        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            print("[OBScene] Failed to create USB matching dictionary")
            stopMonitoring()
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
            stopMonitoring()
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

        if let source = notificationRunLoopSource {
            CFRunLoopRemoveSource(notificationRunLoop ?? CFRunLoopGetMain(), source, .commonModes)
            notificationRunLoopSource = nil
            notificationRunLoop = nil
        }
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
        for info in currentUSBDevices() {
            names.insert(info.name)
        }
        return names
    }

    /// Returns the full metadata for every USB device currently connected.
    /// Exposed publicly so the Settings UI can render a picker of available
    /// devices without standing up its own IOKit enumerator.
    ///
    /// The list is de-duplicated on the same per-port cache key used by the
    /// monitor, then sorted by display label so repeat calls return a stable
    /// order for SwiftUI.
    func currentUSBDevices() -> [USBDeviceInfo] {
        var devices: [USBDeviceInfo] = []
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) else { return devices }
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return devices }

        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let info = deviceInfo(for: device) {
                devices.append(info)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        // De-dup on per-port key so same-name/same-model devices remain
        // separate when IOKit gives us a locationID.
        var seen = Set<String>()
        let unique = devices.filter { seen.insert(Self.cacheKey(for: $0)).inserted }
        return unique.sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
    }

    /// Full IOKit-sourced metadata for a single device node, enriched with any
    /// mounted-volume labels discovered via DiskArbitration.
    private func deviceInfo(for device: io_service_t) -> USBDeviceInfo? {
        guard let name = deviceName(for: device) else { return nil }

        let vendorName = IORegistryEntryCreateCFProperty(
            device,
            "USB Vendor Name" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String

        let vendorID = (IORegistryEntryCreateCFProperty(
            device,
            "idVendor" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber)?.uintValue

        let productID = (IORegistryEntryCreateCFProperty(
            device,
            "idProduct" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber)?.uintValue

        let locationID = (IORegistryEntryCreateCFProperty(
            device,
            "locationID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber)?.uintValue

        let volumeLabels = Self.volumeLabels(forUSBDevice: device)

        return USBDeviceInfo(
            name: name,
            vendorName: vendorName?.isEmpty == true ? nil : vendorName,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            volumeLabels: volumeLabels
        )
    }

    /// Stable cache key — prefers locationID (per-port unique) and falls back
    /// to the USBDeviceInfo.id when locationID is unavailable.
    fileprivate static func cacheKey(for info: USBDeviceInfo) -> String {
        if let loc = info.locationID {
            return "loc:\(loc)"
        }
        return "id:\(info.id)"
    }

    /// Walk the IOService children of a USB device looking for IOMedia nodes,
    /// then use DiskArbitration to read their user-visible volume name. Returns
    /// a de-duplicated, stable-ordered list.
    private static func volumeLabels(forUSBDevice device: io_service_t) -> [String] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }

        var bsdNames: [String] = []
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            device,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &childIterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(childIterator) }

        var child = IOIteratorNext(childIterator)
        while child != 0 {
            if IOObjectConformsTo(child, "IOMedia") != 0 {
                if let bsd = IORegistryEntryCreateCFProperty(
                    child,
                    "BSD Name" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String {
                    bsdNames.append(bsd)
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIterator)
        }

        var labels: [String] = []
        var seen = Set<String>()
        for bsd in bsdNames {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let desc = DADiskCopyDescription(disk) as? [String: Any]
            else { continue }
            if let name = desc[kDADiskDescriptionVolumeNameKey as String] as? String,
               !name.isEmpty,
               seen.insert(name).inserted {
                labels.append(name)
            }
        }
        return labels
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
    /// and posts a notification for any newly-appeared device names. Also
    /// updates the `deviceInfoCache` with the full metadata so the matching
    /// disconnect event (which fires after DiskArbitration has already
    /// un-mounted the volume) can still recover the user-visible labels.
    fileprivate func handleDeviceAdded(iterator: io_iterator_t) {
        var newInfos: [USBDeviceInfo] = []

        var device = IOIteratorNext(iterator)
        while device != 0 {
            if let info = deviceInfo(for: device) {
                newInfos.append(info)
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        let previousKeys = connectedDeviceKeys

        // Update cache and key set before posting; duplicate hardware names
        // are still distinct devices when their per-port key is new.
        var addedInfos: [USBDeviceInfo] = []
        var addedKeys = Set<String>()
        for info in newInfos {
            let key = Self.cacheKey(for: info)
            if !previousKeys.contains(key), addedKeys.insert(key).inserted {
                addedInfos.append(info)
            }
            connectedDeviceKeys.insert(key)
            connectedDeviceNames.insert(info.name)
            deviceInfoCache[key] = info
        }

        for info in addedInfos {
            let key = Self.cacheKey(for: info)
            print("[OBScene] USB device connected: \(info.name) volumeLabels=\(info.volumeLabels)")
            ActivityLog.shared.log(.usbDeviceConnected, "USB device connected: \(info.name)")
            NotificationCenter.default.post(
                name: .usbDeviceConnected,
                object: nil,
                userInfo: [
                    "deviceName": info.name,
                    "volumeLabels": info.volumeLabels,
                    "deviceKey": key
                ]
            )

            if !info.volumeLabels.isEmpty {
                // Labels were resolved synchronously — no follow-up needed.
                volumeLabelsResolvedKeys.insert(key)
            } else {
                // USB mass-storage devices finish their IOMedia →
                // DiskArbitration mount sequence asynchronously, so volume
                // labels may still be empty at first-match time. Schedule a
                // short bounded retry loop to refresh the cache and post a
                // supplementary `.usbDeviceVolumeLabelsResolved` notification
                // once the filesystem finishes coming up. AppDelegate matches
                // that notification ONLY against volume labels, so profiles
                // that already matched by hardware name are not re-fired.
                scheduleVolumeLabelRefresh(for: key,
                                            deviceName: info.name,
                                            attempt: 1)
            }
        }
    }

    /// Retry delays (ms) for DiskArbitration volume-label resolution. Must
    /// cover BOTH the fast path (IOMedia → DA mount in <1s for a freshly
    /// plugged stick on an awake Mac) AND the slow path where the Mac is
    /// waking from sleep with the device still plugged in: the kernel
    /// re-enumerates USB, IOSCSIBlockCommandsDevice re-probes the medium
    /// (`MODE_SENSE_06` retries), and DiskArbitration only dispatches its
    /// mount-approval callback once SCSI finishes — observed at ~7s on a
    /// T6000 after a ~20min sleep.
    ///
    /// The old 2.85s-total schedule gave up well before DA mounted, so
    /// profiles that match on *volume label* (e.g. "Public") never fired on
    /// wake-from-sleep. Extend the tail out to ~30s so volume labels have
    /// time to resolve even on slow USB 2 sticks with sluggish SCSI probes.
    /// Cumulative timeline: 0.15, 0.55, 1.35, 2.85, 5.35, 8.35, 12.35,
    /// 17.35, 23.35, 30.35 seconds after first-match.
    private static let volumeLabelRefreshDelaysMs: [Int] = [
        150, 400, 800, 1500, 2500, 3000, 4000, 5000, 6000, 7000
    ]

    /// Re-enumerate USB devices looking for the one whose cache key we
    /// captured earlier, and if volume labels have now appeared, update the
    /// cache and post a `.usbDeviceVolumeLabelsResolved` follow-up so
    /// label-only matchers see the labels. No-op if the device is gone, we've
    /// already reposted for this key, or labels still haven't resolved after
    /// the final attempt.
    private func scheduleVolumeLabelRefresh(for cacheKey: String,
                                            deviceName: String,
                                            attempt: Int) {
        let delays = Self.volumeLabelRefreshDelaysMs
        guard attempt >= 1, attempt <= delays.count else { return }
        let delayMs = delays[attempt - 1]

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self = self else { return }
            // Device still plugged in?
            guard self.connectedDeviceKeys.contains(cacheKey) else { return }
            // Already posted a labels-resolved follow-up for this key?
            // Use a dedicated set rather than inspecting the cache labels,
            // because another code path (e.g. handleDeviceRemoved's survivor
            // refresh) may have updated the cache concurrently.
            guard !self.volumeLabelsResolvedKeys.contains(cacheKey) else { return }

            // Re-enumerate and find the same key.
            let refreshed = self.currentUSBDevices().first { Self.cacheKey(for: $0) == cacheKey }
            guard let refreshed = refreshed else { return }
            self.deviceInfoCache[cacheKey] = refreshed

            if !refreshed.volumeLabels.isEmpty {
                self.volumeLabelsResolvedKeys.insert(cacheKey)
                print("[OBScene] USB device '\(deviceName)' volumeLabels resolved on attempt \(attempt): \(refreshed.volumeLabels)")
                NotificationCenter.default.post(
                    name: .usbDeviceVolumeLabelsResolved,
                    object: nil,
                    userInfo: [
                        "deviceName": refreshed.name,
                        "volumeLabels": refreshed.volumeLabels,
                        "deviceKey": cacheKey
                    ]
                )
            } else if attempt < delays.count {
                self.scheduleVolumeLabelRefresh(for: cacheKey,
                                                deviceName: deviceName,
                                                attempt: attempt + 1)
            }
        }
    }

    /// Called by IOKit when a USB device is removed. Rescans the connected set
    /// and posts a notification for any disappeared device names. Volume
    /// labels are looked up from the pre-disconnect cache because the
    /// DiskArbitration session can no longer see the already-unmounted
    /// filesystem at this point.
    fileprivate func handleDeviceRemoved(iterator: io_iterator_t) {
        // We need to drain the iterator to keep receiving notifications.
        var device = IOIteratorNext(iterator)
        while device != 0 {
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        // Re-scan to get the accurate current state, because the removed
        // iterator may not give us names reliably for terminated services.
        let previousNames = connectedDeviceNames
        let previousKeys = connectedDeviceKeys
        let survivors = currentUSBDevices()
        let survivorKeys = Set(survivors.map { Self.cacheKey(for: $0) })
        let disappearedKeys = previousKeys.subtracting(survivorKeys)

        connectedDeviceKeys = survivorKeys
        connectedDeviceNames = Set(survivors.map { $0.name })

        // Refresh survivor cache entries so a same-name sibling that remains
        // plugged in does not get mistaken for the removed device.
        for info in survivors {
            deviceInfoCache[Self.cacheKey(for: info)] = info
        }

        var notifiedNames = Set<String>()
        for key in disappearedKeys.sorted() {
            guard let info = deviceInfoCache[key] else { continue }
            print("[OBScene] USB device disconnected: \(info.name) volumeLabels=\(info.volumeLabels)")
            ActivityLog.shared.log(.usbDeviceDisconnected, "USB device disconnected: \(info.name)")
            NotificationCenter.default.post(
                name: .usbDeviceDisconnected,
                object: nil,
                userInfo: [
                    "deviceName": info.name,
                    "volumeLabels": info.volumeLabels,
                    "deviceKey": key
                ]
            )
            notifiedNames.insert(info.name)
            deviceInfoCache.removeValue(forKey: key)
            volumeLabelsResolvedKeys.remove(key)
        }

        // Fallback: any name that disappeared but had no cached entry (e.g.
        // because cache seeding missed it) still deserves a notification.
        // Use a synthetic deviceKey (name-based) so AppDelegate's fired-profile
        // bookkeeping can still key off of it, though without vendor/product
        // disambiguation it may be imprecise for duplicate-named devices.
        let disappeared = previousNames.subtracting(connectedDeviceNames)
        for name in disappeared where !notifiedNames.contains(name) {
            print("[OBScene] USB device disconnected (no cache): \(name)")
            ActivityLog.shared.log(.usbDeviceDisconnected, "USB device disconnected: \(name)")
            NotificationCenter.default.post(
                name: .usbDeviceDisconnected,
                object: nil,
                userInfo: [
                    "deviceName": name,
                    "volumeLabels": [String](),
                    "deviceKey": "name:\(name)"
                ]
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
