#if canImport(Darwin)
    import Darwin
#elseif canImport(Bionic)
    @preconcurrency import Bionic
#elseif canImport(Glibc)
    @preconcurrency import Glibc
#elseif canImport(Musl)
    @preconcurrency import Musl
#elseif os(Windows)
    import WinSDK
#elseif os(WASI)
    @preconcurrency import WASILibc
#elseif os(Emscripten)
    @preconcurrency import EmscriptenLibc
#else
    #error("Unsupported platform: Standard C library not found.")
#endif

package final class Mutex: @unchecked Sendable {
    #if os(Windows)
        private var lockPtr: UnsafeMutablePointer<SRWLock>
    #else
        private var lockPtr: UnsafeMutablePointer<pthread_mutex_t>
    #endif

    package init() {
        #if os(Windows)
            lockPtr = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
            InitializeSRWLock(lockPtr)
        #else
            lockPtr = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
            let result = pthread_mutex_init(lockPtr, nil)
            precondition(result == 0, "Mutex initialization failed with error: \(result)")
        #endif
    }

    deinit {
        #if os(Windows)
            lockPtr.deallocate()
        #else
            pthread_mutex_destroy(lockPtr)
            lockPtr.deallocate()
        #endif
    }

    @usableFromInline
    @inline(__always)
    package func withLock<T>(_ body: () throws -> T) rethrows -> T {
        #if os(Windows)
            AcquireSRWLockExclusive(lockPtr)
            defer { ReleaseSRWLockExclusive(lockPtr) }
            return try body()
        #else
            pthread_mutex_lock(lockPtr)
            defer { pthread_mutex_unlock(lockPtr) }
            return try body()
        #endif
    }
}
