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
open Printf

module D = Obs_storage
module DM = Obs_data_model
module List = struct include List include BatList end
module String = struct include String include BatString end
module Option = BatOption

module C = Obs_protocol_client.Make(Obs_protocol_bin.Version_0_0_0)

let server = ref "127.0.0.1"
let port = ref 12050
let keyspace = ref "obs-benchmark"
let table = ref (Obs_data_model.table_of_string "bm_write")
let concurrency = ref 2048
let multi = ref 1
let range = ref false
let time = ref 60.
let report_latencies = ref false
let period = ref 5.0

let max_key = ref None

let params = Arg.align
  [
   "-server", Arg.Set_string server, "ADDR Connect to server at ADDR.";
   "-port", Arg.Set_int port, "N Connect to server port N (default: 12050)";
   "-keyspace", Arg.Set_string keyspace,
     "NAME keyspace to use (default 'obs-benchmark')";
   "-table", Arg.String (fun s -> table := Obs_data_model.table_of_string s),
     "NAME table to use (default 'bm_write')";
   "-range", Arg.Set range, " Read ranges.";
   "-concurrency", Arg.Set_int concurrency,
     "N maximum number of concurrent reads (default: 2048, multi: max 256)";
   "-multi", Arg.Set_int multi, "N Read in N (power of 2) batches (default: 1).";
   "-latency", Arg.Set report_latencies, " Report latencies.";
   "-period", Arg.Set_float period,
     "FLOAT Report stats every FLOAT seconds (default: 5)";
   "-time", Arg.Set_float time, "N Run for N seconds (default: 60).";
  ]

let usage_message = "Usage: bm_read N [options]"

let make_client ~address ~data_address ~role ~password =
  lwt fd, ich, och = Obs_conn.open_connection address in
    Lwt_unix.setsockopt fd Unix.TCP_NODELAY true;
    C.make ~data_address ich och ~role ~password

let in_flight = ref 0
let finished = ref 0
let errors = ref 0

let benchmark_over = ref false

let prev_finished = ref 0
let t0 = ref 0.
let exec_start_time = ref 0.

let round_to_pow_of_two n =
  let rec round m =
    if m > n then m else round (2 * m)
  in round 2

let report_alarm = ref false

let latencies = ref []

let measure_latency f =
  if not !report_latencies then f ()
  else begin
    let t0 = Unix.gettimeofday () in
    lwt x = f () in
    let dt = Unix.gettimeofday () -. t0 in
      latencies := dt :: !latencies;
      return x
  end

let report_header =
  let n = ref 0 in
    (fun () ->
       if !n = 0 then begin
         printf "#%5s  %6s  " "time" "k rate";
         if !report_latencies then begin
           printf "%8s  %8s  %8s  %8s  %8s"
             "mean" "median" "90th" "95th" "99th"
         end;
         printf "\n%!";
       end;
       incr n;
       if !n > 10 then n := 0)

let report () =
  if !report_alarm then begin
    report_header ();
    let t = Unix.gettimeofday () in
    let dt = t -. !t0 in
      printf "%-6.2f  %-6d  "
        (t -. !exec_start_time) (truncate (float (!finished - !prev_finished) /. dt));
      prev_finished := !finished;
      if !report_latencies && !latencies <> [] then begin
        let sorted = Array.of_list !latencies in
        let () = Array.sort compare sorted in
        let len = Array.length sorted in
        let mean = Array.fold_left (fun dt s -> s +. dt) 0. sorted /. float len in
        let median = sorted.(len / 2) in
        let perc90 = sorted.(90 * len / 100) in
        let perc95 = sorted.(95 * len / 100) in
        let perc99 = sorted.(99 * len / 100) in
          printf "%.6f  %.6f  %.6f  %.6f  %.6f" mean median perc90 perc95 perc99;
          latencies := [];
      end;
      printf "\n%!";
      t0 := t;
      report_alarm := false
  end

let zero_pad n s =
  let len = String.length s in
    if len >= n then s
    else String.make (n - len) '0' ^ s

let mk_key () =
  zero_pad 16 (Int64.to_string (Random.int64 (Option.get !max_key)))

let rec read_values ks =
  while not !benchmark_over && !in_flight < !concurrency do
    ignore begin
      incr in_flight;
      begin try_lwt
        let k = mk_key () in
        lwt _ = measure_latency (fun () -> C.get_column ks !table k "v") in
          incr finished;
          report ();
          return ()
      with _ ->
        incr errors;
        return ()
      finally
        decr in_flight;
        return ()
      end >>
      return (read_values ks)
    end;
  done

let rec read_values_multi ks =
  while not !benchmark_over && !in_flight < !concurrency do
    ignore begin
      incr in_flight;
      begin try_lwt
        let keys = List.init !multi (fun _ -> mk_key ()) in
        lwt _ =
          measure_latency
            (fun () -> C.get_slice ks !table (`Discrete keys) (`Discrete ["v"]))
        in
          finished := !finished + !multi;
          report ();
          return ()
      with _ ->
        incr errors;
        return ()
      finally
        decr in_flight;
        return ()
      end >>
      return (read_values_multi ks)
    end;
  done

let rec read_values_seq ?first ks =
  while not !benchmark_over && !in_flight < 16 do
    ignore begin
      incr in_flight;
      try_lwt
        lwt last_key, l =
          measure_latency
            (fun () ->
               C.get_slice ks !table ~max_keys:512
                 (`Continuous { DM.first; up_to = None; reverse = false; }) `All)
        in
          (* last one will return fewer than 512, so we "resync" in order for
           * report to work *)
          finished := (!finished + List.length l) land (-510);
          report ();
          let first = match last_key with
              None -> None (* restart *)
            | Some k -> Some (k ^ "\x00")
          in
            read_values_seq ?first ks;
            return ()
      with _ ->
        incr errors;
        return ()
      finally
        decr in_flight;
        return ()
    end
  done

let role = "guest"
let password = "guest"

let () =
  Arg.parse params
    (fun s -> match !max_key with
         None ->
           begin try
             max_key := Some (Int64.of_string s)
           with _ -> raise (Arg.Bad s)
           end
       | Some _ -> raise (Arg.Bad s))
    usage_message;
  if Option.is_none !max_key then begin
    Arg.usage params usage_message;
    exit 1
  end;
  Lwt_unix.run begin
    Random.self_init ();
    let address = Unix.ADDR_INET (Unix.inet_addr_of_string !server, !port) in
    let data_address = Unix.ADDR_INET (Unix.inet_addr_of_string !server, !port + 1) in
    lwt db = make_client ~address ~data_address ~role ~password in
    lwt ks = C.register_keyspace db !keyspace in

    let rec wait_until_finished () =
      lwt () = Lwt_unix.sleep 0.01 in
        if !in_flight > 0 then wait_until_finished ()
        else return ()
    in
      t0 := Unix.gettimeofday ();
      exec_start_time := !t0;
      ignore
        (let rec report () =
           Lwt_unix.sleep !period >> report (report_alarm := true) in report ());
      ignore (Lwt_unix.sleep !time >> return (benchmark_over := true));
      if !range then read_values_seq ks
      else if !multi <= 1 then read_values ks
      else begin
          concurrency := min !concurrency 256;
          read_values_multi ks
      end;
      wait_until_finished ()
  end
