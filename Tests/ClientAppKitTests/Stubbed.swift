import Testing

/// The suites that answer requests with `StubProtocol`: its queue is shared,
/// so they run one test at a time, never alongside each other
@Suite(.serialized) enum Stubbed {}
