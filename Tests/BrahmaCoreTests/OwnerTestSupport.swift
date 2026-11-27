import Foundation
@testable import BrahmaCore

extension OwnerPrincipal {
    /// Tests (final wave B1): this owner test process's principal, minted at each use, so a test running in simulated agent
    /// mode never gets one (the mint refuses there).
    static var test: OwnerPrincipal { get throws { try OwnerPrincipal.mint() } }
}
