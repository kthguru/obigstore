(*
 * Copyright (C) 2011-2012 Mauricio Fernandez <mfp@acm.org>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version,
 * with the special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)

module String = struct include String include BatString end

type ks = int

external custom_comparator_ : unit ->  LevelDB.comparator =
  "obigstore_custom_comparator"

let custom_comparator = custom_comparator_ ()

external apply_custom_comparator : string -> string -> int =
  "obigstore_apply_custom_comparator"

module TS : sig
  type timestamp_buf = private string
  val make_timestamp_buf : unit -> timestamp_buf
end = struct
  type timestamp_buf = string
  let make_timestamp_buf () = String.create 8
end

include TS

let version = 0

let keyspace_table_prefix = "00"
let keyspace_table_key ksname = "00" ^ ksname

let end_of_db_key = String.make 8 (Char.chr 0xFF)

let decode_keyspace_table_name k =
  if String.slice k ~last:(String.length keyspace_table_prefix) <>
     keyspace_table_prefix then
    None
  else
    Some (String.slice ~first:2 k)

module Keyspace_tables =
struct
  let ks_table_table_prefix = "01"

  let one_byte_string n = String.make 1 (Char.chr n)

  let ks_table_table_prefix_for_ks ksname =
    String.concat ""
      [ ks_table_table_prefix;
        one_byte_string (String.length ksname); ksname ]

  let ks_table_table_key ~keyspace ~table =
    String.concat ""
      [ ks_table_table_prefix;
        one_byte_string (String.length keyspace); keyspace;
        one_byte_string (String.length table); table;
      ]

  let decode_ks_table_key k =
    if String.slice k ~last:(String.length ks_table_table_prefix) <>
       ks_table_table_prefix then
      None
    else begin
      try
        let ks_len = Char.code k.[2] in
        let table_len = Char.code k.[3 + ks_len] in
          if 2 + 1 + ks_len + 1 + table_len > String.length k then None
          else
            Some (String.slice k ~first:3 ~last:(3 + ks_len),
                  String.slice k ~first:(4 + ks_len) ~last:(4 + ks_len + table_len))
      with _ -> None
    end
end

let add_vint_and_ret_size dst n =
  let off = Obs_bytea.length dst in
    Obs_bytea.add_vint dst n;
    Obs_bytea.length dst - off

(* datum key format:
 * '1' vint(keyspace) vint(table_id) uint8(type) string(key) string(column)
 * uint64_LE(timestamp lxor 0xFFFFFFFFFFFFFFFF)
 * var_int(key_len) var_int(col_len)
 * uint8(len(vint(keyspace)) lsl 3 | len(vint(table_id)))
 * uint8(len(vint(key_len)) lsl 3 | len(vint(col_len)))
 * uint8(flags) uint8(version)
 * *)

let encode_datum_key dst ks ~table ~key ~column ~timestamp =
  Obs_bytea.clear dst;
  Obs_bytea.add_char dst '1';
  let ks_len = add_vint_and_ret_size dst ks in
  let t_len = add_vint_and_ret_size dst table in
    Obs_bytea.add_byte dst 0; (* type *)
    Obs_bytea.add_string dst key;
    Obs_bytea.add_string dst column;
    Obs_bytea.add_int64_complement_le dst timestamp;
    let klen_len = add_vint_and_ret_size dst (String.length key) in
    let clen_len = add_vint_and_ret_size dst (String.length column) in
      Obs_bytea.add_byte dst ((ks_len lsl 3) lor t_len);
      Obs_bytea.add_byte dst ((klen_len lsl 3) lor clen_len);
      Obs_bytea.add_byte dst 0;
      Obs_bytea.add_byte dst version

let encode_table_successor dst ks table =
  encode_datum_key dst ks
    ~table:(table + 1) ~key:"" ~column:"" ~timestamp:Int64.min_int

external obigstore_decode_int64_complement_le : string -> int -> Int64.t =
  "obigstore_decode_int64_complement_le"

let decode_timestamp (s : timestamp_buf) =
  obigstore_decode_int64_complement_le (s :> string) 0

let decode_timestamp' s =
  if String.length s <> 8 then
    invalid_arg "Obs_datum_encoding.decode_timestamp': want string of length 8";
  obigstore_decode_int64_complement_le s 0

let encode_datum_key_to_string ks ~table ~key ~column ~timestamp =
  let b = Obs_bytea.create 13 in
    encode_datum_key b ks ~table ~key ~column ~timestamp;
    Obs_bytea.contents b

let encode_table_successor_to_string ks table =
  let b = Obs_bytea.create 13 in
    encode_table_successor b ks table;
    Obs_bytea.contents b

let decode_var_int_at s off =
  let rec loop s off shift n =
    match Char.code s.[off] with
        m when m >= 0x80 ->
          loop s (off + 1) (shift + 7) (n lor ((m land 0x7F) lsl shift))
      | m -> n lor (m lsl shift)
  in loop s off 0 0

let get_datum_key_keyspace_id datum_key =
  decode_var_int_at datum_key 1

let decode_datum_key
      ~table_r
      ~key_buf_r ~key_len_r
      ~column_buf_r ~column_len_r
      ~timestamp_buf
      datum_key len =
  if datum_key.[0] <> '1' then false else
  let last_byte = Char.code datum_key.[len - 3] in
  let clen_len = last_byte land 0x7 in
  let klen_len = (last_byte lsr 3) land 0x7 in (* safer *)
  let ks_and_t_lengths = Char.code datum_key.[len - 4] in
  let ks_len = (ks_and_t_lengths lsr 3) land 0x7 in
  let t_len = ks_and_t_lengths land 0x7 in
  let c_len = decode_var_int_at datum_key (len - 4 - clen_len) in
  let k_len = decode_var_int_at datum_key (len - 4 - clen_len - klen_len) in
  let expected_len =
    1 + ks_len + t_len + 1 + k_len + c_len + 8 + clen_len + klen_len + 1 + 1 + 1 + 1
  in
    if expected_len <> len then
      false

    (* filter out entries with type <> 0 *)
    else if Char.code datum_key.[1 + ks_len + t_len] <> 0 then
      false
    else begin
      table_r := decode_var_int_at datum_key (1 + ks_len);
      begin match key_buf_r, key_len_r with
          None, _ | _, None -> ()
        | Some b, Some l ->
            if String.length !b < k_len then
              b := String.create k_len;
            String.blit datum_key (1 + ks_len + t_len + 1) !b 0 k_len;
            l := k_len
      end;
      begin match column_buf_r, column_len_r with
          None, _ | _,  None -> ()
        | Some b, Some l ->
            if String.length !b < c_len then
              b := String.create c_len;
            String.blit datum_key (1 + ks_len + t_len + 1 + k_len) !b 0 c_len;
            l := c_len
      end;
      begin match timestamp_buf with
          None -> ()
        | Some (b : timestamp_buf) ->
            String.blit datum_key (1 + ks_len + t_len + 1 + k_len + c_len) (b :> string) 0 8;
      end;
      true
    end
