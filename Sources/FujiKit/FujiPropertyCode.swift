public enum FujiPropertyCode: UInt16, Sendable {
    case eventsList = 0xd212
    case cameraState = 0xdf00
    case clientState = 0xdf01
    case imageGetVersion = 0xdf21
    case getObjectVersion = 0xdf22
    case autoSaveVersion = 0xdf23
    case remoteVersion = 0xdf24
    case remoteGetObjectVersion = 0xdf25

    case compressSmall = 0xd226
    case enableCorrectFileSize = 0xd227
    case filterState = 0xd22b
    case storageID = 0xd244
    case filteredObjectCount = 0xd620
    case filteredObjectHandles = 0xd621
    case remotePhotoViewExVersion = 0xdf28
}
