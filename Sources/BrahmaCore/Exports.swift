/// The safety kernel (Plan S, spec §6.8.1): the path layer, the process primitives and the Seatbelt runtime live in
/// `BrahmaSafety`; its public API is re-exported here so the app, the CLI and the tests keep compiling unchanged.
@_exported import BrahmaSafety
