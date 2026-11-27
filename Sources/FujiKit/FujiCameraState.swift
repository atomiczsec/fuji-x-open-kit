public enum FujiCameraState: UInt32, Sendable {
    case waitingForAccess = 0
    case multipleTransfer = 1
    case fullAccess = 2
    case pcAutoSave = 3
    case remoteAccess = 6
}
