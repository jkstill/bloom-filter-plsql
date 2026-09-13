
## Create the Bloom Filter PL/SQL Package

```text
SQL> @bf-pkg
Package created.
No errors.
Package body created.
```

## Simple Bloom Filter Test

```text
SQL> @bf-test
Vector size: 1000000
Number of hashes: 7
Value 3 is probably in the set.
Value 5 is probably in the set.
Value 42 is definitely NOT in the set.
Value 51 is definitely NOT in the set.
Value 53 is probably in the set.
Value 75 is definitely NOT in the set.
Value 99 is definitely NOT in the set.
Value bob is probably in the set.
Value dave is probably in the set.
Value eve is probably in the set.
Value frank is probably in the set.
Value alice is definitely NOT in the set.
Value grace is probably in the set.
Value heidi is probably in the set.
Value ivan is probably in the set.

PL/SQL procedure successfully completed.

Elapsed: 00:00:00.05
```

## Bloom Filter Demo with 20,000 Elements

This test took about 4 minutes to run on my Oracle test machine (a desktop PC).

The results will vary based on your hardware and the number of rows in the table.

```text
SQL> @bf-demo

Table dropped.
Table created.

Populating bloom_demo_clients with 20,000 rows - please wait...
20000 rows created.
Elapsed: 00:00:10.31

Commit complete.

Table populated and stats gathered.

```text
=== Bloom Filter Demo ===
Parameters:
Batch size	:   10,000
New values	: 70%
Existing values : 30%
Vector size	:      191,702 bits
Num hashes	: 7
Initializing Bloom filter...
Filter initialized in 0 ms
Populating filter from existing client data...
Filter populated in 700 ms
Generating batch of   10,000 values...
New (not in table) :	7,000
Known (in table)   :	3,000
Running naive approach (query table for every value)...
Done.
Running filter-gated approach...
Done.

=== Results ===

Naive approach:
Table queries executed :   10,000
Found in table	       :    3,000
Not found in table     :    7,000
Elapsed time	       :	  183,980 ms

Filter-gated approach:
Table queries executed :    3,057
Queries skipped        :    6,943
Found in table	       :    3,000
Not found in table     :    7,000
False positives        :       57
Elapsed time	       :	   48,140 ms
Comparison:
Query reduction        : 69.4%
Elapsed time reduction : 73.8%
Actual false positive rate: .57%

Elapsed: 00:03:52.84
```

