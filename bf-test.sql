
set serveroutput on size unlimited

declare
	--vector_size pls_integer := 1000000;
	vector_bits blob;
begin

	bloom_filter.set_vector_size(1000000);
	--bloom_filter.set_vector_size(95850584);
	bloom_filter.set_num_hashes(7);

	dbms_output.put_line('Vector size: ' || to_char(bloom_filter.get_vector_size()));
	dbms_output.put_line('Number of hashes: ' || to_char(bloom_filter.get_num_hashes()));

	bloom_filter.init_blob(vector_bits);

	--- set some values in the bloom filter
	for rec in (
		select rownum id, column_value int_data
		from (
			table(
				sys.odcinumberlist(3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97)
			)
		)
	) loop
		bloom_filter.add_value(vector_bits, rec.int_data);
	end loop;

	for rec in (
		select rownum id, column_value varchar2_data
		from (
			table(
				sys.odcivarchar2list('bob','carol','dave','eve','frank','grace','heidi','ivan')
			)
		)
	) loop
		bloom_filter.add_value(vector_bits, rec.varchar2_data);
	end loop;

	-- test if in the bloom filter
	for rec in (
		select rownum id, column_value int_data
		from (
			table(
				sys.odcinumberlist(3,5,42, 51, 53, 75, 99)
			)
		)
	) loop
		if bloom_filter.get_value(vector_bits, rec.int_data) then
			dbms_output.put_line('Value ' || to_char(rec.int_data) || ' is probably in the set.');
		else
			dbms_output.put_line('Value ' || to_char(rec.int_data) || ' is definitely NOT in the set.');
		end if;
	end loop;

	for rec in (
		select rownum id, column_value secname
		from (
			table(
				sys.odcivarchar2list('bob','dave','eve','frank','alice','grace','heidi','ivan')
			)
		)
	) loop
		if bloom_filter.get_value(vector_bits, rec.secname) then
			dbms_output.put_line('Value ' || rec.secname || ' is probably in the set.');
		else
			dbms_output.put_line('Value ' || rec.secname || ' is definitely NOT in the set.');
		end if;
	end loop;

	dbms_lob.freetemporary(vector_bits);

end;
/


