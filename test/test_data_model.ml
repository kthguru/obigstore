(*
 * Copyright (C) 2011 Mauricio Fernandez <mfp@acm.org>
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

open Printf
open Lwt
open Test_00util
open OUnit

module D = Storage
module DM = Data_model


module Run_test
  (D : Data_model.S)
  (C : sig
     val id : string
     val with_db : (D.db -> unit Lwt.t) -> unit
   end) =
struct
  let string_of_key_range = function
      DM.Keys l -> sprintf "Keys %s" (string_of_list (sprintf "%S") l)
    | DM.Key_range { DM.first; up_to; reverse; } ->
        sprintf "Key_range { first: %s; up_to: %s; reverse: %b; }"
          (string_of_option (sprintf "%S") first)
          (string_of_option (sprintf "%S") up_to)
          reverse

  let string_of_column c =
    sprintf "{ name = %S; data = %S; }" c.DM.name c.DM.data

  let string_of_key_data kd =
    sprintf "{ key = %S; last_column = %S; columns = %s }"
      kd.DM.key kd.DM.last_column
      (string_of_list string_of_column kd.DM.columns)

  let string_of_slice (last_key, l) =
    sprintf "(%s, %s)"
      (string_of_option (sprintf "%S") last_key)
      (string_of_list string_of_key_data l)

  let rd_col (name, data) =
    { DM.name; data; timestamp = DM.No_timestamp }

  let column_without_timestamp = rd_col

  let put tx tbl key l =
    D.put_columns tx tbl key
      (List.map column_without_timestamp l)

  let delete = D.delete_columns

  let key_range ?first ?last () =
    let up_to = match last with
        None -> None
      | Some l -> Some (l ^ "\000")
    in DM.Key_range { DM.first; up_to; reverse = false; }

  let rev_key_range ?first ?up_to () =
    DM.Key_range { DM.first; up_to; reverse = true; }

  let col_range_ ?(reverse = false) ?first ?last ?up_to () =
    let up_to = match up_to with
        Some _ as x -> x
      | None -> match last with
            None -> None
          | Some x -> Some (x ^ "\000")
    in DM.Column_range { DM.first; up_to; reverse; }

  let col_range ?reverse ?first ?last ?up_to () =
    DM.Column_range_union [col_range_ ?reverse ?first ?last ?up_to ()]

  let columns_ l = DM.Columns l

  let columns l = DM.Column_range_union [columns_ l]

  let put_slice ks tbl l =
    D.read_committed_transaction ks
      (fun tx -> Lwt_list.iter_s (fun (k, cols) -> put tx tbl k cols) l)

  let test_custom_comparator db =
    let ks = 1 in
    let ks2 = 2 in

    let encode ks (table, key, column, timestamp) =
      let b = Bytea.create 13 in
        Datum_encoding.encode_datum_key b ks ~table ~key ~column ~timestamp;
        Bytea.contents b in
    let cmp ks1 a ks2 b =
      Datum_encoding.apply_custom_comparator (encode ks1 a) (encode ks2 b) in
    let printer (tbl, key, col, ts) =
      sprintf
        "{ table = %d; key = %S; column = %S, timestamp = %Ld }" tbl key col ts in
    let ksname () ks = string_of_int ks in
    let aeq ?(ks1 = ks) ?(ks2 = ks) a b =
                match cmp ks1 a ks2 b with
          0 -> ()
        | n -> assert_failure_fmt
                 "Expected equality for %a:%s vs %a:%s, got %d"
                 ksname ks1 (printer a) ksname ks2 (printer b) n in
    let alt ?(ks1 = ks) ?(ks2 = ks) a b =
      match cmp ks1 a ks2 b with
          n when n < 0 -> ()
        | n -> assert_failure_fmt
                 "Expected LT for %a:%s vs %a:%s, got %d"
                 ksname ks1 (printer a) ksname ks2 (printer b) n in
    let agt ?(ks1 = ks) ?(ks2 = ks) a b =
      match cmp ks1 a ks2 b with
          n when n > 0 -> ()
        | n -> assert_failure_fmt
                 "Expected GT for %a:%s vs %a:%s, got %d"
                 ksname ks1 (printer a) ksname ks2 (printer b) n in
    let agt ?ks1 ?ks2 a b =
      aeq ?ks1 ?ks2:ks1 a a;
      aeq ?ks1 ?ks2:ks1 b b;
      aeq ?ks1:ks2 ?ks2 b b;
      aeq ?ks1:ks2 ?ks2 a a;
      agt ?ks1 ?ks2 a b;
      alt ?ks1:ks2 ?ks2:ks1 b a in
    let t = 0L in
      agt ~ks1:ks2 (1, "", "", t) (1, "", "", t);
      agt ~ks1:ks2 (1, "", "", t) (2, "", "", t);
      agt ~ks1:ks2 (1, "b", "c", t) (1, "b", "d", t);
      agt ~ks1:ks2 (1, "b", "c", t) (1, "c", "c", t);
      agt ~ks1:ks2 (1, "b", "c", t) (2, "b", "c", t);
      agt (3, "", "", t) (1, "", "", t);
      agt (1, "x", "", t) (1, "", "", t);
      agt (1, "x", "", t) (1, "", "", t);
      agt (1, "", "", t) (0, "", "", t);
      agt (1, "", "", t) (0, "\000", "", t);
      agt (1, "", "", t) (0, "\000", "b", t);
      agt (1, "\000", "", t) (1, "", "\000", t);
      agt (1, "1\000", "", t) (1, "1", "\000", t);
      agt (2, "k\000", "2", t) (2, "k", "\0003", t);
      agt (2, "d", "x", 0L) (2, "d", "", Int64.min_int);
      agt (2, "d", "d", 0L) (2, "d", "", 0L);
      agt (2, "d", "d", Int64.min_int) (2, "d", "", 0L);
      agt (2, "d", "d", Int64.min_int) (2, "d", "", Int64.min_int);
      agt ~ks1:203313 (1, "", "", t) ~ks2:13 (0, "", "", t);
      return ()

  let test_custom_comparator_non_datum db =
    let txt rev = if rev then "not " else "" in
    let alt ?(rev=false) x y =
      aeq_bool
        ~msg:(sprintf "%S should %sbe LT %S" x (txt rev) y)
        (not rev) (Datum_encoding.apply_custom_comparator x y < 0) in
    let agt ?(rev=false) x y =
      aeq_bool
        ~msg:(sprintf "%S should %sbe GT %S" x (txt rev) y)
        (not rev) (Datum_encoding.apply_custom_comparator x y > 0) in
    let aeq ?(rev=false) x y =
      aeq_bool
        ~msg:(sprintf "%S should %sbe EQ %S" x (txt rev) y)
        (not rev) (Datum_encoding.apply_custom_comparator x y = 0) in
    let rev = true in
    let alt x y = alt x y; agt y x; aeq ~rev x y in
    let b = Char.code in
    let bytes = string_of_bytes in
    let alt_bytes x y = alt (bytes x) (bytes y) in
    let aeq_bytes x y = aeq (bytes x) (bytes y) in
      aeq "" "";
      alt "" "1";
      alt "" "\255";
      alt "1033232" "\255";
      alt "\255" "\255\000";
      (* multi-byte keyspace *)
      alt
        (Datum_encoding.encode_datum_key_to_string
           129 ~table:9 ~key:"" ~column:"" ~timestamp:0L)
        (Datum_encoding.encode_datum_key_to_string
           256 ~table:0 ~key:"" ~column:"" ~timestamp:0L);
      (* null column with non-zero timestamp vs. non-null column *)
      alt_bytes
        [ b '1'; 1; 1; 0; b 'd'; 255; 0; 0; 0; 0; 0; 0; 0; 1; 0; 9; 9; 0; 0 ]
        [ b '1'; 1; 1; 0; b 'd'; b 'd'; 0; 0; 0; 0; 0; 0; 0; 0; 1; 1; 9; 9; 0; 0 ];
      (* diff timestamps, but nonetheless equal datum_keys *)
      aeq_bytes
        [ b '1'; 1; 1; 0; b 'd'; b 'd'; 1; 2; 0; 0; 0; 0; 0; 0; 1; 1; 9; 9; 0; 0 ]
        [ b '1'; 1; 1; 0; b 'd'; b 'd'; 3; 4; 0; 0; 0; 0; 0; 0; 1; 1; 9; 9; 0; 0 ];
      (* unrelated keys *)
      alt_bytes
        [ b '1'; 1; 1; 0; b 'c'; b 'c'; 1; 2; 0; 0; 0; 0; 0; 0; 1; 1; 9; 9; 0; 0 ]
        [ b '1'; 1; 1; 0; b 'd'; b 'd'; 3; 4; 0; 0; 0; 0; 0; 0; 1; 1; 9; 9; 0; 0 ];
      return ()

  let test_datum_key_encoding _ =
    let check (ks, table, key, column, timestamp) =
      let s = Datum_encoding.encode_datum_key_to_string
                ks ~table ~key ~column ~timestamp in
      let table_r = ref (-1) in
      let key_buf = ref "" and key_len = ref 0 in
      let column_buf = ref "" and column_len = ref 0 in
      let timestamp_buf = Datum_encoding.make_timestamp_buf () in
        aeq_bool ~msg:"decoding failed" true
          (Datum_encoding.decode_datum_key
             ~table_r
             ~key_buf_r:(Some key_buf) ~key_len_r:(Some key_len)
             ~column_buf_r:(Some column_buf) ~column_len_r:(Some column_len)
             ~timestamp_buf:(Some timestamp_buf) s (String.length s));
        aeq_int ~msg:"keyspace" ks (Datum_encoding.get_datum_key_keyspace_id s);
        aeq_int ~msg:"table id" table !table_r;
        aeq_int ~msg:"key len" (String.length key) !key_len;
        aeq_string ~msg:"key" key (String.sub !key_buf 0 !key_len);
        aeq_int ~msg:"column len" (String.length column) !column_len;
        aeq_string ~msg:"column" column (String.sub !column_buf 0 !column_len);
        aeq_int64 ~msg:"timestamp" timestamp
          (Datum_encoding.decode_timestamp timestamp_buf)
    in
      List.iter check
        [
          (1, 2, "foo", "bar", 12323L);
          (1, 2, "foo", "", 123L);
          (128, 31, "foo", "", 232L);
          (128, 24242, "x", "", 123L);
          (128, 128, "foo", "", 232L);
          (12345, 128, "foo", "", 232L);
          (123452, 123428, "foo", "", 232L);
        ];
      return ()

  let test_keyspace_management db =
    D.list_keyspaces db >|= aeq_string_list [] >>
    lwt k1 = D.register_keyspace db "foo" in
    lwt k2 = D.register_keyspace db "bar" in
    D.list_keyspaces db >|= aeq_string_list ["bar"; "foo";] >>
    D.get_keyspace db "foo" >|= aeq_some D.keyspace_name k1 >>
    D.get_keyspace db "bar" >|= aeq_some D.keyspace_name k2 >>
      return ()

  let test_list_tables db =
    lwt ks1 = D.register_keyspace db "test_list_tables" in
    lwt ks2 = D.register_keyspace db "test_list_tables2" in
      D.list_tables ks1 >|= aeq_string_list [] >>
      lwt () =
        D.read_committed_transaction ks1
          (fun tx -> D.put_columns tx "tbl1" "somekey" []) in
      D.list_tables ks1 >|= aeq_string_list [] >>
      lwt () =
        D.read_committed_transaction ks1
          (fun tx ->
             D.put_columns tx "tbl1" "somekey"
               [ { DM.name = "somecol"; data = "";
                   timestamp = DM.No_timestamp; }; ] >>
             D.put_columns tx "tbl2" "someotherkey"
               [ { DM.name = "someothercol"; data = "xxx";
                   timestamp = DM.No_timestamp; }; ]) in
      D.list_tables ks1 >|= aeq_string_list ["tbl1"; "tbl2"] >>
      D.list_tables ks2 >|= aeq_string_list [] >>
      return ()

  let test_list_tables_with_keyspaces db =
    lwt ks1 = D.register_keyspace db "test_list_tables_with_keyspaces" in
    lwt ks2 = D.register_keyspace db "test_list_tables_with_keyspaces2" in
      put_slice ks1 "dummy" ["a", ["x", ""]] >>
      put_slice ks2 "dummy" ["a", ["x", ""]] >>
      put_slice ks2 "dummy2" ["a", ["x", ""]] >>
      D.list_tables ks1 >|= aeq_string_list ["dummy"] >>
      D.list_tables ks2 >|= aeq_string_list ["dummy"; "dummy2"] >>
      put_slice ks1 "bar" ["a", ["x", ""]] >>
      D.list_tables ks1 >|= aeq_string_list ["bar"; "dummy"]

  let get_key_range ks ?max_keys ?first ?last tbl =
    D.read_committed_transaction ks
      (fun tx ->
         D.get_keys tx tbl ?max_keys (key_range ?first ?last ()))

  let get_keys ks tbl l =
    D.read_committed_transaction ks
      (fun tx -> D.get_keys tx tbl (DM.Keys l))

  let test_get_keys_ranges db =
    lwt ks1 = D.register_keyspace db "test_get_keys_ranges" in
    lwt ks2 = D.register_keyspace db "test_get_keys_ranges2" in

      get_key_range ks1 "tbl1" >|= aeq_string_list [] >>
      get_key_range ks2 "tbl1" >|= aeq_string_list [] >>

      D.read_committed_transaction ks1
        (fun tx ->
           Lwt_list.iter_s
             (fun k -> put tx "tbl1" k ["name", k])
             ["a"; "ab"; "b"; "cde"; "d"; "e"; "f"; "g"]) >>

      get_key_range ks2 "tbl1" >|= aeq_string_list [] >>
      get_key_range ks1 "tbl1" >|=
        aeq_string_list ["a"; "ab"; "b"; "cde"; "d"; "e"; "f"; "g"] >>
      get_key_range ks1 "tbl1" ~last:"c" >|=
        aeq_string_list ["a"; "ab"; "b"; ] >>
      get_key_range ks1 "tbl1" ~first:"c" ~last:"c" >|=
        aeq_string_list [ ] >>
      get_key_range ks1 "tbl1" ~first:"c" ~last:"f"  >|=
        aeq_string_list [ "cde"; "d"; "e"; "f" ] >>
      get_key_range ks1 "tbl1" ~first:"b" >|=
        aeq_string_list [ "b"; "cde"; "d"; "e"; "f"; "g" ] >>

      D.read_committed_transaction ks1
        (fun tx ->
           put tx "tbl1" "fg" ["x", ""] >>
           put tx "tbl1" "x" ["x", ""] >>
           get_key_range ks1 "tbl1" ~first:"e" >|=
             aeq_string_list ~msg:"read updates in transaction"
               [ "e"; "f"; "fg"; "g"; "x" ] >>
           get_key_range ks1 "tbl1" ~first:"f" ~last:"g" >|=
             aeq_string_list [ "f"; "fg"; "g"; ] >>
           begin try_lwt
             D.read_committed_transaction ks1
               (fun tx ->
                  D.delete_columns tx "tbl1" "fg" ["x"] >>
                  D.delete_columns tx "tbl1" "xx" ["x"] >>
                  put tx "tbl1" "fgh" ["x", ""] >>
                  put tx "tbl1" "xx" ["x", ""] >>
                  get_key_range ks1 "tbl1" ~first:"f" >|=
                    aeq_string_list ~msg:"nested transactions"
                      [ "f"; "fgh"; "g"; "x"; "xx" ] >>
                  raise Exit)
           with Exit -> return ()
           end >>
           get_key_range ks1 "tbl1" ~first:"e" >|=
             aeq_string_list [ "e"; "f"; "fg"; "g"; "x" ])

  let test_get_keys_reverse_ranges db =
    lwt ks = D.register_keyspace db "test_get_keys_ranges" in

    let expect ?first ?up_to expected =
      lwt actual = D.get_keys ks "tbl" (rev_key_range ?first ?up_to ()) in
      let range = rev_key_range ?first ?up_to () in
        aeq_string_list
          ~msg:(sprintf "range %s" (string_of_key_range range))
          expected actual;
        return ()
    in
      expect [] >>
      put_slice ks "tbl"
        ["a", ["x", ""]; "c", ["c", ""]; "d", ["d", ""]] >>
      D.read_committed_transaction ks
        (fun tx ->
           expect [ "d"; "c"; "a"] >>
           expect ~up_to:"b" ["d"; "c"] >>
           expect ~up_to:"a" ["d"; "c"; "a"] >>
           expect ~first:"c" ["a"] >>
           put_slice ks "tbl" ["e", ["ee", "eee"]] >>
           D.delete_columns tx "tbl" "d" ["d"] >>
           expect ~up_to:"b" ["e"; "c"] >>
           expect ~first:"e" ["c"; "a"] >>
           expect ~first:"e" ~up_to:"b" ["c"] >>
           expect ~first:"e" ~up_to:"a" ["c"; "a"] >>
           expect ~first:"e" ~up_to:"e" []) >>
      (* now after commit *)
      D.read_committed_transaction ks
        (fun tx ->
           expect ~up_to:"b" ["e"; "c"] >>
           expect ~first:"e" ["c"; "a"] >>
           expect ~first:"e" ~up_to:"b" ["c"] >>
           expect ~first:"e" ~up_to:"a" ["c"; "a"] >>
           expect ~first:"e" ~up_to:"e" [])

  let test_get_keys_with_del_put db =
    lwt ks = D.register_keyspace db "test_get_keys_with_del_put" in
    let key_name i = sprintf "%03d" i in
      get_key_range ks "tbl" >|= aeq_string_list [] >>
      put_slice ks "tbl"
        (List.init 5 (fun i -> (key_name i, [ "x", "" ]))) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_key_range ks "tbl" >|= aeq_string_list (List.init 5 key_name) >>
           D.delete_key tx "tbl" "001" >>
           D.delete_columns tx "tbl" "002" ["y"; "x"] >>
           D.delete_columns tx "tbl" "003" ["y"; "x"] >>
           put_slice ks "tbl" ["002", ["z", "z"]] >>
           get_key_range ks "tbl" >|= aeq_string_list ["000"; "002"; "004"]) >>
      get_key_range ks "tbl" >|= aeq_string_list ["000"; "002"; "004"]

  let test_get_keys_discrete db =
    lwt ks1 = D.register_keyspace db "test_get_keys_discrete" in
      get_keys ks1 "tbl" ["a"; "b"] >|= aeq_string_list [] >>
      D.read_committed_transaction ks1
        (fun tx ->
           Lwt_list.iter_s (fun k -> put tx "tbl" k ["x", ""])
             [ "a"; "b"; "c"; "d" ]) >>
      get_keys ks1 "tbl" ["a"; "b"; "d"] >|= aeq_string_list ["a"; "b"; "d"] >>
      get_keys ks1 "tbl" ["c"; "x"; "b"] >|= aeq_string_list ["b"; "c"] >>
      begin try_lwt
        D.read_committed_transaction ks1
          (fun tx ->
             delete tx "tbl" "b" ["x"] >>
             delete tx "tbl" "d" ["x"] >>
             put tx "tbl" "x" ["x", ""] >>
             get_keys ks1 "tbl" ["a"; "d"; "x"] >|=
               aeq_string_list ~msg:"data in transaction" ["a"; "x" ] >>
             raise Exit)
      with Exit -> return () end >>
      get_keys ks1 "tbl" ["c"; "x"; "b"] >|= aeq_string_list ["b"; "c"]

  let test_get_keys_max_keys db =
    lwt ks = D.register_keyspace db "test_get_keys_max_keys" in
    let key_name i = sprintf "%03d" i in
      put_slice ks "tbl"
        (List.init 10 (fun i -> (key_name i, [ "x", ""; "y", "" ]))) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_key_range ks "tbl" >|=
             aeq_string_list (List.init 10 key_name) >>
           get_key_range ks "tbl" ~first:"002" ~max_keys:2 >|=
             aeq_string_list ["002"; "003"] >>
           get_key_range ks "tbl" ~last:"002" ~max_keys:5 >|=
             aeq_string_list ["000"; "001"; "002"] >>
           get_key_range ks "tbl" ~first:"008" ~max_keys:5 >|=
             aeq_string_list ["008"; "009"] >>
           D.delete_key tx "tbl" "001" >>
           D.delete_columns tx "tbl" "003" ["x"; "y"] >>
           D.delete_columns tx "tbl" "002" ["xxxx"] >>
           get_key_range ks "tbl" ~max_keys:3 >|=
             aeq_string_list ["000"; "002"; "004"]) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_key_range ks "tbl" ~max_keys:4 >|=
             aeq_string_list ["000"; "002"; "004"; "005"])

  let test_count_keys db =
    lwt ks1 = D.register_keyspace db "test_get_keys_ranges" in
    lwt ks2 = D.register_keyspace db "test_get_keys_ranges2" in

    let count_key_range ks ?first ?last tbl =
      D.read_committed_transaction ks
        (fun tx -> D.count_keys tx tbl (key_range ?first ?last ())) in

    let aeq_nkeys ks ?first ?last tbl expected =
      let msg =
        sprintf
          "number of keys for %s" (string_of_key_range (key_range ?first ?last ()))
      in
        count_key_range ks tbl ?first ?last >|= Int64.to_int >|= aeq_int ~msg expected in

      aeq_nkeys ks1 "tbl1" 0 >>
      aeq_nkeys ks2 "tbl1" 0 >>

      D.read_committed_transaction ks1
        (fun tx ->
           Lwt_list.iter_s
             (fun k -> put tx "tbl1" k ["name", k])
             ["a"; "ab"; "b"; "cde"; "d"; "e"; "f"; "g"]) >>

      aeq_nkeys ks2 "tbl1" 0 >>
      aeq_nkeys ks1 "tbl1" 8 >> (* ["a"; "ab"; "b"; "cde"; "d"; "e"; "f"; "g"] *)
      aeq_nkeys ks1 "tbl1" ~last:"c" 3 >> (* ["a"; "ab"; "b"; ] *)
      aeq_nkeys ks1 "tbl1" ~first:"c" ~last:"c" 0 >>
      aeq_nkeys ks1 "tbl1" ~first:"c" ~last:"f" 4 >> (* [ "cde"; "d"; "e"; "f" ] *)
      aeq_nkeys ks1 "tbl1" ~first:"b" 6 >> (* [ "b"; "cde"; "d"; "e"; "f"; "g" ] *)

      D.read_committed_transaction ks1
        (fun tx ->
           put tx "tbl1" "fg" ["x", ""] >>
           put tx "tbl1" "x" ["x", ""] >>
           aeq_nkeys ks1 "tbl1" ~first:"e" 5 >> (* [ "e"; "f"; "fg"; "g"; "x" ] *)
           aeq_nkeys ks1 "tbl1" ~first:"f" ~last:"g" 3 >> (* [ "f"; "fg"; "g"; ] *)
           begin try_lwt
             D.read_committed_transaction ks1
               (fun tx ->
                  D.delete_columns tx "tbl1" "fg" ["x"] >>
                  D.delete_columns tx "tbl1" "xx" ["x"] >>
                  put tx "tbl1" "fgh" ["x", ""] >>
                  put tx "tbl1" "xx" ["x", ""] >>
                  aeq_nkeys ks1 "tbl1" ~first:"f" 5 >> (* [ "f"; "fgh"; "g"; "x"; "xx" ] *)
                  raise Exit)
           with Exit -> return ()
           end >>
           aeq_nkeys ks1 "tbl1" ~first:"e" 5) (* [ "e"; "f"; "fg"; "g"; "x" ] *)

  let tuple_to_slice (last_key, data) =
    (last_key,
     List.map
       (fun (key, last_column, cols) ->
          { DM.key; last_column; columns = List.map rd_col cols })
       data)

  let aeq_slice ?msg expected actual =
    aeq ?msg string_of_slice (tuple_to_slice expected) actual

  let get_slice tx table ?max_keys ?max_columns ?decode_timestamps
        key_range ?predicate col_range =
    match predicate with
        None ->
          lwt x =
            D.get_slice tx table ?max_keys ?max_columns ?decode_timestamps
              key_range col_range in
          (* check we get same results with dummy predicate (always true) *)
          let predicate = [[DM.At_least min_int]] in
          lwt x' =
            D.get_slice tx table ?max_keys ?max_columns ?decode_timestamps
              ~predicate
              key_range col_range
          in
            aeq ~msg:"Slice with dummy predicate is wrong"
              string_of_slice x x';
            return x
      | Some p ->
          D.get_slice tx table ?max_keys ?max_columns ?decode_timestamps
            key_range ?predicate col_range

  let string_of_slice_columns (last_key, l) =
    sprintf "(%s, %s)"
      (string_of_option (sprintf "%S") last_key)
      (string_of_list
         (string_of_tuple2
            (sprintf "%S")
            (string_of_list (string_of_option (sprintf "%S"))))
         l)

  let aeq_slice_columns ?msg x actual =
    aeq ?msg string_of_slice_columns x actual

  let test_get_slice_discrete db =
    lwt ks = D.register_keyspace db "test_get_slice_discrete" in
      put_slice ks "tbl"
        [
         "a", ["k", "kk"; "v", "vv"];
         "b", ["k1", "kk1"; "v", "vv1"];
         "c", ["k2", "kk2"; "w", "ww"];
        ] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" (DM.Keys ["a"; "c"]) DM.All_columns >|=
             aeq_slice
               (Some "c",
                ["a", "v", [ "k", "kk"; "v", "vv" ];
                 "c", "w", [ "k2", "kk2"; "w", "ww" ]]) >>
           delete tx "tbl" "a" ["v"] >>
           delete tx "tbl" "c" ["k2"] >>
           put tx "tbl" "a" ["v2", "v2"] >>
           get_slice tx "tbl" (DM.Keys ["a"; "c"]) DM.All_columns >|=
             aeq_slice
               (Some "c",
                ["a", "v2", [ "k", "kk"; "v2", "v2"; ];
                 "c", "w", [ "w", "ww" ]])) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" (DM.Keys ["a"; "c"]) DM.All_columns >|=
             aeq_slice
               (Some "c",
                ["a", "v2", [ "k", "kk"; "v2", "v2"; ];
                 "c", "w", [ "w", "ww" ]]))

  let test_get_slice_discrete_rev_col_range db =
    lwt ks = D.register_keyspace db "test_get_slice_discrete_rev_col_range" in

    let expect tx =
      get_slice tx "tbl"
        (DM.Keys ["08"; "01"])
        (col_range ~reverse:true ~first:"8" ~up_to:"6" ()) >|=
      aeq_slice (Some "08", ["01", "6", ["7", ""; "6", ""];
                             "08", "6", ["7", ""; "6", ""]]) >>
      get_slice tx "tbl" ~max_columns:1
        (DM.Keys ["08"; "01"])
        (col_range ~reverse:true ~first:"8" ~up_to:"6" ()) >|=
      aeq_slice (Some "08", ["01", "7", ["7", ""];
                             "08", "7", ["7", ""]])
    in
        D.read_committed_transaction ks
          (fun tx ->
             put_slice ks "tbl"
               (List.init 10
                  (fun i -> (sprintf "%02d" i,
                             List.init 10 (fun i -> string_of_int i, "")))) >>
             expect tx) >>
        D.read_committed_transaction ks expect

  let test_get_slice_key_range db =
    lwt ks = D.register_keyspace db "test_get_slice_key_range" in
    let all = DM.All_columns in
      put_slice ks "tbl"
        [
         "a", ["k", "kk"; "v", "vv"];
         "b", ["k1", "kk1"; "v", "vv1"];
         "c", ["k2", "kk2"; "w", "ww"];
        ] >>
      D.read_committed_transaction ks
        (fun tx ->
           let expect1 =
             aeq_slice
               (Some "b",
                [ "a", "v", [ "k", "kk"; "v", "vv"; ];
                  "b", "v", [ "k1", "kk1"; "v", "vv1" ]])
           in
             get_slice tx "tbl" (key_range ~first:"a" ~last:"b" ()) all >|= expect1 >>
             get_slice tx "tbl" (key_range ~last:"b" ()) all >|= expect1 >>
             get_slice tx "tbl" (key_range ~first:"b" ~last:"c" ())
               (columns ["k1"; "w"]) >|=
               aeq_slice
               (Some "c",
                [ "b", "k1", [ "k1", "kk1" ];
                  "c", "w", [ "w", "ww" ] ]))

  let test_get_slice_key_range_reverse db =
    lwt ks = D.register_keyspace db "test_get_slice_key_range_reverse" in
    let all = DM.All_columns in
    let expect1 tx =
      let e1 =
        aeq_slice
          (Some "a",
           [
             "b", "k1", [ "v", "vv1"; "k1", "kk1"; ];
             "a", "k", [ "v", "vv"; "k", "kk"; ];])
      in
        get_slice tx "tbl"
          (rev_key_range ~first:"c" ~up_to:"" ()) all >|= e1 >>
        get_slice tx "tbl" (rev_key_range ~first:"c" ()) all >|= e1 >>
        get_slice tx "tbl" (rev_key_range ~up_to:"b" ())
          (columns ["k1"; "w"]) >|=
          aeq_slice (Some "b", [ "c", "w", [ "w", "ww" ];
                                 "b", "k1", [ "k1", "kk1" ];]) >>
        (* reverse key range, normal col_range *)
        get_slice tx "tbl"
          (rev_key_range ~first:"b" ())
          (col_range ~first:"a" ~up_to:"x" ()) >|=
          aeq_slice (Some "a", [ "a", "k", [ "v", "vv"; "k", "kk" ] ])
    in
      D.read_committed_transaction ks
        (fun tx ->
           put_slice ks "tbl"
             [
               "a", ["k", "kk"; "v", "vv"];
               "b", ["k1", "kk1"; "v", "vv1"];
               "c", ["k2", "kk2"; "w", "ww"]
             ] >>
           expect1 tx) >>
      D.read_committed_transaction ks expect1 >>
      D.read_committed_transaction ks
        (fun tx ->
           put_slice ks "tbl" [ "a", ["k", "new"] ] >>
           get_slice tx "tbl"
             (rev_key_range ~first:"b" ~up_to:"a" ())
             DM.All_columns >|=
           aeq_slice (Some "a", [ "a", "k", [ "v", "vv"; "k", "new" ] ]))

  let test_get_slice_max_keys db =
    lwt ks = D.register_keyspace db "test_get_slice_max_keys" in
    let all = DM.All_columns in
      put_slice ks "tbl"
        (List.init 100 (fun i -> (sprintf "%03d" i, [ "x", "" ]))) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" ~max_keys:2 (key_range ()) all >|=
             aeq_slice
               (Some "001", [ "000", "x", ["x", ""]; "001", "x", ["x", ""]]) >>
           get_slice tx "tbl" ~max_keys:2 (key_range ~first:"002" ()) all >|=
             aeq_slice
               (Some "003", [ "002", "x", ["x", ""]; "003", "x", ["x", ""]]) >>
           D.delete_columns tx "tbl" "002" ["x"] >>
           get_slice tx "tbl" ~max_keys:2 (key_range ~first:"002" ()) all >|=
             aeq_slice
               (Some "004", [ "003", "x", ["x", ""]; "004", "x", ["x", ""]]) >>
           put_slice ks "tbl" [ "002", [ "y", "" ] ] >>
           get_slice tx "tbl" ~max_keys:2 (key_range ~first:"002" ()) all >|=
             aeq_slice
               (Some "003", [ "002", "y", ["y", ""]; "003", "x", ["x", ""]]) >>
           get_slice tx "tbl" ~max_keys:1 (DM.Keys ["001"; "002"])
             (columns ["y"]) >|=
             aeq_slice (Some "002", [ "002", "y", ["y", ""] ])) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" ~max_keys:2 (key_range ~first:"002" ()) all >|=
             aeq_slice
               (Some "003", [ "002", "y", ["y", ""]; "003", "x", ["x", ""]]) >>
           D.delete_columns tx "tbl" "002" ["y"] >>
           put_slice ks "tbl" [ "002", ["x", ""] ] >>
           get_slice tx "tbl" ~max_keys:1000 (key_range ()) all >|=
             aeq_slice
               (Some "099",
                List.init 100
                  (fun i -> (sprintf "%03d" i, "x", ["x", ""]))) >>
           get_slice tx "tbl" ~max_keys:2 (DM.Keys ["003"; "001"; "002"]) all >|=
             aeq_slice (Some "002",
                        [ "001", "x", ["x", ""];
                          "002", "x", ["x", ""]]))

  let test_get_slice_max_columns db =
    lwt ks = D.register_keyspace db "test_get_slice_max_columns" in
      put_slice ks "tbl"
        (List.init 10
           (fun i -> (sprintf "%02d" i,
                      List.init 10 (fun i -> string_of_int i, "")))) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" ~max_keys:2 ~max_columns:2
             (key_range ()) DM.All_columns >|=
             aeq_slice
               (Some "01", ["00", "1", ["0", ""; "1", ""];
                            "01", "1", ["0", ""; "1", ""]]) >>
           get_slice tx "tbl" ~max_keys:2 ~max_columns:1
             (key_range ()) (columns ["2"; "1"]) >|=
             aeq_slice
               (Some "01", ["00", "1", ["1", ""]; "01", "1", ["1", ""]]) >>
           D.delete_columns tx "tbl" "01" ["1"; "2"] >>
           get_slice tx "tbl" ~max_keys:2 ~max_columns:3
             (key_range ()) (columns ["2"; "1"; "0"]) >|=
             aeq_slice
               (Some "01", ["00", "2", ["0", ""; "1", ""; "2", ""];
                            "01", "0", ["0", ""]]) >>
           put_slice ks "tbl" [ "01",  ["10", "a"; "11", "b"] ] >>
           get_slice tx "tbl" ~max_keys:2 ~max_columns:3
             (key_range ()) DM.All_columns >|=
             aeq_slice
               (Some "01", ["00", "2", ["0", ""; "1", ""; "2", ""];
                            "01", "11", ["0", ""; "10", "a"; "11", "b"]]) >>
           get_slice tx "tbl" ~max_keys:2 ~max_columns:3
             (key_range ()) (columns ["2"; "1"; "0"]) >|=
             aeq_slice ~msg:"all keys, Columns 2, 1, 0"
               (Some "01", ["00", "2", ["0", ""; "1", ""; "2", ""];
                            "01", "0", ["0", ""]])) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" ~max_keys:2 ~max_columns:3
             (key_range ()) DM.All_columns >|=
             aeq_slice
               (Some "01", ["00", "2", ["0", ""; "1", ""; "2", ""];
                            "01", "11", ["0", ""; "10", "a"; "11", "b"]]) >>
           get_slice tx "tbl" ~max_keys:2 ~max_columns:3
             (DM.Keys ["01"; "00"]) (columns ["2"; "1"; "0"; "10"]) >|=
             aeq_slice
               (Some "01", ["00", "2", ["0", ""; "1", ""; "2", ""];
                            "01", "10", ["0", ""; "10", "a"]]))

  let test_get_slice_column_ranges db =
    lwt ks = D.register_keyspace db "test_get_slice_column_ranges" in
    let expect tx =
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (col_range ~first:"5" ~last:"6" ()) >|=
        aeq_slice (Some "02", ["02", "6", ["5", ""; "6", ""]]) >>
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (col_range ~reverse:true ~first:"7" ~up_to:"5" ()) >|=
        aeq_slice (Some "02", ["02", "6", ["5", ""; "6", ""]]) >>
      get_slice tx "tbl" ~max_keys:1 ~max_columns:1
        (key_range ~first:"02" ())
        (col_range ~first:"5" ~last:"6" ()) >|=
        aeq_slice (Some "02", ["02", "5", ["5", ""]]) >>
      get_slice tx "tbl" ~max_keys:1 ~max_columns:1
        (key_range ~first:"02" ())
        (col_range ~first:"50" ~last:"6" ()) >|=
          aeq_slice (Some "02", ["02", "6", ["6", ""]]) >>
      get_slice tx "tbl" ~max_keys:1 ~max_columns:1
        (key_range ~first:"02" ())
        (col_range ~first:"7" ~last:"6" ()) >|=
          aeq_slice (None, []) >>
      get_slice tx "tbl" ~max_keys:1 ~max_columns:1
        (rev_key_range ~first:"02" ())
        (col_range ~first:"6" ~up_to:"7" ()) >|=
          aeq_slice (Some "01", ["01", "6", ["6", ""]]) >>
      get_slice tx "tbl" ~max_keys:2 ~max_columns:1
        (rev_key_range ~first:"02" ())
        (col_range ~reverse:true ~first:"7" ~up_to:"6" ()) >|=
          aeq_slice (Some "00", ["01", "6", ["6", ""];
                                 "00", "6", ["6", ""]]) >>
      get_slice tx "tbl" ~max_keys:3 ~max_columns:3
        (rev_key_range ~first:"02" ())
        (col_range ~reverse:true ~up_to:"8" ()) >|=
          aeq_slice (Some "00", ["01", "8", ["9", ""; "8", ""];
                                 "00", "8", ["9", ""; "8", ""]])
    in
      D.read_committed_transaction ks
        (fun tx ->
           put_slice ks "tbl"
             (List.init 10
                (fun i -> (sprintf "%02d" i,
                           List.init 10 (fun i -> string_of_int i, "")))) >>
           expect tx) >>
      D.read_committed_transaction ks expect

  let test_get_slice_column_range_union db =
    lwt ks = D.register_keyspace db "test_get_slice_column_range_union" in
    let expect tx =
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (DM.Column_range_union
           [ col_range_ ~first:"2" ~last:"3" ();
             col_range_ ~first:"7" ~last:"99" () ]) >|=
        aeq_slice (Some "02",
                   ["02", "9", ["2", ""; "3", ""; "7", ""; "8", ""; "9", ""]]) >>
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (DM.Column_range_union
           [ col_range_ ~first:"7" ~last:"99" ();
             col_range_ ~first:"2" ~last:"3" (); ]) >|=
        aeq_slice (Some "02",
                   ["02", "9", ["2", ""; "3", ""; "7", ""; "8", ""; "9", ""]]) >>
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (DM.Column_range_union
           [ col_range_ ~first:"7" ~last:"99" ();
             columns_ ["3"; "2"] ]) >|=
        aeq_slice (Some "02",
                   ["02", "9", ["2", ""; "3", ""; "7", ""; "8", ""; "9", ""]]) >>
      get_slice tx "tbl" ~max_keys:1
        (key_range ~first:"02" ~last:"03" ())
        (DM.Column_range_union
           [ col_range_ ~first:"7" ~last:"99" ();
             columns_ ["2"]; columns_ ["3"] ]) >|=
        aeq_slice (Some "02",
                   ["02", "9", ["2", ""; "3", ""; "7", ""; "8", ""; "9", ""]]) >>
      get_slice tx "tbl" ~max_keys:1
        (rev_key_range ~first:"03" ~up_to:"01" ())
        (DM.Column_range_union
           [ col_range_ ~first:"7" ~last:"99" ();
             columns_ ["2"]; columns_ ["3"] ]) >|=
        aeq_slice (Some "02",
                   ["02", "2", ["9", ""; "8", ""; "7", ""; "3", ""; "2", ""]])
    in
      D.read_committed_transaction ks
        (fun tx ->
           put_slice ks "tbl"
             (List.init 10
                (fun i -> (sprintf "%02d" i,
                           List.init 10 (fun i -> string_of_int i, "")))) >>
           expect tx >>
           begin try_lwt
             D.read_committed_transaction tx
               (fun tx ->
                  D.delete_columns tx "tbl" "02" (List.init 10 string_of_int) >>
                  let get () =
                    get_slice tx "tbl" ~max_keys:1
                      (rev_key_range ~first:"03" ~up_to:"01" ())
                      (DM.Column_range_union
                         [ col_range_ ~first:"7" ~last:"99" ();
                           columns_ ["2"]; columns_ ["3"] ])
                  in
                    get () >|=
                      aeq_slice (Some "01",
                                 ["01", "2", ["9", ""; "8", ""; "7", "";
                                              "3", ""; "2", ""]]) >>
                    put_slice tx "tbl" ["02", ["7", "x"]] >>
                    get () >|= aeq_slice (Some "02", ["02", "7", ["7", "x"]]) >>
                    raise_lwt Exit)
           with Exit -> return ()
           end) >>
      D.read_committed_transaction ks expect

  let test_get_slice_nested_transactions db =
    lwt ks = D.register_keyspace db "test_get_slice_nested_transactions" in
    let all = DM.All_columns in
      put_slice ks "tbl"
        [
          "a", [ "c1", ""; "c2", "" ];
          "b", [ "c1", ""; "c2", "" ];
          "c", [ "c1", ""; "c2", "" ];
        ] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" (key_range ~first:"b" ()) all >|=
             aeq_slice (Some "c",
                        ["b", "c2", [ "c1", ""; "c2", "" ];
                         "c", "c2",  [ "c1", ""; "c2", "" ]]) >>
           put_slice ks "tbl" ["a", ["c4", "c4"]] >>
           begin try_lwt
             D.read_committed_transaction ks
               (fun tx ->
                  delete tx "tbl" "b" ["c1"; "c2"] >>
                  delete tx "tbl" "c" ["c2"] >>
                  put_slice ks "tbl" ["c", ["c3", "c3"]] >>
                  get_slice tx "tbl" (key_range ()) all >|=
                    aeq_slice
                      ~msg:"nested tx data"
                      (Some "c",
                       ["a", "c4", ["c1", ""; "c2", ""; "c4", "c4"];
                        "c", "c3", ["c1", ""; "c3", "c3"]]) >>
                  raise Exit)
           with Exit -> return () end >>
           get_slice tx "tbl" (key_range ()) all >|=
             aeq_slice ~msg:"after aborted transaction"
               (Some "c",
                ["a", "c4", ["c1", ""; "c2", ""; "c4", "c4"];
                 "b", "c2", ["c1", ""; "c2", ""];
                 "c", "c2", ["c1", ""; "c2", ""]]))

  let test_get_slice_read_tx_data db =
    lwt ks = D.register_keyspace db "test_get_slice_read_tx_data" in
      put_slice ks "tbl" [ "a", ["0", ""; "1", ""]; "b", ["0", ""; "1", ""] ] >>
      D.read_committed_transaction ks
        (fun tx ->
           put_slice ks "tbl" [ "a", ["00", ""]; "b", [ "10", ""] ] >>
           get_slice tx "tbl" (key_range ()) DM.All_columns >|=
             aeq_slice
               (Some "b", ["a", "1", ["0", ""; "00", ""; "1", ""];
                           "b", "10", ["0", ""; "1", ""; "10", ""]]) >>
           get_slice tx "tbl" (key_range ()) (columns ["0"; "00"]) >|=
             aeq_slice ~msg:"key range"
               (Some "b", ["a", "00", ["0", ""; "00", ""];
                           "b", "0", ["0", ""]]) >>
           get_slice tx "tbl" (DM.Keys ["a"; "b"]) (columns ["0"; "00"]) >|=
             aeq_slice ~msg:"discrete keys"
               (Some "b", ["a", "00", ["0", ""; "00", ""];
                           "b", "0", ["0", ""]]))

  (* check that iteration over datum keys is performed correctly
   *   key "foo"  column "\0001"
   * should precede
   *   key "foo\000" column "0"
   * *)
  let test_get_slice_tricky_columns db =
    lwt ks = D.register_keyspace db "test_get_slice_tricky_columns" in
      put_slice ks "tbl"
        [ "k", [ "\0003", "" ];
          "k\000", [ "2", "" ] ] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" (DM.Keys ["k"]) DM.All_columns >|=
             aeq_slice (Some "k", [ "k", "\0003", [ "\0003", "" ] ]) >>
           get_slice tx "tbl" (DM.Keys ["k\000"]) DM.All_columns >|=
             aeq_slice (Some "k\000", [ "k\000", "2", [ "2", "" ] ]))

  let test_get_slice_with_keyspaces db =
    lwt ks1 = D.register_keyspace db "test_get_slice_with_keyspaces" in
    lwt ks2 = D.register_keyspace db "test_get_slice_with_keyspaces2" in
      put_slice ks1 "tbl" [ "a", ["x", "y"] ] >>
      put_slice ks2 "tbl" [ "b", ["w", "z"] ] >>
      D.read_committed_transaction ks1
        (fun tx ->
           get_slice tx "tbl" (key_range ()) DM.All_columns >|=
           aeq_slice (Some "a", ["a", "x", ["x", "y"]]))

  let test_get_slice_values db =
    lwt ks = D.register_keyspace db "test_get_slice_values" in
    let add_data () =
      put_slice ks "tbl"
        [ "a", (List.init 10 (fun n -> (sprintf "%d" n, sprintf "a%d" n)));
          "b", ["0", "b0"; "3", "b3"];
          "c", ["1", "c1"] ] in
    let assertions tx =
      D.get_slice_values tx "tbl" (DM.Keys ["a"; "b"]) ["0"; "1"] >|=
        aeq_slice_columns
          (Some "b", ["a", [Some "a0"; Some "a1"];
                      "b", [Some "b0"; None]]) >>
      D.get_slice_values tx "tbl" (DM.Keys ["a"; "b"]) ["1"] >|=
        aeq_slice_columns
          (Some "b", ["a", [Some "a1"];
                      "b", [None]]) >>
      D.get_slice_values tx "tbl" (key_range ()) ["0"; "2"] >|=
        aeq_slice_columns
          (Some "c", ["a", [Some "a0"; Some "a2"];
                      "b", [Some "b0"; None];
                      "c", [None; None]])
    in
      D.read_committed_transaction ks (fun tx -> add_data () >> assertions tx) >>
      (* also after commit *)
      D.read_committed_transaction ks assertions

  let test_get_column_values db =
    lwt ks = D.register_keyspace db "test_get_column_values" in
    let aeq ?msg =
      aeq ?msg (string_of_list (string_of_option (sprintf "%S")))
    in
      put_slice ks "tbl"
        [ "a", [ "0", ""; "1", "1"; "3", "" ] ] >>
      D.read_committed_transaction ks
        (fun tx ->
           D.get_column_values tx "tbl" "a" ["1"; "2"; "0"] >|=
             aeq [Some "1"; None; Some ""] >>
           D.get_column_values tx "tbl" "b" ["1"] >|=
             aeq [None] >>
           put_slice ks "tbl" [ "b", [ "1", "b1" ] ] >>
           D.get_column_values tx "tbl" "b" ["1"; "2"] >|=
             aeq [Some "b1"; None]) >>
      D.read_committed_transaction ks
        (fun tx ->
           D.get_column_values tx "tbl" "b" ["1"; "2"] >|=
             aeq [Some "b1"; None])

  let test_delete_key db =
    lwt ks = D.register_keyspace db "test_delete_key" in
    let get_all tx = get_slice tx "tbl" (key_range ()) DM.All_columns in
      put_slice ks "tbl"
        [ "a", [ "x", ""; "y", ""; "z", "" ];
          "b", [ "x", ""; "y", ""; "z", "" ]] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_all tx >|=
             aeq_slice ~msg:"before delete"
               (Some "b",
                [ "a", "z", [ "x", ""; "y", ""; "z", "" ];
                  "b", "z", [ "x", ""; "y", ""; "z", "" ]]) >>
           D.delete_key tx "tbl" "b" >>
           let expect_after_del msg =
             aeq_slice ~msg
               (Some "a",
                [ "a", "z", [ "x", ""; "y", ""; "z", "" ]])
           in get_all tx >|= expect_after_del "with key range">>
              get_slice tx "tbl" (DM.Keys ["a"; "b"]) DM.All_columns >|=
                expect_after_del "with discrete keys") >>
      D.read_committed_transaction ks
        (fun tx ->
           get_all tx >|=
             aeq_slice ~msg:"after delete, after transaction commit"
               (Some "a", [ "a", "z", [ "x", ""; "y", ""; "z", "" ]]))

  let get_all tx tbl =
    get_slice tx tbl (key_range ()) DM.All_columns

  let test_delete_columns db =
    lwt ks = D.register_keyspace db "test_delete_columns" in
      put_slice ks "tbl"
        [ "a", [ "x", ""; "y", ""; "z", "" ];
          "b", [ "x", ""; "y", ""; "z", "" ]] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_all tx "tbl" >|=
             aeq_slice ~msg:"before delete_columns"
               (Some "b",
                [ "a", "z", [ "x", ""; "y", ""; "z", "" ];
                  "b", "z", [ "x", ""; "y", ""; "z", "" ]]) >>
           D.delete_columns tx "tbl" "a" ["x"; "z"] >>
           D.delete_columns tx "tbl" "b" ["x"; "y"; "z"] >>
           get_all tx "tbl" >|=
             aeq_slice ~msg:"after delete, in transaction"
               (Some "a", ["a", "y", ["y", ""]])) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_all tx "tbl" >|=
             aeq_slice ~msg:"after transaction commit"
               (Some "a", ["a", "y", ["y", ""]]))

  let test_put_columns db =
    lwt ks = D.register_keyspace db "test_put_columns" in
      put_slice ks "tbl"
        [ "a", [ "x", ""; "y", ""; "z", "" ];
          "b", [ "x", ""; "y", ""; "z", "" ]] >>
      put_slice ks "tbl"
        [ "a", [ "x", "x"; "zz", ""];
          "c", [ "z", ""] ] >>
      D.read_committed_transaction ks
        (fun tx ->
           get_all tx "tbl" >|=
             aeq_slice
               (Some "c",
                [ "a", "zz", [ "x", "x"; "y", ""; "z", ""; "zz", "" ];
                  "b", "z", [ "x", ""; "y", ""; "z", "" ];
                  "c", "z", [ "z", "" ]]) >>
           put_slice ks "tbl" [ "c", ["c", "c"]] >>
           get_slice tx "tbl" (DM.Keys ["c"]) DM.All_columns >|=
             aeq_slice (Some "c", [ "c", "z", ["c", "c"; "z", ""] ])) >>
      D.read_committed_transaction ks
        (fun tx ->
           get_slice tx "tbl" (DM.Keys ["c"]) DM.All_columns >|=
             aeq_slice (Some "c", [ "c", "z", ["c", "c"; "z", ""] ]))

  let test_with_db f () = C.with_db f

  let tests =
    List.map (fun (n, f) -> n >:: test_with_db f)
    [
      "custom comparator", test_custom_comparator;
      "custom comparator (2)", test_custom_comparator_non_datum;
      "datum key encoding", test_datum_key_encoding;
      "keyspace management", test_keyspace_management;
      "list tables", test_list_tables;
      "list tables with diff keyspaces", test_list_tables_with_keyspaces;
      "get_keys ranges", test_get_keys_ranges;
      "get_keys reverse ranges", test_get_keys_reverse_ranges;
      "get_keys discrete keys", test_get_keys_discrete;
      "get_keys honors max_keys", test_get_keys_max_keys;
      "get_keys with delete/put", test_get_keys_with_del_put;
      "count_keys", test_count_keys;
      "get_slice discrete", test_get_slice_discrete;
      "get_slice discrete reverse col range", test_get_slice_discrete_rev_col_range;
      "get_slice key range", test_get_slice_key_range;
      "get_slice reverse key range", test_get_slice_key_range_reverse;
      "get_slice honors max_keys", test_get_slice_max_keys;
      "get_slice nested transactions", test_get_slice_nested_transactions;
      "get_slice in open transaction", test_get_slice_read_tx_data;
      "get_slice honor max_columns", test_get_slice_max_columns;
      "get_slice with column ranges", test_get_slice_column_ranges;
      "get_slice with column range union", test_get_slice_column_range_union;
      "get_slice correct iteration with tricky columns", test_get_slice_tricky_columns;
      "get_slice with diff keyspaces", test_get_slice_with_keyspaces;
      "get_slice_values", test_get_slice_values;
      "get_column_values", test_get_column_values;
      "put_columns", test_put_columns;
      "delete_key", test_delete_key;
      "delete_columns", test_delete_columns;
    ]

  let () =
    register_tests (C.id ^ " Data_model") tests
end


