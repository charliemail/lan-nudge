import Foundation
import Network
import Testing
@testable import LANNudge

struct KnownPeersTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let port = NWEndpoint.Port(rawValue: 47123)!

    func bonjourPeer(_ hint: String, addrs: [String]) -> Peer {
        Peer(id: "LANNudge-\(hint)", name: "小明", hint: hint,
             candidates: [.service(name: "LANNudge-\(hint)", type: Wire.bonjourType, domain: "local.", interface: nil)]
                + addrs.map { .hostPort(host: NWEndpoint.Host($0), port: port) })
    }

    @Test func remembersAdvertisedAddressesAndBuildsAPeer() throws {
        var known = KnownPeers()
        known.met(bonjourPeer("AAAA", addrs: ["192.168.1.10", "10.8.0.20"]), now: now)
        let peer = try #require(known.peer("AAAA"))
        #expect(peer.name == "小明（VPN）" && peer.hint == "AAAA")
        #expect(peer.candidates == [.hostPort(host: "192.168.1.10", port: port), .hostPort(host: "10.8.0.20", port: port)])
    }

    @Test func recordWithoutPortIsNotRemembered() {
        var known = KnownPeers()
        known.met(bonjourPeer("AAAA", addrs: []), now: now)
        #expect(known.entries.isEmpty)
    }

    @Test func helloOnlyUpdatesKnownPeers() {
        var known = KnownPeers()
        let stranger = known.heard(from: "BBBB", host: "10.8.0.30", port: 50000, now: now)
        #expect(!stranger)
        #expect(known.entries.isEmpty)

        known.met(bonjourPeer("AAAA", addrs: ["192.168.1.10", "10.8.0.20"]), now: now)
        let friend = known.heard(from: "AAAA", host: "10.8.0.99", port: 50000, now: now + 60)
        #expect(friend)
        let entry = known.entries["AAAA"]
        #expect(entry?.addresses == ["10.8.0.99", "192.168.1.10", "10.8.0.20"])
        #expect(entry?.port == 50000 && entry?.seen == now + 60)
    }

    @Test func namedStrangerIsAddedFromItsConnection() {
        var known = KnownPeers()
        let added = known.heard(from: "CCCC", host: "10.8.0.40", port: 47123, name: "阿華", now: now)
        #expect(added)
        #expect(known.peer("CCCC")?.name == "阿華（VPN）")
        #expect(known.peer("CCCC")?.candidates == [.hostPort(host: "10.8.0.40", port: port)])
    }

    @Test func forgetsOldAndCapsTheList() {
        var known = KnownPeers()
        known.met(bonjourPeer("OLD", addrs: ["10.0.0.1"]), now: now)
        known.prune(now: now + KnownPeers.maxAge + 1)
        #expect(known.entries.isEmpty)

        for i in 0...KnownPeers.maxEntries {
            known.met(bonjourPeer("P\(i)", addrs: ["10.0.0.\(i)"]), now: now + Double(i))
        }
        #expect(known.entries.count == KnownPeers.maxEntries)
        #expect(known.entries["P0"] == nil && known.entries["P\(KnownPeers.maxEntries)"] != nil)
    }
}

struct VPNScanHostsTests {
    let own: UInt32 = 10 << 24 | 8 << 16 | 0 << 8 | 13

    @Test func coversOwnSlash24ExceptSelf() {
        let hosts = LocalAddresses.scanHosts(address: own, prefix: 24)
        #expect(hosts.count == 253 && hosts.first == "10.8.0.1" && hosts.last == "10.8.0.254")
        #expect(!hosts.contains("10.8.0.13"))
    }

    @Test func widerPoolsStayWithinOwnSlash24() {
        #expect(LocalAddresses.scanHosts(address: own, prefix: 16) == LocalAddresses.scanHosts(address: own, prefix: 24))
    }

    @Test func pointToPointLinksHaveNoNeighbours() {
        #expect(LocalAddresses.scanHosts(address: own, prefix: 32).isEmpty)
        #expect(LocalAddresses.scanHosts(address: own, prefix: 31).isEmpty)
        #expect(LocalAddresses.scanHosts(address: own, prefix: 30) == ["10.8.0.14"])
    }
}
