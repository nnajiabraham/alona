import AudioToolbox
import Foundation

// MARK: - Constants

extension AudioObjectID {
    /// Convenience for `kAudioObjectSystemObject`.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Convenience for `kAudioObjectUnknown`.
    static let unknown = kAudioObjectUnknown

    /// `true` if this object has the value of `kAudioObjectUnknown`.
    var isUnknown: Bool { self == .unknown }

    /// `false` if this object has the value of `kAudioObjectUnknown`.
    var isValid: Bool { !self.isUnknown }
}

// MARK: - Concrete Property Helpers

extension AudioObjectID {
    /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`.
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioDeviceID.system.readDefaultSystemOutputDevice()
    }

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readProcessList()
    }

    /// Reads `kAudioHardwarePropertyTranslatePIDToProcessObject` for the specific pid.
    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try AudioDeviceID.system.translatePIDToProcessObjectID(pid: pid)
    }

    /// Reads `kAudioHardwarePropertyProcessObjectList`.
    func readProcessList() throws -> [AudioObjectID] {
        try self.requireSystemObject()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)

        guard err == noErr else { throw CoreAudioError.propertyError("Error reading data size for \(address): \(err)") }

        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)

        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)

        guard err == noErr else { throw CoreAudioError.propertyError("Error reading array for \(address): \(err)") }

        return value
    }

    /// Reads `kAudioHardwarePropertyTranslatePIDToProcessObject` for the specific pid.
    func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        try self.requireSystemObject()

        let processObject = try read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid)

        guard processObject.isValid else {
            throw CoreAudioError.invalidProcess("Invalid process identifier: \(pid)")
        }

        return processObject
    }

    func readProcessBundleID() -> String? {
        if let result = try? readString(kAudioProcessPropertyBundleID) {
            result.isEmpty ? nil : result
        } else {
            nil
        }
    }

    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    func readProcessIsRunningInput() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunningInput)) ?? false
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`.
    func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try self.requireSystemObject()

        return try read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads the value for `kAudioDevicePropertyDeviceUID` for the device represented by this audio object ID.
    func readDeviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }

    /// Reads the value for `kAudioTapPropertyFormat` for the device represented by this audio object ID.
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    private func requireSystemObject() throws {
        if self != .system { throw CoreAudioError.systemObjectRequired("Only supported for the system object.") }
    }
}

// MARK: - Generic Property Access

extension AudioObjectID {
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        qualifier: some Any) throws -> T
    {
        try self.read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: defaultValue,
            qualifier: qualifier)
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T) throws -> T
    {
        try self.read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: defaultValue)
    }

    func read<T, Q>(_ address: AudioObjectPropertyAddress, defaultValue: T, qualifier: Q) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { qualifierPtr in
            try self.read(
                address,
                defaultValue: defaultValue,
                inQualifierSize: qualifierSize,
                inQualifierData: qualifierPtr)
        }
    }

    func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
        try self.read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String
    {
        try self.read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: "" as CFString) as String
    }

    func readBool(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> Bool
    {
        let value: Int = try read(
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
            defaultValue: 0)
        return value == 1
    }

    private func read<T>(
        _ inAddress: AudioObjectPropertyAddress,
        defaultValue: T,
        inQualifierSize: UInt32 = 0,
        inQualifierData: UnsafeRawPointer? = nil) throws -> T
    {
        var address = inAddress

        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, inQualifierSize, inQualifierData, &dataSize)

        guard err == noErr else {
            throw CoreAudioError.propertyError("Error reading data size for \(inAddress): \(err)")
        }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
        }

        guard err == noErr else {
            throw CoreAudioError.propertyError("Error reading data for \(inAddress): \(err)")
        }

        return value
    }
}

// MARK: - Errors

enum CoreAudioError: LocalizedError {
    case propertyError(String)
    case invalidProcess(String)
    case systemObjectRequired(String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .propertyError(msg): msg
        case let .invalidProcess(msg): msg
        case let .systemObjectRequired(msg): msg
        case let .tapCreationFailed(status): "Process tap creation failed with error \(status)"
        case let .aggregateDeviceFailed(status): "Failed to create aggregate device: \(status)"
        case let .deviceStartFailed(status): "Failed to start audio device: \(status)"
        case let .ioProcCreationFailed(status): "Failed to create device I/O proc: \(status)"
        }
    }
}
