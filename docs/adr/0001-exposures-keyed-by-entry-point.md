# Exposures are keyed by entry point, not by rule

An exposure is one entry point (a controller action, or a GraphQL root field or mutation) performing one op on one kind of resource; its guard is built from the rules it calls plus its filters. Keying by policy rule instead would lose threat 10 (an entry point that never calls `authorize`) and entry points that call several rules, and one rule often serves many entry points anyway. Rules stay a separate unit, so an RSpec matcher can still check one rule's guard on its own.

## Consequences

Generated check names (`safe_<entry point>_<op>_<resource>`) and the witness skolems `Finding` reads (`$safe_<entry point>_<op>_<resource>_p`, `_r`) are derived from the whole key, so changing the key later means changing the model builder, the decoder and every fixture.

Until Oct 16, 2026 the names left out the resource (`safe_<entry point>_<op>`), so an entry point that read two kinds of record, inferred from stamps, produced two checks with the same name and the analysis refused to run. The resource is now part of every name.
