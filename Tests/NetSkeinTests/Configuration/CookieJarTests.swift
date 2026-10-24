import Foundation
import Testing

@testable import NetSkein

struct CookieJarTests {
    @Test(
        "CookieJarTests: Verifies setting and retrieving a single cookie for a specific host"
    )
    func testSetAndGetSingleCookie() {
        let jar = CookieJar()
        let host = "://github.com"

        jar.setCookie(host: host, name: "session_id", value: "xyz123")
        let header = jar.cookieHeader(for: host)

        #expect(header == "session_id=xyz123")
    }

    @Test(
        "CookieJarTests: Verifies multiple cookies for the same host are correctly joined with semicolons"
    )
    func testMultipleCookiesForSameHost() {
        let jar = CookieJar()
        let host = "example.com"

        jar.setCookie(host: host, name: "theme", value: "dark")
        jar.setCookie(host: host, name: "lang", value: "en")

        guard let header = jar.cookieHeader(for: host) else {
            Issue.record("Cookie header was unexpectedly nil")
            return
        }

        // Swift Dictionary is unordered by default, so we break down the joined
        // string components to verify presence of each element independently.
        let components = header.components(separatedBy: "; ")
        #expect(components.count == 2)
        #expect(components.contains("theme=dark"))
        #expect(components.contains("lang=en"))
    }

    @Test("CookieJarTests: Ensures cookie domains are fully isolated from each other")
    func testHostIsolation() {
        let jar = CookieJar()

        jar.setCookie(host: "apple.com", name: "user", value: "steve")
        jar.setCookie(host: "google.com", name: "user", value: "larry")

        #expect(jar.cookieHeader(for: "apple.com") == "user=steve")
        #expect(jar.cookieHeader(for: "google.com") == "user=larry")
        #expect(jar.cookieHeader(for: "microsoft.com") == nil)
    }

    @Test(
        "CookieJarTests: Verifies clear operation purges all stored cookie data across all hosts"
    )
    func testClearCookies() {
        let jar = CookieJar()

        jar.setCookie(host: "example.com", name: "token", value: "123")
        #expect(jar.cookieHeader(for: "example.com") != nil)

        jar.clear()

        #expect(jar.cookieHeader(for: "example.com") == nil)
    }

    @Test(
        "CookieJarTests: Verifies thread-safety under heavy concurrent write operations across parallel tasks"
    )
    func testConcurrentCookieWrites() async {
        let jar = CookieJar()
        let host = "concurrent.local"
        let iterationCount = 100

        // Simulating heavy concurrent access utilizing Swift 6 structural TaskGroup loops
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterationCount {
                group.addTask {
                    jar.setCookie(host: host, name: "cookie_\(i)", value: "val_\(i)")
                }
            }
        }

        guard let header = jar.cookieHeader(for: host) else {
            Issue.record("Failed to fetch header after concurrent inserts")
            return
        }

        let components = header.components(separatedBy: "; ")
        #expect(components.count == iterationCount)
    }
}
