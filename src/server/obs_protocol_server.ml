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

open Lwt
open Obs_data_model
open Obs_protocol
open Obs_request

let data_protocol_version = (0, 0, 0)

module Make
  (D : sig
     include Obs_data_model.S
     include Obs_data_model.BACKUP_SUPPORT with type backup_cursor := backup_cursor
     val use_thread_pool : db -> bool -> unit
   end)
  (P : PAYLOAD) =
struct
  open Request

  exception Abort_exn
  exception Commit_exn

  module H = Hashtbl.Make(struct
                            type t = int
                            let hash n = n
                            let equal a b = (a == b)
                          end)

  module Notif_queue : sig
    type 'a t
    val empty : 'a t
    val push : 'a -> 'a t -> 'a t
    val iter : ('a -> unit) -> 'a t  -> unit
  end =
  struct
    type 'a t = 'a list

    let empty = []

    (* TODO: further "compression" by keeping set of previous notifications? *)
    let push x = function
        y :: _ as l when y = x -> l
      | l -> x :: l

    let iter f t = List.iter f (List.rev t)
  end

  let num_clients = ref 0

  let dummy_auto_yield () = return ()

  let auto_yielder = ref dummy_auto_yield

  type client_id = int
  type topic = string
  type keyspace_name = string

  type subscription_descriptor = { subs_ks : keyspace_name; subs_topic : topic }

  type subs_stream = string Lwt_stream.t * (string option -> unit)
  type mutable_string_set = (string, unit) Hashtbl.t

  type t =
      {
        db : D.db;
        subscriptions : (subscription_descriptor, subs_stream H.t) Hashtbl.t;
        rev_subscriptions :
          (keyspace_name, subs_stream * mutable_string_set) Hashtbl.t H.t;
        raw_dumps : (Int64.t, D.Raw_dump.raw_dump) Hashtbl.t;
        mutable raw_dump_seqno : Int64.t;
      }

  type client_state =
      {
        id : client_id;
        keyspaces : D.keyspace H.t;
        rev_keyspaces : int H.t;
        ich : Lwt_io.input_channel;
        och : Lwt_io.output_channel;
        server : t;
        mutable in_buf : string;
        out_buf : Obs_bytea.t;
        debug : bool;
        mutable pending_reqs : int;
        wait_for_pending_reqs : unit Lwt_condition.t;
        async_req_region : Lwt_util.region;
      }

  type tx_data =
      {
        mutable tx_notifications : string Notif_queue.t;
      }

  let tx_key = Lwt.new_key ()

  let find_or_add find add h k =
    try find h k with Not_found -> add h k

  let read_exactly c n =
    let s = String.create n in
      Lwt_io.read_into_exactly c.ich s 0 n >>
      return s

  (* the chunk of the region needed to perform a given request --- allows to
   * impose diff limits per type *)
  let request_slot_cost = function
      Load _ -> 100
    | _ -> 1

  let with_raw_dump c id default f =
    try_lwt
      let raw_dump = Hashtbl.find c.server.raw_dumps id in
        f raw_dump
    with Not_found -> return default

  let rec service c =
    !auto_yielder () >>
    lwt request_id, len, crc = read_header c.ich in
      match_lwt read_request c ~request_id len crc with
          None -> service c
        | Some r ->
            if Obs_protocol.is_sync_req request_id then begin
              begin try_lwt
                respond c ~buf:c.out_buf ~request_id r
              with
                | Abort_exn | Commit_exn | End_of_file as e -> raise_lwt e
                (* catch exns that indicate that the connection is gone,
                 * and signal End_of_file *)
                | Unix.Unix_error((Unix.ECONNRESET | Unix.EPIPE), _, _) ->
                    raise_lwt End_of_file
                | e ->
                Format.eprintf
                  "Internal error %s@\n\
                   request:@\n\
                   %a@."
                  (Printexc.to_string e)
                  Request.pp r;
                P.internal_error c.och ~request_id ()
              end >>
              service c
            end else begin
              ignore begin
                c.pending_reqs <- c.pending_reqs + 1;
                try_lwt
                  Lwt_util.run_in_region c.async_req_region
                    (request_slot_cost r)
                    (fun () -> respond c ~request_id r)
                finally
                  c.pending_reqs <- c.pending_reqs - 1;
                  if c.pending_reqs = 0 then
                    Lwt_condition.broadcast c.wait_for_pending_reqs ();
                  return ()
              end;
              (* here we block if the allowed number of async reqs is reached
               * until one of them is done *)
              Lwt_util.run_in_region c.async_req_region 1 (fun () -> return ()) >>
              service c
            end

  and read_request c ~request_id len crc =
    if String.length c.in_buf < len then c.in_buf <- String.create len;
    Lwt_io.read_into_exactly c.ich c.in_buf 0 len >>
    lwt crc2 = read_exactly c 4 in
    let crc2' = Obs_crc32c.substring c.in_buf 0 len in
    let gb n = Char.code c.in_buf.[n] in
    let format_id = gb 0 + (gb 1 lsl 8) + (gb 2 lsl 16) + (gb 3 lsl 24) in
      Obs_crc32c.xor crc2 crc;
      if crc2 <> crc2' then begin
        P.bad_request c.och ~request_id () >>
        return None
      end else begin
        match Obs_protocol_payload.Obs_request_serialization.of_format_id format_id with
            `Extprot -> begin
              let m =
                try Some (Extprot.Conv.deserialize Request.read ~offset:4 c.in_buf)
                with _ -> None
              in match m with
                  None -> P.bad_request c.och ~request_id () >> return None
                | Some _ as x -> return x
            end
          | `Raw -> P.bad_request c.och ~request_id () >> return None
          | `Unknown -> P.unknown_serialization c.och ~request_id () >> return None
      end

  and respond ?buf c ~request_id r =
    if c.debug then Format.eprintf "Got request from %d %a@." c.id Request.pp r;
    match r with
      Register_keyspace { Register_keyspace.name } ->
        lwt ks = D.register_keyspace c.server.db name in
        let idx =
          (* find keyspace idx in local table, register if not found *)
          try
            H.find c.rev_keyspaces (D.keyspace_id ks)
          with Not_found ->
            let idx = H.length c.keyspaces in
              H.add c.keyspaces idx ks;
              H.add c.rev_keyspaces (D.keyspace_id ks) idx;
              idx
        in
          P.return_keyspace ?buf c.och ~request_id idx
    | Get_keyspace { Get_keyspace.name; } -> begin
        match_lwt D.get_keyspace c.server.db name with
            None -> P.return_keyspace_maybe ?buf c.och ~request_id None
          | Some ks ->
              let idx =
                (* find keyspace idx in local table, register if not found *)
                try
                  H.find c.rev_keyspaces (D.keyspace_id ks)
                with Not_found ->
                  let idx = H.length c.keyspaces in
                    H.add c.keyspaces idx ks;
                    H.add c.rev_keyspaces (D.keyspace_id ks) idx;
                    idx
              in
                P.return_keyspace_maybe ?buf c.och ~request_id
                  (Some idx)
      end
    | List_keyspaces _ ->
        D.list_keyspaces c.server.db >>=
          P.return_keyspace_list ?buf c.och ~request_id
    | List_tables { List_tables.keyspace } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.list_tables ks >>=
             P.return_table_list ?buf c.och ~request_id)
    | Table_size_on_disk { Table_size_on_disk.keyspace; table; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.table_size_on_disk ks table >>=
             P.return_table_size_on_disk ?buf c.och ~request_id)
    | Key_range_size_on_disk { Key_range_size_on_disk.keyspace; table; range; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.key_range_size_on_disk ks table
               ?first:range.first ?up_to:range.up_to >>=
             P.return_key_range_size_on_disk ?buf c.och ~request_id)
    | Begin { Begin.keyspace; tx_type; } ->
        (* FIXME: check if we have an open tx in another ks, and signal error
         * if so *)
        let is_outermost, parent_tx_data, tx_data =
          match Lwt.get tx_key with
              None ->
                let d = { tx_notifications = Notif_queue.empty } in
                  (true, d, d)
            | Some d -> (false, d, { tx_notifications = d.tx_notifications; }) in
        let transaction_f = match tx_type with
            Tx_type.Repeatable_read -> D.repeatable_read_transaction
          | Tx_type.Read_committed -> D.read_committed_transaction
        in
          wait_for_pending_reqs c >>
          with_keyspace c keyspace ~request_id
            (fun ks ->
               try_lwt
                 lwt ret =
                   transaction_f ks
                     (fun ks ->
                        Lwt.with_value tx_key (Some tx_data)
                          (fun () ->
                             try_lwt
                               P.return_ok ?buf c.och ~request_id () >>
                               service c
                             with Commit_exn ->
                               wait_for_pending_reqs c >>
                               P.return_ok ?buf c.och ~request_id ()))
                 in
                   (* we deliver notifications _after_ actual commit
                    * (otherwise, new data wouldn't be found if another client
                    *  performs a query right away) *)
                   begin if is_outermost then
                     Notif_queue.iter (notify c.server ks) tx_data.tx_notifications
                   else parent_tx_data.tx_notifications <- tx_data.tx_notifications
                   end;
                   return ret
               with Abort_exn ->
                 wait_for_pending_reqs c >>
                 P.return_ok ?buf c.och ~request_id ())
    | Commit _ ->
        (* only commit if we're inside a tx *)
        begin match Lwt.get tx_key with
            None -> P.return_ok ?buf c.och ~request_id ()
          | Some _ -> raise_lwt Commit_exn
        end
    | Abort _ ->
        (* only abort if we're inside a tx *)
        begin match Lwt.get tx_key with
            None -> P.return_ok ?buf c.och ~request_id ()
          | Some _ -> raise_lwt Abort_exn
        end
    | Lock { Lock.keyspace; names; shared; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             try_lwt
               D.lock ks ~shared names >>
               P.return_ok ?buf c.och ~request_id ()
             with Error Deadlock ->
               P.deadlock ?buf c.och ~request_id () >>
               raise_lwt Abort_exn)
    | Get_keys { Get_keys.keyspace; table; max_keys; key_range; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.get_keys ks table ?max_keys key_range >>=
                     P.return_keys ?buf c.och ~request_id)
    | Exist_keys { Exist_keys.keyspace; table; keys; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.exist_keys ks table keys >>=
                     P.return_exist_result ?buf c.och ~request_id)
    | Count_keys { Count_keys.keyspace; table; key_range; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.count_keys ks table key_range >>=
                     P.return_key_count ?buf c.och ~request_id)
    | Get_slice { Get_slice.keyspace; table; max_keys; max_columns;
                  decode_timestamps; key_range; predicate; column_range; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.get_slice ks table ?max_keys ?max_columns ~decode_timestamps
               key_range ?predicate column_range >>=
             P.return_slice ?buf c.och ~request_id)
    | Get_slice_values { Get_slice_values.keyspace; table; max_keys;
                         key_range; columns; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.get_slice_values ks table ?max_keys key_range columns >>=
             P.return_slice_values ?buf c.och ~request_id)
    | Get_slice_values_timestamps
        { Get_slice_values_timestamps.keyspace; table; max_keys; key_range; columns; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.get_slice_values_with_timestamps ks table ?max_keys key_range columns >>=
             P.return_slice_values_timestamps ?buf c.och ~request_id)
    | Get_columns { Get_columns.keyspace; table; max_columns;
                    decode_timestamps; key; column_range; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.get_columns ks table ?max_columns ~decode_timestamps
               key column_range >>=
             P.return_columns ?buf c.och ~request_id)
    | Get_column_values { Get_column_values.keyspace; table; key; columns; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.get_column_values ks table key columns >>=
             P.return_column_values ?buf c.och ~request_id)
    | Get_column { Get_column.keyspace; table; key; column; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.get_column ks table key column >>=
                     P.return_column ?buf c.och ~request_id)
    | Put_columns { Put_columns.keyspace; table; data; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.put_multi_columns ks table data >>=
                     P.return_ok ?buf c.och ~request_id)
    | Delete_columns { Delete_columns.keyspace; table; key; columns; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.delete_columns ks table key columns >>=
                     P.return_ok ?buf c.och ~request_id)
    | Delete_key { Delete_key.keyspace; table; key; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.delete_key ks table key >>=
                     P.return_ok ?buf c.och ~request_id)
    | Dump { Dump.keyspace; only_tables; cursor; format; } ->
        let offset = match cursor with
            None -> None
          | Some c -> D.cursor_of_string c in
        with_keyspace c keyspace ~request_id
          (fun ks ->
             lwt x =
               D.dump ks ?format ?only_tables ?offset () >|= function
                   None -> None
                 | Some (data, None) -> Some (data, None)
                 | Some (data, Some cursor) ->
                     Some (data, Some (D.string_of_cursor cursor))
             in P.return_backup_dump ?buf c.och ~request_id x)
    | Load { Load.keyspace; data; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             D.load ks data >>=
             P.return_backup_load_result ?buf c.och ~request_id)
    | Stats { Stats.keyspace; } ->
        with_keyspace c keyspace ~request_id
          (fun ks -> D.load_stats ks >>=
                     P.return_load_stats ?buf c.och ~request_id)
    | Listen { Listen.keyspace; topic; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             let ks_name = D.keyspace_name ks in
             let k = { subs_ks = ks_name; subs_topic = topic} in
             let tbl =
               find_or_add
                 Hashtbl.find
                 (fun h k -> let v = H.create 13 in Hashtbl.add h k v; v)
                 c.server.subscriptions k
             in
               if not (H.mem tbl c.id) then begin
                 let stream, topics =
                   find_or_add
                     Hashtbl.find
                     (fun h ks_name ->
                        let v = (Lwt_stream.create (), Hashtbl.create 13) in
                          Hashtbl.add h ks_name v;
                          v)
                     (find_or_add
                        H.find
                        (fun h k -> let v = Hashtbl.create 13 in H.add h k v; v)
                        c.server.rev_subscriptions c.id)
                     ks_name
                 in
                   Hashtbl.replace topics topic ();
                   H.add tbl c.id stream;
               end;
               P.return_ok ?buf c.och ~request_id ())
    | Unlisten { Unlisten.keyspace; topic; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             let ks_name = D.keyspace_name ks in
             let k = { subs_ks = ks_name; subs_topic = topic} in
               begin try
                 H.remove (Hashtbl.find c.server.subscriptions k) c.id;
                 Hashtbl.remove (H.find c.server.rev_subscriptions c.id) ks_name;
               with Not_found -> () end;
               P.return_ok ?buf c.och ~request_id ())
    | Notify { Notify.keyspace; topic; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             begin match Lwt.get tx_key with
                 None -> notify c.server ks topic
               | Some tx_data ->
                   tx_data.tx_notifications <-
                     Notif_queue.push topic tx_data.tx_notifications;
             end;
             P.return_ok ?buf c.och ~request_id ())
    | Await { Await.keyspace; } ->
        with_keyspace c keyspace ~request_id
          (fun ks ->
             let ks_name = D.keyspace_name ks in
               try_lwt
                 let tbl = H.find c.server.rev_subscriptions c.id in
                 let ((stream, _), _) = Hashtbl.find tbl ks_name in
                 (* we use get_available_up_to to limit the stack footprint
                  * (get_available is not tail-recursive) *)
                 lwt l = match Lwt_stream.get_available_up_to 500 stream with
                     [] -> begin
                       match_lwt Lwt_stream.get stream with
                           None -> return []
                         | Some x -> return [x]
                     end
                   | l -> return l
                 in P.return_notifications ?buf c.och ~request_id l
               with Not_found ->
                 P.return_notifications ?buf c.och ~request_id [])
    | Trigger_raw_dump { Trigger_raw_dump.record; } ->
      (* FIXME: catch errors in Raw_dump.dump, signal to client *)
      lwt raw_dump = D.Raw_dump.dump c.server.db in
      lwt timestamp = D.Raw_dump.timestamp raw_dump in
      let dump_id = c.server.raw_dump_seqno in
        c.server.raw_dump_seqno <- Int64.add 1L dump_id;
        Hashtbl.add c.server.raw_dumps dump_id raw_dump;
        P.return_raw_dump_id_and_timestamp ?buf c.och ~request_id
          (dump_id, timestamp)
    | Raw_dump_release { Raw_dump_release.id } ->
        with_raw_dump c id ()
          (fun raw_dump ->
             Hashtbl.remove c.server.raw_dumps id;
             D.Raw_dump.release raw_dump) >>=
        P.return_ok ?buf c.och ~request_id
    | Raw_dump_list_files { Raw_dump_list_files.id } ->
        with_raw_dump c id [] D.Raw_dump.list_files >>=
        P.return_raw_dump_files ?buf c.och ~request_id
    | Raw_dump_file_digest { Raw_dump_file_digest.id; file; } ->
        with_raw_dump c id None
          (fun d -> D.Raw_dump.file_digest d file) >>=
        P.return_raw_dump_file_digest ?buf c.och ~request_id

  and notify server ks topic =
    let ks_name = D.keyspace_name ks in
    let k = { subs_ks = ks_name; subs_topic = topic; } in
      begin try
        let subs = Hashtbl.find server.subscriptions k in
          H.iter (fun _ (_, pushf) -> pushf (Some topic)) subs
      with _ -> () end

  and with_keyspace c ks_idx ~request_id f =
    let ks = try Some (H.find c.keyspaces ks_idx) with Not_found -> None in
      match ks with
          None -> P.unknown_keyspace c.och ~request_id ()
        | Some ks -> f ks

  and wait_for_pending_reqs c =
    if c.pending_reqs = 0 then
      return ()
    else begin
      Lwt_condition.wait c.wait_for_pending_reqs
    end

  let setup_auto_yield t =
    incr num_clients;
    if !num_clients >= 2 then begin
      D.use_thread_pool t.db true;
      let f = Lwt_unix.auto_yield 0.5e-3 in
        auto_yielder := f
    end;
    let db = t.db in
      Gc.finalise
        (fun _ ->
           decr num_clients;
           if !num_clients <= 1 then begin
             D.use_thread_pool db false;
             auto_yielder := dummy_auto_yield
           end)
        t

  let make db =
    {
      db;
      subscriptions = Hashtbl.create 13;
      rev_subscriptions = H.create 13;
      raw_dump_seqno = 0L;
      raw_dumps = Hashtbl.create 13;
    }

  let client_id = ref 0

  let service_client server ?(max_async_reqs = 5000) ?(debug=false) ich och =
    let c =
      {
        id = (incr client_id; !client_id);
        keyspaces = H.create 13;
        rev_keyspaces = H.create 13;
        ich; och; server; debug;
        out_buf = Obs_bytea.create 1024;
        in_buf = String.create 128;
        pending_reqs = 0;
        wait_for_pending_reqs = Lwt_condition.create ();
        async_req_region = Lwt_util.make_region max_async_reqs;
      }
    in setup_auto_yield server;
       try_lwt
         service c
       with Unix.Unix_error (Unix.ECONNRESET, _, _) ->
         raise_lwt End_of_file
       finally
         let empty_topics =
           Hashtbl.fold
             (fun subs_ks ((_, pushf), topics) l ->
                pushf None;
                Hashtbl.fold
                  (fun subs_topic _ l ->
                     let k =  { subs_ks; subs_topic; } in
                     let t = Hashtbl.find server.subscriptions k in
                       H.remove t c.id;
                       if H.length t = 0 then
                         k :: l
                       else l)
                  topics l)
             (try H.find server.rev_subscriptions c.id
              with Not_found -> Hashtbl.create 1)
             []
         in
           H.remove server.rev_subscriptions c.id;
           List.iter (Hashtbl.remove server.subscriptions) empty_topics;
           return ()

  type data_protocol_response_code = [ `OK | `Unknown_dump | `Unknown_file ]

  let data_response_code = function
      `OK -> 0
    | `Unknown_dump -> 1
    | `Unknown_file -> 2

  let send_response_code code och =
    Lwt_io.LE.write_int och (data_response_code code)

  let service_data_client server ?(debug=false) ich och =
    try_lwt
      let (self_major, self_minor, self_bugfix) = data_protocol_version in
      lwt () =
        Lwt_io.LE.write_int och self_major >>
        Lwt_io.LE.write_int och self_minor >>
        Lwt_io.LE.write_int och self_bugfix in
      lwt major = Lwt_io.LE.read_int ich in
      lwt minor = Lwt_io.LE.read_int ich in
      lwt bugfix = Lwt_io.LE.read_int ich in
      lwt dump_id = Lwt_io.LE.read_int64 ich in
      lwt offset = Lwt_io.LE.read_int64 ich in
      lwt name_siz = Lwt_io.LE.read_int ich in
      lwt name = Lwt_io.read ~count:name_siz ich in
        try
          let dump = Hashtbl.find server.raw_dumps dump_id in
            match_lwt D.Raw_dump.open_file dump ~offset name with
                None -> send_response_code `Unknown_file och
              | Some ic ->
                  send_response_code `OK och >>
                  let buf = String.create 16384 in
                  let rec loop_copy_data () =
                    match_lwt Lwt_io.read_into ic buf 0 16384 with
                        0 -> return ()
                      | n -> Lwt_io.write_from_exactly och buf 0 n >>
                             loop_copy_data ()
                  in loop_copy_data () >>
                     (* client gets End_of_file if we don't flush (i.e. the
                      * conn is shutdown before the data is sent) *)
                     Lwt_io.flush och
        with Not_found -> send_response_code `Unknown_dump och
    with Unix.Unix_error (Unix.ECONNRESET, _, _) ->
      raise_lwt End_of_file

end
