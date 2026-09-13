
-- Automated test for bloom_filter (bf-pkg.sql).
--
-- Unlike bf-test.sql (which prints membership results for a human to read),
-- this script asserts correctness: every value added to the filter MUST
-- come back "probably in the set". A Bloom filter can never produce a false
-- negative, so any miss here means the implementation is broken, not that
-- we got unlucky - the script raises an error and exits with a failure
-- status on the first miss, and prints a PASS summary if all checks pass.

whenever sqlerror exit failure rollback

set serveroutput on size unlimited

declare
	vector_bits    blob;
	v_pass_count   pls_integer := 0;
	v_check_count  pls_integer := 0;
begin

	-- Sized via bloom-filter-sizing.py -n 32 -p 0.01 (32 items loaded below)
	bloom_filter.set_vector_size(307);
	bloom_filter.set_num_hashes(7);

	bloom_filter.init_blob(vector_bits);

	-- load the positive set: values that MUST be reported as members afterward
	for rec in (
		select column_value int_data
		from table(
			sys.odcinumberlist(3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97)
		)
	) loop
		bloom_filter.add_value(vector_bits, rec.int_data);
	end loop;

	for rec in (
		select column_value varchar2_data
		from table(
			sys.odcivarchar2list('bob','carol','dave','eve','frank','grace','heidi','ivan')
		)
	) loop
		bloom_filter.add_value(vector_bits, rec.varchar2_data);
	end loop;

	-- verify: every value just added must test positive - no exceptions
	for rec in (
		select column_value int_data
		from table(
			sys.odcinumberlist(3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97)
		)
	) loop
		v_check_count := v_check_count + 1;
		if bloom_filter.get_value(vector_bits, rec.int_data) then
			v_pass_count := v_pass_count + 1;
		else
			raise_application_error(-20001,
				'FAIL: added value ' || rec.int_data || ' was NOT reported as a member (false negative).');
		end if;
	end loop;

	for rec in (
		select column_value varchar2_data
		from table(
			sys.odcivarchar2list('bob','carol','dave','eve','frank','grace','heidi','ivan')
		)
	) loop
		v_check_count := v_check_count + 1;
		if bloom_filter.get_value(vector_bits, rec.varchar2_data) then
			v_pass_count := v_pass_count + 1;
		else
			raise_application_error(-20001,
				'FAIL: added value ''' || rec.varchar2_data || ''' was NOT reported as a member (false negative).');
		end if;
	end loop;

	dbms_output.put_line('PASS: ' || v_pass_count || '/' || v_check_count ||
		' positive membership checks succeeded.');

	dbms_lob.freetemporary(vector_bits);

end;
/
