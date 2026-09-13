
-- plsql bloom filter prototype

set serveroutput on size unlimited

declare

	vector_size pls_integer := 1000000;
	num_hashes pls_integer := 5;
	vector_bits blob;

  	-- prepare a 32k character raw string of zeroes
	v_zero_str  raw(32767) := utl_raw.copies(hextoraw('00'), 32767);
	v_chunk_len number := 32767;   -- chunk size (<= 32,767)

	procedure init_blob (vector_bits out blob, vector_size in pls_integer)
	is
		v_remaining number;
	begin
		-- create a temporary blob
  		dbms_lob.createtemporary(vector_bits, true, dbms_lob.call);

  		-- append in chunks to avoid varchar2/literal limitations
  		v_remaining := ceil(vector_size / 8);
  		while v_remaining > 0 loop
    		if v_remaining >= v_chunk_len then
      		dbms_lob.writeappend(vector_bits, v_chunk_len, v_zero_str);
      		v_remaining := v_remaining - v_chunk_len;
    		else
      		-- append the remainder
      		dbms_lob.writeappend(vector_bits, v_remaining, utl_raw.copies(hextoraw('00'), v_remaining));
      		v_remaining := 0;
    		end if;
  		end loop;
	end;

	function get_bit (vector_bits in blob, bit_index in pls_integer) return boolean is
		byte_index pls_integer := trunc((bit_index - 1) / 8) + 1;
		bit_position pls_integer := mod(bit_index - 1, 8);
		byte_value raw(1);
		l_amount pls_integer := 1;
	begin
		dbms_lob.read(vector_bits, l_amount, byte_index, byte_value);
		return (bitand(utl_raw.cast_to_binary_integer(byte_value), power(2, bit_position)) != 0);
	end;
	
	procedure set_bit (vector_bits in out blob, bit_index in pls_integer) is
		byte_index   pls_integer := trunc((bit_index - 1) / 8) + 1;
		bit_position pls_integer := mod(bit_index - 1, 8);
		byte_value   raw(1);
		mask         raw(4);  -- 4 bytes from cast_from_binary_integer
		l_amount     pls_integer := 1;
	begin
		dbms_lob.read(vector_bits, l_amount, byte_index, byte_value);
		mask := utl_raw.cast_from_binary_integer(power(2, bit_position));
		byte_value := utl_raw.bit_or(byte_value, utl_raw.substr(mask, 4, 1));
		dbms_lob.write(vector_bits, 1, byte_index, byte_value);
	end;

	procedure add_value (vector_bits in out blob, p_value in pls_integer) is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice binary_integer;
	begin

		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice num_hashes x 4-byte chunks from the 32-byte SHA-256 digest
		dbms_output.put_line('Hash: ' || rawtohex(l_hash));	

		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			dbms_output.put_line('Slice: ' || l_slice);
   		l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			dbms_output.put_line('Setting bit index: ' || l_bit_index);
   		set_bit(vector_bits, l_bit_index);
			dbms_output.put_line('===============================');
		end loop;
	
	end;

	procedure add_value (vector_bits in out blob, p_value in varchar2) is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice binary_integer;
	begin

		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice num_hashes x 4-byte chunks from the 32-byte SHA-256 digest
		dbms_output.put_line('Hash: ' || rawtohex(l_hash));	

		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			dbms_output.put_line('Slice: ' || l_slice);
   		l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			dbms_output.put_line('Setting bit index: ' || l_bit_index);
   		set_bit(vector_bits, l_bit_index);
			dbms_output.put_line('===============================');
		end loop;
	
	end;

	function get_value (vector_bits in blob, p_value in pls_integer) return boolean is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice pls_integer;
		l_result boolean := true;
	begin
		
		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice num_hashes x 4-byte chunks from the 32-byte SHA-256 digest
		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			if not get_bit(vector_bits, l_bit_index) then
				l_result := false;
				exit;
			end if;
		end loop;

		return l_result;
	end;

	function get_value (vector_bits in blob, p_value in varchar2) return boolean is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice pls_integer;
		l_result boolean := true;
	begin
		
		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice num_hashes x 4-byte chunks from the 32-byte SHA-256 digest
		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			if not get_bit(vector_bits, l_bit_index) then
				l_result := false;
				exit;
			end if;
		end loop;

		return l_result;
	end;


begin

	-- initialize the bloom filter bits
	init_blob(vector_bits, vector_size);
	add_value(vector_bits, 42);
	add_value(vector_bits, 'carol');

	--- set some values in the bloom filter
	for rec in (
		select rownum id, column_value int_data
		from (
			table(
				sys.odcinumberlist(3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97)
			)
		)
	) loop
		add_value(vector_bits, rec.int_data);
	end loop;

	for rec in (
		select rownum id, column_value varchar2_data
		from (
			table(
				sys.odcivarchar2list('bob','carol','dave','eve','frank','grace','heidi','ivan')
			)
		)
	) loop
		add_value(vector_bits, rec.varchar2_data);
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
		if get_value(vector_bits, rec.int_data) then
			dbms_output.put_line('Value ' || to_char(rec.int_data) || ' is probably in the set.');
		else
			dbms_output.put_line('Value ' || to_char(rec.int_data) || ' is definitely not in the set.');
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
		if get_value(vector_bits, rec.secname) then
			dbms_output.put_line('Value ' || rec.secname || ' is probably in the set.');
		else
			dbms_output.put_line('Value ' || rec.secname || ' is definitely not in the set.');
		end if;
	end loop;

	dbms_lob.freetemporary(vector_bits);

end;
/


