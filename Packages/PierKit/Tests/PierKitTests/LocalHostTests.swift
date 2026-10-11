import Testing
@testable import PierKit

struct LocalHostTests {
    let names = ["Ana-MacBook.local"]
    let addresses = ["192.168.1.20", "fe80::1c2a:3bff:fe4d:5e6f", "100.101.102.103"]

    @Test func loopbackIsThisDevice() {
        for h in ["localhost", "127.0.0.1", "127.0.1.1", "::1", "[::1]"] {
            #expect(LocalHost.isThisDevice(h, names: [], addresses: []), "\(h)")
        }
    }

    @Test func itsOwnNamesAndAddresses() {
        #expect(LocalHost.isThisDevice("ana-macbook.local", names: names, addresses: addresses))
        #expect(LocalHost.isThisDevice("Ana-MacBook", names: names, addresses: addresses))
        #expect(LocalHost.isThisDevice("192.168.1.20", names: names, addresses: addresses))
        #expect(LocalHost.isThisDevice("100.101.102.103", names: names, addresses: addresses))
    }

    @Test func anotherMachineIsNot() {
        for h in ["bob-mac.local", "192.168.1.21", "203.0.113.5", "box.example.com", ""] {
            #expect(!LocalHost.isThisDevice(h, names: names, addresses: addresses), "\(h)")
        }
    }
}
