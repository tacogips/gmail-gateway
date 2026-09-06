import Foundation
@testable import GmailGatewayCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class PersistentAuthRedirectSemanticsTests: XCTestCase {
    func testLoadedClientPreservesFirstRegisteredRedirectForDefaultSelection() throws {
        let client = try loadGmailOAuthClientRecord(from: Data("""
        {
          "installed": {
            "client_id": "client-id.apps.googleusercontent.com",
            "client_secret": "client-secret",
            "project_id": "project",
            "auth_uri": "https://accounts.google.com/o/oauth2/v2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": [
              "http://localhost:8125/first-registered",
              "http://127.0.0.1:8124/lexically-first"
            ]
          }
        }
        """.utf8))

        XCTAssertEqual(client.redirectURIs.first, "http://localhost:8125/first-registered")
        XCTAssertEqual(
            try selectedGmailOAuthLoopbackRedirect(client: client, requestedURI: nil).registeredURI,
            "http://localhost:8125/first-registered"
        )
    }

    func testStoredDefaultAndExplicitRedirectsPreserveRegisteredHostPathAndPort() throws {
        let client = GmailOAuthClientRecord(
            kind: "installed",
            clientId: "client-id.apps.googleusercontent.com",
            clientSecret: "client-secret",
            projectId: "project",
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            redirectURIs: [
                "http://[::1]:8123/callback%2Fipv6",
                "http://localhost/callback%2Flocal",
                "http://127.0.0.1:8124/callback"
            ]
        )

        let stored = try selectedGmailOAuthLoopbackRedirect(client: client, requestedURI: nil)
        XCTAssertEqual(stored.host, "::1")
        XCTAssertEqual(stored.port, 8123)
        XCTAssertEqual(stored.path, "/callback%2Fipv6")
        XCTAssertEqual(stored.absoluteString(port: 8123), "http://[::1]:8123/callback%2Fipv6")

        let explicit = try selectedGmailOAuthLoopbackRedirect(client: client, requestedURI: "http://localhost:4567/callback%2Flocal")
        XCTAssertEqual(explicit.host, "localhost")
        XCTAssertEqual(explicit.port, 4567)
        XCTAssertEqual(explicit.path, "/callback%2Flocal")
        XCTAssertThrowsError(try selectedGmailOAuthLoopbackRedirect(client: client, requestedURI: "http://127.0.0.1:9999/callback"))
    }

    func testPortlessIPv4RedirectRetainsRegisteredCallbackPathWithDynamicPort() throws {
        let client = try loadGmailOAuthClientRecord(from: Data("""
        {
          "installed": {
            "client_id": "client-id.apps.googleusercontent.com",
            "auth_uri": "https://accounts.google.com/o/oauth2/v2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": ["http://127.0.0.1/persistent-callback"]
          }
        }
        """.utf8))

        let selected = try selectedGmailOAuthLoopbackRedirect(client: client, requestedURI: nil)
        let receiver = try LoopbackOAuthReceiver(redirect: selected)
        let components = try XCTUnwrap(URLComponents(string: receiver.redirectURI))
        XCTAssertEqual(selected.registeredURI, "http://127.0.0.1/persistent-callback")
        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.percentEncodedPath, "/persistent-callback")
        XCTAssertNotNil(components.port)
    }

    func testLoopbackReceiverRetainsIPv6AndLocalhostFamilySemantics() throws {
        let ipv6 = try LoopbackOAuthReceiver(redirectURI: "http://[::1]/callback%2Fipv6")
        let ipv6Components = try XCTUnwrap(URLComponents(string: ipv6.redirectURI))
        XCTAssertEqual(ipv6Components.host, "[::1]")
        XCTAssertEqual(ipv6Components.percentEncodedPath, "/callback%2Fipv6")
        XCTAssertNotNil(ipv6Components.port)

        let localhost = try LoopbackOAuthReceiver(
            redirectURI: "http://localhost/callback",
            localhostAddressResolver: { ["127.0.0.1", "::1"] }
        )
        let localhostComponents = try XCTUnwrap(URLComponents(string: localhost.redirectURI))
        XCTAssertEqual(localhostComponents.host, "localhost")
        XCTAssertEqual(localhostComponents.path, "/callback")
        XCTAssertNotNil(localhostComponents.port)
        XCTAssertThrowsError(try LoopbackOAuthReceiver(
            redirectURI: "http://localhost/callback",
            localhostAddressResolver: { ["127.0.0.1", "203.0.113.10"] }
        ))
    }

    func testPartialLocalhostBindingClosesEarlierListenerBeforeOAuthActivity() throws {
        let occupied = try reserveIPv6LoopbackListener()
        var occupiedDescriptor = occupied.descriptor
        defer {
            if occupiedDescriptor >= 0 {
                close(occupiedDescriptor)
            }
        }

        let client = GmailOAuthClientRecord(
            kind: "installed",
            clientId: "client-id.apps.googleusercontent.com",
            clientSecret: "client-secret",
            projectId: "project",
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            redirectURIs: ["http://localhost:\(occupied.port)/callback"]
        )
        let credential = CredentialConfig(
            id: "gmail-personal",
            provider: .gmail,
            accessMode: .read,
            oauthClientSecretPath: "/not-used-client",
            oauthClientSecretJSON: try client.legacyJSON(),
            tokenStorePath: "/not-used-token",
            tokenStoreJSON: nil
        )
        let activity = OAuthActivityCounter()
        let bootstrapper = GmailOAuthBootstrapper(
            receiverFactory: { redirect in
                try LoopbackOAuthReceiver(
                    redirect: redirect,
                    localhostAddressResolver: { ["127.0.0.1", "::1"] }
                )
            },
            browserOpener: { _ in activity.recordBrowserOpen() },
            beforeTokenExchange: { activity.recordTokenExchange() }
        )

        XCTAssertThrowsError(try bootstrapper.loginResult(
            credential: credential,
            options: GmailOAuthLoginOptions(openBrowser: true)
        ))
        XCTAssertEqual(activity.browserOpenCount, 0)
        XCTAssertEqual(activity.tokenExchangeCount, 0)

        // The constructor opened IPv4 first, then failed on the occupied IPv6
        // address. Rebinding IPv4 proves cleanup happened before login could
        // launch a browser or exchange a callback code.
        close(occupiedDescriptor)
        occupiedDescriptor = -1
        let recovered = try LoopbackOAuthReceiver(redirectURI: "http://127.0.0.1:\(occupied.port)/callback")
        XCTAssertEqual(try XCTUnwrap(URLComponents(string: recovered.redirectURI)).port, Int(occupied.port))
    }
}

private func reserveIPv6LoopbackListener() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else {
        throw PersistentAuthRedirectTestError(description: "Failed to create IPv6 port reservation socket")
    }
    do {
        var ipv6Only: Int32 = 1
        guard setsockopt(
            descriptor,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            &ipv6Only,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw PersistentAuthRedirectTestError(description: "Failed to require IPv6-only reservation socket")
        }
        var address = sockaddr_in6()
        #if !os(Linux)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(0).bigEndian
        address.sin6_addr = in6addr_loopback
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            throw PersistentAuthRedirectTestError(description: "Failed to bind IPv6 port reservation socket")
        }
        var boundAddress = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw PersistentAuthRedirectTestError(description: "Failed to read IPv6 port reservation socket")
        }
        return (descriptor, UInt16(bigEndian: boundAddress.sin6_port))
    } catch {
        close(descriptor)
        throw error
    }
}

private struct PersistentAuthRedirectTestError: Error, CustomStringConvertible {
    let description: String
}

private final class OAuthActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var browserOpens = 0
    private var tokenExchanges = 0

    func recordBrowserOpen() { lock.withLock { browserOpens += 1 } }
    func recordTokenExchange() { lock.withLock { tokenExchanges += 1 } }
    var browserOpenCount: Int { lock.withLock { browserOpens } }
    var tokenExchangeCount: Int { lock.withLock { tokenExchanges } }
}
