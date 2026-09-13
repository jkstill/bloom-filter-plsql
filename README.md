# PL/SQL Bloom Filter

**Status: educational / prototype only.** This code demonstrates how a
[Bloom filter](https://en.wikipedia.org/wiki/Bloom_filter) can be built in
PL/SQL using a BLOB as a bit vector. It has not been hardened, load-tested,
or reviewed for production use — treat it as a teaching example of the
technique, not a library to depend on.

## Files

| File | Purpose |
|---|---|
| `bf-proto.sql` | Anonymous-block **prototype**. All logic (init/get/set/add) lives as nested procedures/functions inside one `declare` block, with debug `dbms_output` calls left in. This is the "figure it out" version. |
| `bf-pkg.sql` | The same logic promoted into a reusable `bloom_filter` package (spec + body), with debug output commented out and getters/setters for configuration. This is the version meant to be called from other code. |
| `bf-test.sql` | A driver script that configures `bloom_filter`, loads a set of integers and names into it, and prints membership results for known and unknown values, for a human to read. |
| `bf-verify.sql` | An automated test: loads a set of values into `bloom_filter`, then asserts every one of them comes back "probably in the set." Any miss raises an error and fails the script, since a Bloom filter must never produce a false negative. Prints `PASS: N/N ...` on success. |
| `bf-demo.sql` | A larger, timed demo: builds a 20,000-row unindexed table, populates a Bloom filter from it, then runs an incoming batch of lookups two ways — naive (query the table every time) vs. filter-gated (skip the query when the filter says "definitely not present") — and reports the query/time reduction and observed false-positive rate. |
| `bloom-filter-sizing.py` | Standalone helper (no dependency on the SQL) that computes the optimal bit-vector size `m` and hash count `k` for a target item count `n` and false-positive rate `p`. |
| `bloom-filter-simple.pl` | Standalone simple demo of a bloom filter in Perl, for understanding the algorithm without the PL/SQL/BLOB complexity. |
| `bloom-filter-simple.py` | Standalone simple demo of a bloom filter in Python, for understanding the algorithm without the PL/SQL/BLOB complexity. |

`bloom-filter-simple.pl` and `bloom-filter-simple.py` teach the concept
with a plain array of bits and MD5 (`md5("item-0")`, `md5("item-1")`, ...)
as a cheap way to get multiple hash values. They're intentionally not a
port of `bloom_filter`'s SHA-256-slicing approach (see "Hashing" below)
— read them to understand *what* a Bloom filter does, not to predict the
exact bits `bloom_filter` will set for the same input.

## What a Bloom filter is

A Bloom filter is a space-efficient probabilistic set. It answers "have I
seen this value before?" with one of two answers:

- **"Definitely not"** — always correct.
- **"Probably yes"** — correct most of the time, but can be a **false
  positive**. The false-positive rate is tunable by allocating a bigger bit
  vector and/or using more hash functions.

It can never produce a false negative, and it never stores the actual
values — only a fixed-size bit vector — so it trades a small, tunable error
rate for constant memory use regardless of how many items are checked.
There is no way to remove an item or list what's in the filter.

## How this implementation works

The bit vector is a BLOB. Instead of one bit column, bytes are addressed
and individual bits within a byte are tested/set with `bitand`/`bit_or`.

### Bit vector (`init_blob`, `get_bit`, `set_bit`)

- `init_blob` creates a temporary BLOB (`dbms_lob.createtemporary`) and
  zero-fills it to `ceil(vector_size / 8)` bytes, writing in chunks of up
  to 32,767 bytes at a time (`dbms_lob.writeappend`) to stay under
  RAW/literal size limits.
- `get_bit(vector_bits, bit_index)` computes which byte holds a given
  1-based bit index (`byte_index := trunc((bit_index-1)/8) + 1`), reads that
  single byte, and tests the relevant bit with `bitand(byte, 2^bit_position)`.
  The `trunc` matters: PL/SQL rounds (rather than truncates) a fractional
  value on assignment to a `PLS_INTEGER`, so plain `/` here would round
  some `bit_index` values up to the wrong byte — and, at the top of the
  vector, up to one byte past the BLOB's actual allocated length.
- `set_bit(vector_bits, bit_index)` reads the same byte, OR's in a mask for
  the target bit (`utl_raw.bit_or`), and writes the byte back.

### Hashing (`add_value`, `get_value`)

Both are overloaded for `pls_integer` and `varchar2` inputs, but do the
same thing:

1. Hash the input with SHA-256 (`dbms_crypto.hash(..., hash_sh256)`),
   producing a 32-byte digest.
2. Split the digest into 4-byte slices — one slice per hash function.
   Because 32 bytes / 4 bytes = 8, **`num_hashes` must be ≤ 8** or slices
   would need to repeat/reuse digest bytes (not implemented here).
3. Each 4-byte slice is cast to a `binary_integer` and masked with
   `2147483647` (`0x7FFFFFFF`) to clear the sign bit, then reduced with
   `mod(slice, vector_size) + 1` to get a 1-based bit index into the
   vector.
4. `add_value` sets that bit for every slice; `get_value` checks that bit
   for every slice and returns `false` (definitely not present) the moment
   any expected bit is unset, or `true` (probably present) if all bits from
   all `num_hashes` slices are set.

This is a single strong hash sliced into independent chunks, rather than
combining two different hashes (e.g. the common Kirsch–Mitzenmacher
`h1 + i*h2` trick) — simpler to read, at the cost of being capped at 8 hash
functions by SHA-256's output size.

### Package state (`bf-pkg.sql` only)

`vector_size` (default 1,000,000) and `num_hashes` (default 5) are **package
variables**, not parameters passed alongside the BLOB. That means:

- They are session-global — one `set_vector_size`/`set_num_hashes` call
  affects every BLOB the session touches afterward.
- The BLOB itself doesn't encode its own size or hash count, so a filter
  built with one configuration will silently produce wrong answers if
  checked after the configuration is changed. `bf-test.sql` sets both
  *before* calling `init_blob`, which is the correct order.

The prototype (`bf-proto.sql`) avoids this by keeping `vector_size` and
`num_hashes` as local variables in one block, which is simpler to reason
about but not reusable across calls.

## Sizing: `bloom-filter-sizing.py`

Bloom filter effectiveness depends on choosing `m` (bit vector size) and
`k` (hash count) for an expected item count `n` and acceptable
false-positive probability `p`:

```
m = ceil(-n * ln(p) / ln(2)^2)
k = round((m / n) * ln(2))
```

Running it confirms the constants each script hardcodes for its own
target `n`, e.g.:

```
optimal_params(10_000_000, 0.01) -> (95850584, 7)
optimal_params(20_000, 0.01)     -> (191702, 7)
```

`bf-test.sql` actually calls `set_vector_size(1000000)` and
`set_num_hashes(7)` — a round, easy-to-read vector size rather than the
value `optimal_params` would pick for its 32 test values, with a
commented-out `set_vector_size(95850584)` line showing the
10M-items/1%-false-positive sizing for comparison. `bf-demo.sql` sizes
for its actual 20,000-row table (`set_vector_size(191702)`,
`set_num_hashes(7)`) using the formula above.

## Running the tests / demos

```sql
SQL> @bf-pkg.sql
SQL> @bf-test.sql     -- eyeball demo: prints membership results
SQL> @bf-verify.sql   -- automated test: asserts positive results, PASS/FAIL
SQL> @bf-demo.sql     -- timed demo: builds a table, compares naive vs. filter-gated lookups
```

`bf-test.sql`:

1. Configures the filter with `vector_size => 1,000,000`, `num_hashes => 7`.
2. Adds 24 primes and 8 names (`bob`, `carol`, `dave`, `eve`, `frank`,
   `grace`, `heidi`, `ivan`) to the filter.
3. Checks a mix of numbers/names that were and weren't added, printing
   "is probably in the set" or "is definitely NOT in the set" for each.
   Values that were added should always report "probably in the set";
   values that weren't added should almost always report "definitely NOT"
   (a false positive is possible but, at this size/hash-count, extremely
   unlikely for a handful of lookups).

`bf-verify.sql` loads the same kind of small value set, then checks
every added value programmatically instead of leaving that to a human:
it raises an error and fails on the first value that doesn't come back
"probably in the set" (which should never happen), and otherwise prints
`PASS: N/N positive membership checks succeeded.`

`bf-demo.sql` requires a schema you can create objects in — it drops
and recreates a `bloom_demo_clients` table. See the "Demo" description
in the Files table above for what it measures; adjust `c_batch_size`
and `c_new_pct` at the top of its `declare` block to try other batch
sizes or new/known ratios.

## Requirements

- `dbms_crypto` execute privilege (for SHA-256 hashing).
- `dbms_lob` / temporary LOB support.

## Possible use cases (for a production-grade version of this idea)

These are the kinds of problems Bloom filters are normally used for — not
claims about what this particular prototype is ready for:

- **Pre-filtering expensive lookups**: check a Bloom filter before hitting
  a remote service, disk-based table, or index to skip work when the
  answer is "definitely not present" (e.g. "has this URL been crawled?",
  "has this email already been sent?").
- **De-duplication at scale**: flag likely-duplicate rows/events during
  ETL or streaming ingestion without keeping every seen key in memory.
- **Cache-miss avoidance**: avoid querying a cache or database for keys
  that are known not to exist.
- **Membership testing across a distributed system**: ship a compact bit
  vector between systems instead of a full key list (e.g. row-set
  reconciliation, join filtering in distributed queries — similar in
  spirit to what some databases already do internally for join
  pruning).

## Known limitations (as written)

- `num_hashes` is capped at 8 (SHA-256 digest / 4-byte slices).
- `vector_size`/`num_hashes` are session-global package state, not
  per-filter — see "Package state" above.
- No persistence shown: BLOBs here are temporary
  (`dbms_lob.createtemporary`) and freed at the end of the block/session;
  storing a filter permanently (e.g. in a table column) would need
  additional code.
- No item removal, no cardinality/false-positive-rate introspection, and
  no concurrency control if multiple sessions were to share one stored
  BLOB.
