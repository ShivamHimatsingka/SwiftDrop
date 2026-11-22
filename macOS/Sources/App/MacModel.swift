import Foundation
import IOKit.ps

enum MacModel {
    /// LocalSend shows this string under the device name on the other side.
    static let name: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        if model.lowercased().contains("macbook") { return "MacBook" }
        if hasInternalBattery { return "MacBook" }
        if model.lowercased().contains("imac") { return "iMac" }
        return "Mac"
    }()

    private static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for ps in list {
            if let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }
}

