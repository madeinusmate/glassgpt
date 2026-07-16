import Foundation

enum StreamRecoveryAction: Equatable {
    case updateGlassesDATApp
    case updateGlassesFirmware
    case grantCameraPermission
    case powerCycleGlasses
}
