import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

func systemClose(_ descriptor: Int32) {
    #if canImport(Glibc)
        _ = Glibc.close(descriptor)
    #else
        _ = Darwin.close(descriptor)
    #endif
}
var streamSocket: Int32 {
    #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
    #else
        return SOCK_STREAM
    #endif
}
