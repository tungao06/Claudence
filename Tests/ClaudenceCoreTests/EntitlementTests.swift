import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - FullEntitlement grants everything

@Test
func fullEntitlementGrantsEveryFeature() {
    let entitlement = FullEntitlement()
    for feature in Feature.allCases {
        #expect(entitlement.isGranted(feature))
    }
}

@Test
func fullEntitlementCoversAtLeastOneFeaturePerNamedArea() {
    // A regression guard against the enum quietly losing cases: the doc
    // comment on `Feature` names six areas, so six is the floor, not a target
    // to keep the count above.
    #expect(Feature.allCases.count >= 6)
}

// MARK: - No I/O

@Test
func fullEntitlementHasNoStoredState() {
    // Nothing to hold a file handle, a URLSession, or a Keychain reference in.
    // A conformance that performs I/O needs somewhere to keep the means of
    // doing it; a zero-property value has nowhere to put it.
    let mirror = Mirror(reflecting: FullEntitlement())
    #expect(mirror.children.isEmpty)
}

@Test
func fullEntitlementAnswersSynchronouslyAndFast() {
    // `isGranted` is neither `async` nor `throws`, so it cannot await a
    // network response or surface a file error; this pins the runtime
    // behaviour that follows from that signature. A hundred thousand calls
    // completing in a few milliseconds is only possible because nothing here
    // touches a file, a socket, or the Keychain — any of those would push the
    // total from microseconds into tens of milliseconds at minimum.
    let entitlement = FullEntitlement()
    let start = DispatchTime.now()
    var grantedCount = 0
    for i in 0..<100_000 {
        let feature = Feature.allCases[i % Feature.allCases.count]
        if entitlement.isGranted(feature) {
            grantedCount += 1
        }
    }
    let elapsedSeconds =
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

    #expect(grantedCount == 100_000)
    #expect(elapsedSeconds < 0.05)
}

@Test
func entitlementIsUsableAcrossConcurrencyDomains() async {
    // `Entitlement: Sendable` is meant to cross actor boundaries with no
    // synchronization of its own; this fails to compile if that ever stops
    // being true, which is the property this test exists to protect.
    let entitlement: any Entitlement = FullEntitlement()
    let result = await Task {
        entitlement.isGranted(.dashboardAnalytics)
    }.value
    #expect(result)
}
