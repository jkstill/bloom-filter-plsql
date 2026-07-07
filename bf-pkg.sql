
-- plsql bloom filter prototype

create or replace package bloom_filter is
	--procedure init_blob (vector_bits out blob, vector_size in pls_integer);
	procedure init_blob (vector_bits out blob);
	procedure add_value (vector_bits in out blob, p_value in pls_integer);
	procedure add_value (vector_bits in out blob, p_value in varchar2);
	function get_value (vector_bits in blob, p_value in pls_integer) return boolean;
	function get_value (vector_bits in blob, p_value in varchar2) return boolean;

	function get_vector_size return pls_integer;
	procedure set_vector_size (p_vector_size in pls_integer);
	function get_num_hashes return pls_integer;
	procedure set_num_hashes (p_num_hashes in pls_integer);

end bloom_filter;
/

show errors package bloom_filter;

create or replace package body bloom_filter is

	num_hashes pls_integer := 5;  -- number of hash functions
	vector_size pls_integer := 1000000;  -- size of the bit vector

	--procedure init_blob (vector_bits out blob, vector_size in pls_integer)
	procedure init_blob (vector_bits out blob)
	is
		v_remaining number;
		v_zero_str  raw(32767) := utl_raw.copies(hextoraw('00'), 32767);
		v_chunk_len number := 32767;   -- chunk size (<= 32,767)
	begin
		-- 1. create a temporary blob
  		dbms_lob.createtemporary(vector_bits, true, dbms_lob.call);
  		-- 2. prepare a 32,000 character string of zeroes
  		--v_zero_str := lpad('0', v_chunk_len, '0');

  		-- 3. append in chunks to exceed varchar2/literal limitations
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

	function get_vector_size return pls_integer is
	begin
		return vector_size;
	end;

	procedure set_vector_size (p_vector_size in pls_integer) is
	begin
		vector_size := p_vector_size;
	end;

	function get_num_hashes return pls_integer is
	begin
		return num_hashes;
	end;

	procedure set_num_hashes (p_num_hashes in pls_integer) is
	begin
		num_hashes := p_num_hashes;
	end;

	function get_bit (vector_bits in blob, bit_index in pls_integer) return boolean is
		byte_index pls_integer := (bit_index - 1) / 8 + 1;
		bit_position pls_integer := mod(bit_index - 1, 8);
		byte_value raw(1);
		l_amount pls_integer := 1;
	begin
		dbms_lob.read(vector_bits, l_amount, byte_index, byte_value);
		return (bitand(utl_raw.cast_to_binary_integer(byte_value), power(2, bit_position)) != 0);
	end;
	
	procedure set_bit (vector_bits in out blob, bit_index in pls_integer) is
		byte_index   pls_integer := (bit_index - 1) / 8 + 1;
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
		-- slice 4 x 4-byte chunks from the 16-byte MD5
		--dbms_output.put_line('Hash: ' || rawtohex(l_hash));	

		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			--dbms_output.put_line('Slice: ' || l_slice);
   		l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			--dbms_output.put_line('Setting bit index: ' || l_bit_index);
   		set_bit(vector_bits, l_bit_index);
			--dbms_output.put_line('===============================');
		end loop;
	
	end;

	procedure add_value (vector_bits in out blob, p_value in varchar2) is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice binary_integer;
	begin

		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice 4 x 4-byte chunks from the 16-byte MD5
		--dbms_output.put_line('Hash: ' || rawtohex(l_hash));	

		for i in 0..num_hashes-1 loop
			l_slice := bitand(utl_raw.cast_to_binary_integer(utl_raw.substr(l_hash, i*4+1, 4)), 2147483647);
			--dbms_output.put_line('Slice: ' || l_slice);
   		l_bit_index := mod(l_slice, vector_size) + 1;  -- 1-based
			--dbms_output.put_line('Setting bit index: ' || l_bit_index);
   		set_bit(vector_bits, l_bit_index);
			--dbms_output.put_line('===============================');
		end loop;
	
	end;

	function get_value (vector_bits in blob, p_value in pls_integer) return boolean is
		l_hash raw(32);  -- 32 bytes for SHA-256
		l_bit_index pls_integer;
		l_slice pls_integer;
		l_result boolean := true;
	begin
		
		l_hash := dbms_crypto.hash(utl_raw.cast_to_raw(p_value), dbms_crypto.hash_sh256);
		-- slice 4 x 4-byte chunks from the 16-byte MD5
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
		-- slice 4 x 4-byte chunks from the 16-byte MD5
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

end bloom_filter;
/

show errors package body bloom_filter;



