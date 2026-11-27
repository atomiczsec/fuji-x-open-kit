import Foundation

public enum OperationCode: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession
    case closeSession
    case getStorageIDs
    case getStorageInfo
    case getObjectHandles = 0x1007
    case getObjectInfo
    case getObject
    case getThumb
    case getDevicePropValue = 0x1015
    case setDevicePropValue
    case initiateOpenCapture = 0x101c
    case getPartialObject = 0x101b

    case getFilterProps = 0x9050
    case getImageImportDates = 0x9053
    case getPreviewObjectInfo = 0x9054
    case getPreviewThumb = 0x9055
}
