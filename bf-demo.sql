-- =============================================================================
-- Bloom Filter Demo - Oracle 19c
-- =============================================================================
-- Demonstrates using a Bloom filter to gate an expensive full-table-scan
-- lookup against a poorly constructed table (no useful index, wide rows).
--
-- Flow:
--   1. Create and populate a wide, unindexed table with 20,000 rows
--   2. Populate the Bloom filter from existing client_names
--   3. Generate an incoming batch with a variable new/seen ratio
--   4. Run naive approach (query table for every value)
--   5. Run filter-gated approach (query table only on probable YES)
--   6. Report results and timing comparison
--
-- Variables at the top of the BEGIN block control batch size and new/seen ratio.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Create the poorly performing table
--    - No index on client_name (the lookup column)
--    - Wide rows with random data to increase scan cost
-- -----------------------------------------------------------------------------
drop table bloom_demo_clients purge;

create table bloom_demo_clients (
   id               number         not null,
   client_name      varchar2(30)   not null,
   junk_col_01      varchar2(200),
   junk_col_02      varchar2(200),
   junk_col_03      varchar2(200),
   junk_col_04      varchar2(200),
   junk_col_05      varchar2(200),
   junk_col_06      varchar2(200),
   junk_col_07      varchar2(200),
   junk_col_08      varchar2(200),
   junk_col_09      varchar2(200),
   junk_col_10      varchar2(200),
   junk_num_01      number,
   junk_num_02      number,
   junk_num_03      number,
   junk_num_04      number,
   junk_num_05      number,
   created_date     date
)
pctfree 10
storage (initial 128m next 128m)
nologging;

-- No index on client_name - this is intentional
-- Full table scan is the only access path available

-- -----------------------------------------------------------------------------
-- 2. Populate with 20,000 rows
--    client_name values are CLIENT_000001 .. CLIENT_020000
--    All other columns are random noise to widen the rows
-- -----------------------------------------------------------------------------
prompt Populating bloom_demo_clients with 20,000 rows - please wait...

insert --+ append 
into bloom_demo_clients (
   id,
   client_name,
   junk_col_01, junk_col_02, junk_col_03, junk_col_04, junk_col_05,
   junk_col_06, junk_col_07, junk_col_08, junk_col_09, junk_col_10,
   junk_num_01, junk_num_02, junk_num_03, junk_num_04, junk_num_05,
   created_date
)
select
   level,
   'CLIENT_' || lpad(level, 6, '0'),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.string('A', 200),
   dbms_random.value(1, 1000000),
   dbms_random.value(1, 1000000),
   dbms_random.value(1, 1000000),
   dbms_random.value(1, 1000000),
   dbms_random.value(1, 1000000),
   sysdate - dbms_random.value(0, 3650)
from dual
connect by level <= 20000;

commit;

-- Gather stats so the optimizer knows what it's dealing with
exec dbms_stats.gather_table_stats(user, 'BLOOM_DEMO_CLIENTS', estimate_percent => 100);

prompt Table populated and stats gathered.
prompt

-- -----------------------------------------------------------------------------
-- 3. Main demo block
-- -----------------------------------------------------------------------------
set serveroutput on size unlimited
declare

   -- -----------------------------------------------------------------------
   -- Demo parameters - adjust these to explore different scenarios
   -- -----------------------------------------------------------------------
   c_batch_size      constant pls_integer := 10000;   -- total incoming values to process
   c_new_pct         constant number      := 70;      -- % of batch that are NEW (not in table)
                                                      -- remaining % will be values known to exist

   -- -----------------------------------------------------------------------
   -- Bloom filter sizing
   -- For 20,000 elements at 1% false positive rate (bloom-filter-sizing.py -n 20000 -p 0.01):
   --   m = -n * ln(p) / ln(2)^2  =  191,702 bits
   --   k = (m/n) * ln(2)         =  7 hashes
   -- -----------------------------------------------------------------------
   c_vector_size     constant pls_integer := 191702;
   c_num_hashes      constant pls_integer := 7;

   -- -----------------------------------------------------------------------
   -- Working variables
   -- -----------------------------------------------------------------------
   vector_bits          blob;

   -- batch storage
   type str_array_t     is table of varchar2(30) index by pls_integer;
   v_batch              str_array_t;

   -- counters - naive approach
   v_naive_found        pls_integer := 0;
   v_naive_not_found    pls_integer := 0;
   v_naive_queries      pls_integer := 0;

   -- counters - filter-gated approach
   v_filter_found       pls_integer := 0;
   v_filter_not_found   pls_integer := 0;
   v_filter_queries     pls_integer := 0;   -- actual table queries executed
   v_filter_skipped     pls_integer := 0;   -- queries skipped (definite NO)
   v_false_positives    pls_integer := 0;   -- filter said YES but table said NO

   -- timing
   v_t0                 number;
   v_t1                 number;
   v_naive_ms           number;
   v_filter_ms          number;

   -- lookup
   v_dummy              varchar2(30);
   v_exists             boolean;

   -- batch generation
   v_new_count          pls_integer;
   v_seen_count         pls_integer;
   v_client_num         pls_integer;

begin

   -- -----------------------------------------------------------------------
   -- Step 1: Initialize the Bloom filter
   -- -----------------------------------------------------------------------
   dbms_output.put_line('=== Bloom Filter Demo ===');
   dbms_output.put_line('');
   dbms_output.put_line('Parameters:');
   dbms_output.put_line('  Batch size      : ' || to_char(c_batch_size, '999,999'));
   dbms_output.put_line('  New values      : ' || to_char(c_new_pct) || '%');
   dbms_output.put_line('  Existing values : ' || to_char(100 - c_new_pct) || '%');
   dbms_output.put_line('  Vector size     : ' || to_char(c_vector_size, '999,999,999') || ' bits');
   dbms_output.put_line('  Num hashes      : ' || to_char(c_num_hashes));
   dbms_output.put_line('');

   bloom_filter.set_vector_size(c_vector_size);
   bloom_filter.set_num_hashes(c_num_hashes);

   dbms_output.put_line('Initializing Bloom filter...');
   v_t0 := dbms_utility.get_time();
   bloom_filter.init_blob(vector_bits);
   v_t1 := dbms_utility.get_time();
   dbms_output.put_line('  Filter initialized in ' || to_char((v_t1 - v_t0) * 10) || ' ms');
   dbms_output.put_line('');

   -- -----------------------------------------------------------------------
   -- Step 2: Populate filter from existing table data
   -- -----------------------------------------------------------------------
   dbms_output.put_line('Populating filter from existing client data...');
   v_t0 := dbms_utility.get_time();

   for rec in (select client_name from bloom_demo_clients) loop
      bloom_filter.add_value(vector_bits, rec.client_name);
   end loop;

   v_t1 := dbms_utility.get_time();
   dbms_output.put_line('  Filter populated in ' || to_char((v_t1 - v_t0) * 10) || ' ms');
   dbms_output.put_line('');

   -- -----------------------------------------------------------------------
   -- Step 3: Generate the incoming batch
   --   NEW values    : CLIENT_020001 and above (guaranteed not in table)
   --   KNOWN values  : CLIENT_000001 .. CLIENT_020000 (guaranteed in table)
   -- -----------------------------------------------------------------------
   v_new_count  := round(c_batch_size * c_new_pct / 100);
   v_seen_count := c_batch_size - v_new_count;

   dbms_output.put_line('Generating batch of ' || to_char(c_batch_size, '999,999') || ' values...');
   dbms_output.put_line('  New (not in table) : ' || to_char(v_new_count, '999,999'));
   dbms_output.put_line('  Known (in table)   : ' || to_char(v_seen_count, '999,999'));
   dbms_output.put_line('');

   -- new values: CLIENT_020001 onwards
   for i in 1..v_new_count loop
      v_batch(i) := 'CLIENT_' || lpad(20000 + i, 6, '0');
   end loop;

   -- known values: random selection from CLIENT_000001..CLIENT_020000
   for i in 1..v_seen_count loop
      v_client_num := trunc(dbms_random.value(1, 20001));
      v_batch(v_new_count + i) := 'CLIENT_' || lpad(v_client_num, 6, '0');
   end loop;

   -- -----------------------------------------------------------------------
   -- Step 4: Naive approach - query table for every value
   -- -----------------------------------------------------------------------
   dbms_output.put_line('Running naive approach (query table for every value)...');
   v_t0 := dbms_utility.get_time();

   for i in 1..c_batch_size loop
      v_naive_queries := v_naive_queries + 1;
      begin
         select client_name
         into   v_dummy
         from   bloom_demo_clients
         where  client_name = v_batch(i)
         and    rownum = 1;

         v_naive_found := v_naive_found + 1;
      exception
         when no_data_found then
            v_naive_not_found := v_naive_not_found + 1;
      end;
   end loop;

   v_t1 := dbms_utility.get_time();
   v_naive_ms := (v_t1 - v_t0) * 10;

   dbms_output.put_line('  Done.');
   dbms_output.put_line('');

   -- -----------------------------------------------------------------------
   -- Step 5: Filter-gated approach
   -- -----------------------------------------------------------------------
   dbms_output.put_line('Running filter-gated approach...');
   v_t0 := dbms_utility.get_time();

   for i in 1..c_batch_size loop
      if bloom_filter.get_value(vector_bits, v_batch(i)) then
         -- probable YES: still need to verify with table query
         v_filter_queries := v_filter_queries + 1;
         begin
            select client_name
            into   v_dummy
            from   bloom_demo_clients
            where  client_name = v_batch(i)
            and    rownum = 1;

            v_filter_found := v_filter_found + 1;
         exception
            when no_data_found then
               -- filter said YES but table said NO: false positive
               v_false_positives := v_false_positives + 1;
               v_filter_not_found := v_filter_not_found + 1;
         end;
      else
         -- definite NO: skip the table query entirely
         v_filter_skipped  := v_filter_skipped + 1;
         v_filter_not_found := v_filter_not_found + 1;
      end if;
   end loop;

   v_t1 := dbms_utility.get_time();
   v_filter_ms := (v_t1 - v_t0) * 10;

   dbms_output.put_line('  Done.');
   dbms_output.put_line('');

   -- -----------------------------------------------------------------------
   -- Step 6: Results
   -- -----------------------------------------------------------------------
   dbms_output.put_line('=== Results ===');
   dbms_output.put_line('');
   dbms_output.put_line('Naive approach:');
   dbms_output.put_line('  Table queries executed : ' || to_char(v_naive_queries,   '999,999'));
   dbms_output.put_line('  Found in table         : ' || to_char(v_naive_found,     '999,999'));
   dbms_output.put_line('  Not found in table     : ' || to_char(v_naive_not_found, '999,999'));
   dbms_output.put_line('  Elapsed time           : ' || to_char(v_naive_ms,        '999,999,999,999') || ' ms');
   dbms_output.put_line('');
   dbms_output.put_line('Filter-gated approach:');
   dbms_output.put_line('  Table queries executed : ' || to_char(v_filter_queries,   '999,999'));
   dbms_output.put_line('  Queries skipped        : ' || to_char(v_filter_skipped,   '999,999'));
   dbms_output.put_line('  Found in table         : ' || to_char(v_filter_found,     '999,999'));
   dbms_output.put_line('  Not found in table     : ' || to_char(v_filter_not_found, '999,999'));
   dbms_output.put_line('  False positives        : ' || to_char(v_false_positives,  '999,999'));
   dbms_output.put_line('  Elapsed time           : ' || to_char(v_filter_ms,        '999,999,999,999') || ' ms');
   dbms_output.put_line('');
   dbms_output.put_line('Comparison:');
   dbms_output.put_line('  Query reduction        : ' ||
      to_char(round((1 - v_filter_queries/v_naive_queries) * 100, 1)) || '%');
   dbms_output.put_line('  Elapsed time reduction : ' ||
      to_char(round((1 - v_filter_ms/v_naive_ms) * 100, 1)) || '%');
   dbms_output.put_line('  Actual false positive rate: ' ||
      to_char(round(v_false_positives / greatest(v_filter_skipped + v_filter_queries, 1) * 100, 3)) || '%');
   dbms_output.put_line('');

   -- -----------------------------------------------------------------------
   -- Cleanup
   -- -----------------------------------------------------------------------
   dbms_lob.freetemporary(vector_bits);

end;
/
