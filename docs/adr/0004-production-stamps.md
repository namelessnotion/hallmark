# Production stamps stay id-free; hashed ids ride beside them

Phase 3 runs the collectors outside the test suite (shadow and sampled modes), where an operator who sees a counterexample needs to find the request behind it. Stamps hold no ids, and their value depends on that: equal decisions collapse into one stamp, so a busy app writes a handful of lines per entry point, and verification cost follows the number of distinct shapes, not traffic. Adding a user or record id to a stamp would make nearly every request a new stamp.

So a stamp's key (every field it has today) stays id-free in every mode. When `c.ids` is on (off by default, refused in test mode, and requiring `c.id_key` or `HALLMARK_ID_KEY`), the first occurrence of a stamp in a process carries an `example`: the user, the record and the current tenant as HMAC-SHA256 hex digests under the per-environment key. Equality, deduplication and inference ignore the example; the report prints it beside a finding ("first seen as user h:ab12..., record h:cd34..."), and an operator holding the key can match it against the app's own ids.

## Considered options

- **Ids in the stamp.** Exact witnesses, but deduplication stops working and the stamp files grow with traffic.
- **No ids at all.** Simplest and most private, but a shadow finding then names a shape with no way to find a request that produced it.
- **Plain ids in the example.** Traceable without a key, but stamps would carry personal data off the box; hashing keeps them useless without the key.

## Consequences

`Stamp` gains a field outside its key, so `StampStore`'s seen set and `StampSet` must compare stamps without it. Rotating the key makes old examples unmatchable, which is acceptable for an alert trail. Test mode never writes examples, so committed fixtures and CI artifacts stay id-free.
