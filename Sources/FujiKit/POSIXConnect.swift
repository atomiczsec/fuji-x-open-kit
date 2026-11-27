import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t)
    -> Int32
{
    #if canImport(Glibc)
        return Glibc.connect(descriptor, address, length)
    #else
        return Darwin.connect(descriptor, address, length)
    #endif
}
