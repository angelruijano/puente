import CoreAudio
import AudioToolbox
import Foundation

/// Volumen del sistema (salida por defecto), 0–100. Avisa cuando cambia desde el Mac.
final class SystemVolume {
    var onChange: ((Int) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private let listenQueue = DispatchQueue.main

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var mainVolume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        self.onChange?(self.level)
    }
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.attach()
        if let self { self.onChange?(self.level) }
    }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput,
                                            listenQueue, deviceChanged)
        attach()
    }

    private func attach() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.mainVolume, listenQueue, changed)
            AudioObjectRemovePropertyListenerBlock(device, &Self.mute, listenQueue, changed)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        device = id
        AudioObjectAddPropertyListenerBlock(device, &Self.mainVolume, listenQueue, changed)
        AudioObjectAddPropertyListenerBlock(device, &Self.mute, listenQueue, changed)
    }

    /// Nivel efectivo: 0 si está silenciado.
    var level: Int {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.mainVolume, 0, nil, &size, &v) == noErr else { return 0 }
        var m = UInt32(0), ms = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &ms, &m) == noErr, m != 0 { return 0 }
        return Int((v * 100).rounded())
    }

    var settable: Bool {
        var s = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &Self.mainVolume, &s) == noErr && s.boolValue
    }

    func set(_ level: Int) {
        var v = Float32(max(0, min(100, level))) / 100
        AudioObjectSetPropertyData(device, &Self.mainVolume, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        var m = UInt32(v == 0 ? 1 : 0)
        if AudioObjectHasProperty(device, &Self.mute) {
            AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}
