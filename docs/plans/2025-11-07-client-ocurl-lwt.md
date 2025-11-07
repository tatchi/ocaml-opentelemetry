# Client-OCurl-Lwt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add opentelemetry-client-ocurl-lwt package that combines ezcurl-lwt with Lwt for async HTTP telemetry export

**Architecture:** Hybrid approach combining client-ocurl's thread-based batching (B_queue, Batch modules) with ezcurl-lwt's async HTTP. Main thread manages batches, Lwt promises handle async HTTP sends via ezcurl-lwt instead of blocking ezcurl calls.

**Tech Stack:** OCaml, Dune, ezcurl-lwt, Lwt, opentelemetry.client (shared batching/config), Pbrt

---

## Task 1: Create package structure

**Files:**
- Create: `src/client-ocurl-lwt/dune`
- Create: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli`
- Create: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`
- Create: `src/client-ocurl-lwt/common_.ml`
- Create: `src/client-ocurl-lwt/config.mli`
- Create: `src/client-ocurl-lwt/config.ml`
- Modify: `dune-project` (add new package definition)

**Step 1: Create directory structure**

Run: `mkdir -p src/client-ocurl-lwt`

**Step 2: Create dune file for library**

Create `src/client-ocurl-lwt/dune`:

```ocaml
(library
 (name opentelemetry_client_ocurl_lwt)
 (public_name opentelemetry-client-ocurl-lwt)
 (synopsis "Opentelemetry collector using ezcurl-lwt")
 (preprocess
  (pps lwt_ppx))
 (libraries
  opentelemetry
  opentelemetry.atomic
  opentelemetry.client
  curl
  pbrt
  threads
  mtime
  mtime.clock.os
  ezcurl-lwt
  ezcurl.core
  lwt
  lwt.unix))
```

**Step 3: Create common_.ml helper module**

Create `src/client-ocurl-lwt/common_.ml`:

```ocaml
module Atomic = Opentelemetry_atomic.Atomic
include Opentelemetry.Lock

let spf = Printf.sprintf

let ( let@ ) = ( @@ )

let tid () = Thread.id @@ Thread.self ()
```

**Step 4: Create config.mli interface**

Create `src/client-ocurl-lwt/config.mli`:

```ocaml
(** Configuration for the ocurl-lwt backend *)

type t = {
  bg_threads: int;
      (** Number of background threads for HTTP sends. Default [4].
          Adjusted to be at least [1] and at most [32]. *)
  ticker_thread: bool;
      (** If true, start a thread that regularly checks if signals should be
          sent to the collector. Default [true] *)
  ticker_interval_ms: int;
      (** Interval for ticker thread, in milliseconds. Only useful if
          [ticker_thread] is [true]. Clamped between [2 ms] and [60s].
          Default 500. *)
  common: Opentelemetry_client.Config.t;
      (** Common configuration options *)
}
(** Configuration.

    To build one, use {!make} below. This might be extended with more fields in
    the future. *)

val pp : Format.formatter -> t -> unit

val make :
  (?bg_threads:int ->
  ?ticker_thread:bool ->
  ?ticker_interval_ms:int ->
  unit ->
  t)
  Opentelemetry_client.Config.make
(** Make a configuration {!t}. *)

module Env : Opentelemetry_client.Config.ENV
```

**Step 5: Create config.ml implementation**

Create `src/client-ocurl-lwt/config.ml`:

```ocaml
type t = {
  bg_threads: int;
  ticker_thread: bool;
  ticker_interval_ms: int;
  common: Opentelemetry_client.Config.t;
}

let pp out self =
  Format.fprintf out
    "{@[bg_threads=%d;@ ticker_thread=%B;@ ticker_interval_ms=%d;@ common=%a@]}"
    self.bg_threads self.ticker_thread self.ticker_interval_ms
    Opentelemetry_client.Config.pp self.common

let make ?(bg_threads = 4) ?(ticker_thread = true) ?(ticker_interval_ms = 500) =
  fun common_config ->
    let bg_threads = max 1 (min 32 bg_threads) in
    let common = common_config () in
    { bg_threads; ticker_thread; ticker_interval_ms; common }

module Env = Opentelemetry_client.Config.Env
```

**Step 6: Add package to dune-project**

Modify `dune-project`, add after the `opentelemetry-client-ocurl` package definition (around line 92):

```lisp
(package
 (name opentelemetry-client-ocurl-lwt)
 (depends
  (ocaml
   (>= "4.08"))
  (mtime
   (>= "1.4"))
  (opentelemetry
   (= :version))
  (odoc :with-doc)
  (ezcurl-lwt
   (>= 0.2.3))
  (ezcurl
   (>= 0.2.3))
  ocurl
  (lwt
   (>= "5.3"))
  (lwt_ppx
   (>= "2.0"))
  (alcotest :with-test))
 (synopsis "Collector client for opentelemetry, using ezcurl-lwt"))
```

**Step 7: Build to verify structure**

Run: `dune build @all`
Expected: Build succeeds or fails only because main .mli/.ml files are empty

**Step 8: Commit**

```bash
git add src/client-ocurl-lwt/ dune-project
git commit -m "feat: add client-ocurl-lwt package structure

Create new package combining ezcurl-lwt + Lwt for async telemetry export

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: Implement core backend with B_queue and Batch modules

**Files:**
- Create: `src/client-ocurl-lwt/b_queue.mli`
- Create: `src/client-ocurl-lwt/b_queue.ml`
- Create: `src/client-ocurl-lwt/batch.mli`
- Create: `src/client-ocurl-lwt/batch.ml`

**Step 1: Copy b_queue.mli from client-ocurl**

Create `src/client-ocurl-lwt/b_queue.mli` (identical to client-ocurl version):

```ocaml
(** Basic Blocking Queue *)

type 'a t

val create : unit -> _ t

exception Closed

val push : 'a t -> 'a -> unit
(** [push q x] pushes [x] into [q], and returns [()].
    @raise Closed if [close q] was previously called.*)

val pop : 'a t -> 'a
(** [pop q] pops the next element in [q]. It might block until an element comes.
    @raise Closed if the queue was closed before a new element was available. *)

val pop_all : 'a t -> 'a Queue.t -> unit
(** [pop_all q into] pops all the elements of [q] and moves them into [into]. It
    might block until an element comes.
    @raise Closed if the queue was closed before a new element was available. *)

val close : _ t -> unit
(** Close the queue, meaning there won't be any more [push] allowed. *)
```

**Step 2: Copy b_queue.ml from client-ocurl**

Run: `cp src/client-ocurl/b_queue.ml src/client-ocurl-lwt/b_queue.ml`

**Step 3: Copy batch.mli from client-ocurl**

Create `src/client-ocurl-lwt/batch.mli` (identical to client-ocurl version):

```ocaml
(** List of lists with length *)

type 'a t

val create : unit -> 'a t

val push : 'a t -> 'a list -> unit

val len : _ t -> int

val time_started : _ t -> Mtime.t
(** Time at which the batch most recently became non-empty *)

val pop_all : 'a t -> 'a list list
```

**Step 4: Copy batch.ml from client-ocurl**

Run: `cp src/client-ocurl/batch.ml src/client-ocurl-lwt/batch.ml`

**Step 5: Build to verify modules compile**

Run: `dune build src/client-ocurl-lwt/`
Expected: Build succeeds for b_queue and batch modules

**Step 6: Commit**

```bash
git add src/client-ocurl-lwt/b_queue.* src/client-ocurl-lwt/batch.*
git commit -m "feat: add b_queue and batch modules to client-ocurl-lwt

Copy blocking queue and batching logic from client-ocurl

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Implement public interface (.mli file)

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli`

**Step 1: Write the interface file**

Write to `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli`:

```ocaml
val get_headers : unit -> (string * string) list

val set_headers : (string * string) list -> unit
(** Set http headers that are sent on every http query to the collector. *)

module Atomic = Opentelemetry_atomic.Atomic
module Config = Config

val create_backend :
  ?stop:bool Atomic.t ->
  ?config:Config.t ->
  unit ->
  (module Opentelemetry.Collector.BACKEND)
(** Create a new backend using lwt and ezcurl-lwt *)

val setup :
  ?stop:bool Atomic.t -> ?config:Config.t -> ?enable:bool -> unit -> unit
(** Setup endpoint. This modifies {!Opentelemetry.Collector.backend}.
    @param enable
      actually setup the backend (default true). This can be used to
      enable/disable the setup depending on CLI arguments or environment.
    @param config configuration to use
    @param stop
      an atomic boolean. When it becomes true, background threads will all stop
      after a little while. *)

val remove_backend : unit -> unit
(** Remove current backend *)

val with_setup :
  ?stop:bool Atomic.t ->
  ?config:Config.t ->
  ?enable:bool ->
  unit ->
  (unit -> 'a) ->
  'a
(** [with_setup () f] is like [setup(); f()] but takes care of cleaning up after
    [f()] returns. See {!setup} for more details. *)
```

**Step 2: Build to check interface**

Run: `dune build src/client-ocurl-lwt/`
Expected: Build fails with "Unbound module" errors (implementation not done yet)

**Step 3: Commit**

```bash
git add src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli
git commit -m "feat: add public interface for client-ocurl-lwt

Define API matching client-ocurl pattern

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Implement Backend_impl with Lwt HTTP sending

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`

**Step 1: Add module header and imports**

Write initial part of `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
(*
   https://github.com/open-telemetry/oteps/blob/main/text/0035-opentelemetry-protocol.md
   https://github.com/open-telemetry/oteps/blob/main/text/0099-otlp-http.md
 *)

module OT = Opentelemetry
module Config = Config
module Self_trace = Opentelemetry_client.Self_trace
module Signal = Opentelemetry_client.Signal
open Opentelemetry
include Common_

let get_headers = Config.Env.get_headers

let set_headers = Config.Env.set_headers

let needs_gc_metrics = Atomic.make false

let last_gc_metrics = Atomic.make (Mtime_clock.now ())

let timeout_gc_metrics = Mtime.Span.(20 * s)

(** side channel for GC, appended to metrics batch data *)
let gc_metrics = AList.make ()

(** capture current GC metrics if {!needs_gc_metrics} is true or it has been a
    long time since the last GC metrics collection, and push them into
    {!gc_metrics} for later collection *)
let sample_gc_metrics_if_needed () =
  let now = Mtime_clock.now () in
  let alarm = Atomic.exchange needs_gc_metrics false in
  let timeout () =
    let elapsed = Mtime.span now (Atomic.get last_gc_metrics) in
    Mtime.Span.compare elapsed timeout_gc_metrics > 0
  in
  if alarm || timeout () then (
    Atomic.set last_gc_metrics now;
    let l =
      OT.Metrics.make_resource_metrics
        ~attrs:(Opentelemetry.GC_metrics.get_runtime_attributes ())
      @@ Opentelemetry.GC_metrics.get_metrics ()
    in
    AList.add gc_metrics l
  )

let n_errors = Atomic.make 0

let n_dropped = Atomic.make 0

(** Something sent to the collector *)
module Event = struct
  open Opentelemetry.Proto

  type t =
    | E_metric of Metrics.resource_metrics list
    | E_trace of Trace.resource_spans list
    | E_logs of Logs.resource_logs list
    | E_tick
    | E_flush_all  (** Flush all batches *)
end

(** Something to be sent via HTTP *)
module To_send = struct
  open Opentelemetry.Proto

  type t =
    | Send_metric of Metrics.resource_metrics list list
    | Send_trace of Trace.resource_spans list list
    | Send_logs of Logs.resource_logs list list
end
```

**Step 2: Add thread helpers and hex conversion**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
(** start a thread in the background, running [f()] *)
let start_bg_thread (f : unit -> unit) : Thread.t =
  let unix_run () =
    let signals =
      [
        Sys.sigusr1;
        Sys.sigusr2;
        Sys.sigterm;
        Sys.sigpipe;
        Sys.sigalrm;
        Sys.sigstop;
      ]
    in
    ignore (Thread.sigmask Unix.SIG_BLOCK signals : _ list);
    f ()
  in
  (* no signals on Windows *)
  let run () =
    if Sys.win32 then
      f ()
    else
      unix_run ()
  in
  Thread.create run ()

let str_to_hex (s : string) : string =
  let i_to_hex (i : int) =
    if i < 10 then
      Char.chr (i + Char.code '0')
    else
      Char.chr (i - 10 + Char.code 'a')
  in

  let res = Bytes.create (2 * String.length s) in
  for i = 0 to String.length s - 1 do
    let n = Char.code (String.get s i) in
    Bytes.set res (2 * i) (i_to_hex ((n land 0xf0) lsr 4));
    Bytes.set res ((2 * i) + 1) (i_to_hex (n land 0x0f))
  done;
  Bytes.unsafe_to_string res
```

**Step 3: Implement Backend_impl module with Lwt HTTP**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
module Backend_impl : sig
  type t

  val create : stop:bool Atomic.t -> config:Config.t -> unit -> t

  val send_event : t -> Event.t -> unit

  val shutdown : t -> on_done:(unit -> unit) -> unit
end = struct
  open Opentelemetry.Proto

  type t = {
    stop: bool Atomic.t;
    cleaned: bool Atomic.t;  (** True when we cleaned up after closing *)
    config: Config.t;
    q: Event.t B_queue.t;  (** Queue to receive data from the user's code *)
    mutable main_th: Thread.t option;  (** Thread that listens on [q] *)
    send_q: To_send.t B_queue.t;  (** Queue for the send worker threads *)
    mutable send_threads: Thread.t array;  (** Threads that send data via http *)
  }

  let send_http_ ~stop ~(config : Config.t) (client : Curl.t) ~url data : unit =
    let@ _sc =
      Self_trace.with_ ~kind:Span.Span_kind_producer "otel-ocurl-lwt.send-http"
    in

    if Config.Env.get_debug () then
      Printf.eprintf "opentelemetry: send http POST to %s (%dB)\n%!" url
        (String.length data);
    let headers =
      ("Content-Type", "application/x-protobuf") :: config.common.headers
    in

    (* Use Lwt.wait + wakeup to bridge Lwt and threads *)
    let result_promise, result_resolver = Lwt.wait () in

    (* Launch async Lwt HTTP request *)
    Lwt.async (fun () ->
      let open Lwt.Syntax in
      let@ _sc =
        Self_trace.with_ ~kind:Span.Span_kind_internal "ezcurl-lwt.post"
          ~attrs:[ "sz", `Int (String.length data); "url", `String url ]
      in
      let* result =
        Ezcurl_lwt.post ~headers ~client ~params:[] ~url ~content:(`String data) ()
      in
      Lwt.wakeup result_resolver result;
      Lwt.return ()
    );

    (* Block thread until result available *)
    match Lwt_main.run result_promise with
    | Ok { code; _ } when code >= 200 && code < 300 ->
      if Config.Env.get_debug () then
        Printf.eprintf "opentelemetry: got response code=%d\n%!" code
    | Ok { code; body; headers = _; info = _ } ->
      Atomic.incr n_errors;
      Self_trace.add_event _sc
      @@ Opentelemetry.Event.make "error" ~attrs:[ "code", `Int code ];

      if Config.Env.get_debug () then (
        let dec = Pbrt.Decoder.of_string body in
        let body =
          try
            let status = Status.decode_pb_status dec in
            Format.asprintf "%a" Status.pp_status status
          with _ ->
            spf "(could not decode status)\nraw bytes: %s" (str_to_hex body)
        in
        Printf.eprintf
          "opentelemetry: error while sending data to %s:\n  code=%d\n  %s\n%!"
          url code body
      );
      ()
    | exception Sys.Break ->
      Printf.eprintf "ctrl-c captured, stopping\n%!";
      Atomic.set stop true
    | Error (code, msg) ->
      (* TODO: log error _via_ otel? *)
      Atomic.incr n_errors;

      Printf.eprintf
        "opentelemetry: export failed:\n  %s\n  curl code: %s\n  url: %s\n%!"
        msg (Curl.strerror code) url;

      (* avoid crazy error loop *)
      Thread.delay 3.

  let[@inline] send_event (self : t) ev : unit = B_queue.push self.q ev

  (** Thread that, in a loop, reads from [q] to get the next message to send via
      http *)
  let bg_thread_loop (self : t) : unit =
    Ezcurl.with_client ?set_opts:None @@ fun client ->
    let config = self.config in
    let stop = self.stop in
    let send ~name ~url ~conv signals =
      let l = List.fold_left (fun acc l -> List.rev_append l acc) [] signals in
      let@ _sp =
        Self_trace.with_ ~kind:Span_kind_producer name
          ~attrs:[ "n", `Int (List.length l) ]
      in
      conv l |> send_http_ ~stop ~config ~url client
    in
    try
      while not (Atomic.get stop) do
        let msg = B_queue.pop self.send_q in
        match msg with
        | To_send.Send_trace tr ->
          send ~name:"send-traces" ~conv:Signal.Encode.traces
            ~url:config.common.url_traces tr
        | To_send.Send_metric ms ->
          send ~name:"send-metrics" ~conv:Signal.Encode.metrics
            ~url:config.common.url_metrics ms
        | To_send.Send_logs logs ->
          send ~name:"send-logs" ~conv:Signal.Encode.logs
            ~url:config.common.url_logs logs
      done
    with B_queue.Closed -> ()

  type batches = {
    traces: Proto.Trace.resource_spans Batch.t;
    logs: Proto.Logs.resource_logs Batch.t;
    metrics: Proto.Metrics.resource_metrics Batch.t;
  }

  let batch_max_size_ = 200

  let should_send_batch_ ?(side = []) ~config ~now (b : _ Batch.t) : bool =
    (Batch.len b > 0 || side != [])
    && (Batch.len b >= batch_max_size_
       ||
       let timeout = Mtime.Span.(config.Config.common.batch_timeout_ms * ms) in
       let elapsed = Mtime.span now (Batch.time_started b) in
       Mtime.Span.compare elapsed timeout >= 0)

  let main_thread_loop (self : t) : unit =
    let local_q = Queue.create () in
    let config = self.config in

    (* keep track of batches *)
    let batches =
      {
        traces = Batch.create ();
        logs = Batch.create ();
        metrics = Batch.create ();
      }
    in

    let send_metrics () =
      let metrics = AList.pop_all gc_metrics :: Batch.pop_all batches.metrics in
      B_queue.push self.send_q (To_send.Send_metric metrics)
    in

    let send_logs () =
      B_queue.push self.send_q (To_send.Send_logs (Batch.pop_all batches.logs))
    in

    let send_traces () =
      B_queue.push self.send_q
        (To_send.Send_trace (Batch.pop_all batches.traces))
    in

    try
      while not (Atomic.get self.stop) do
        (* read multiple events at once *)
        B_queue.pop_all self.q local_q;

        (* are we asked to flush all events? *)
        let must_flush_all = ref false in

        (* how to process a single event *)
        let process_ev (ev : Event.t) : unit =
          match ev with
          | Event.E_metric m -> Batch.push batches.metrics m
          | Event.E_trace tr -> Batch.push batches.traces tr
          | Event.E_logs logs -> Batch.push batches.logs logs
          | Event.E_tick ->
            (* the only impact of "tick" is that it wakes us up regularly *)
            ()
          | Event.E_flush_all -> must_flush_all := true
        in

        Queue.iter process_ev local_q;
        Queue.clear local_q;

        if !must_flush_all then (
          if Batch.len batches.metrics > 0 || not (AList.is_empty gc_metrics)
          then
            send_metrics ();
          if Batch.len batches.logs > 0 then send_logs ();
          if Batch.len batches.traces > 0 then send_traces ()
        ) else (
          let now = Mtime_clock.now () in
          if
            should_send_batch_ ~config ~now batches.metrics
              ~side:(AList.get gc_metrics)
          then
            send_metrics ();

          if should_send_batch_ ~config ~now batches.traces then send_traces ();
          if should_send_batch_ ~config ~now batches.logs then send_logs ()
        )
      done
    with B_queue.Closed -> ()

  let create ~stop ~config () : t =
    let n_send_threads = max 2 config.Config.bg_threads in
    let self =
      {
        stop;
        config;
        q = B_queue.create ();
        send_threads = [||];
        send_q = B_queue.create ();
        cleaned = Atomic.make false;
        main_th = None;
      }
    in

    let main_th = start_bg_thread (fun () -> main_thread_loop self) in
    self.main_th <- Some main_th;

    self.send_threads <-
      Array.init n_send_threads (fun _i ->
          start_bg_thread (fun () -> bg_thread_loop self));

    self

  let shutdown self ~on_done : unit =
    Atomic.set self.stop true;
    if not (Atomic.exchange self.cleaned true) then (
      (* empty batches *)
      send_event self Event.E_flush_all;
      (* close the incoming queue, wait for the thread to finish
         before we start cutting off the background threads, so that they
         have time to receive the final batches *)
      B_queue.close self.q;
      Option.iter Thread.join self.main_th;
      (* close send queues, then wait for all threads *)
      B_queue.close self.send_q;
      Array.iter Thread.join self.send_threads
    );
    on_done ()
end
```

**Step 4: Build to verify Backend_impl compiles**

Run: `dune build src/client-ocurl-lwt/`
Expected: Partial build success, may have issues with remaining functions

**Step 5: Commit**

```bash
git add src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml
git commit -m "feat: implement Backend_impl with ezcurl-lwt

Add event queuing, batching, and Lwt-based HTTP sending

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Implement public API functions

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`

**Step 1: Add create_backend function**

Append to `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
let create_backend ?(stop = Atomic.make false)
    ?(config : Config.t = Config.make ()) () : (module Collector.BACKEND) =
  let module M = struct
    open Opentelemetry.Proto
    open Opentelemetry.Collector

    let backend = Backend_impl.create ~stop ~config ()

    let send_trace : Trace.resource_spans list sender =
      {
        send =
          (fun l ~ret ->
            Backend_impl.send_event backend (Event.E_trace l);
            ret ());
      }

    let last_sent_metrics = Atomic.make (Mtime_clock.now ())

    (* send metrics from time to time *)
    let timeout_sent_metrics = Mtime.Span.(5 * s)

    let signal_emit_gc_metrics () =
      if config.common.debug then
        Printf.eprintf "opentelemetry: emit GC metrics requested\n%!";
      Atomic.set needs_gc_metrics true

    let additional_metrics () : Metrics.resource_metrics list =
      (* add exporter metrics to the lot? *)
      let last_emit = Atomic.get last_sent_metrics in
      let now = Mtime_clock.now () in
      let add_own_metrics =
        let elapsed = Mtime.span last_emit now in
        Mtime.Span.compare elapsed timeout_sent_metrics > 0
      in

      (* there is a possible race condition here, as several threads might update
         metrics at the same time. But that's harmless. *)
      if add_own_metrics then (
        Atomic.set last_sent_metrics now;
        let open OT.Metrics in
        let now_unix = OT.Timestamp_ns.now_unix_ns () in
        [
          make_resource_metrics
            [
              sum ~name:"otel.export.dropped" ~is_monotonic:true
                [
                  int ~start_time_unix_nano:now_unix ~now:now_unix
                    (Atomic.get n_dropped);
                ];
              sum ~name:"otel.export.errors" ~is_monotonic:true
                [
                  int ~start_time_unix_nano:now_unix ~now:now_unix
                    (Atomic.get n_errors);
                ];
            ];
        ]
      ) else
        []

    let send_metrics : Metrics.resource_metrics list sender =
      {
        send =
          (fun m ~ret ->
            let m = List.rev_append (additional_metrics ()) m in
            Backend_impl.send_event backend (Event.E_metric m);
            ret ());
      }

    let send_logs : Logs.resource_logs list sender =
      {
        send =
          (fun m ~ret ->
            Backend_impl.send_event backend (Event.E_logs m);
            ret ());
      }

    let on_tick_cbs_ = Atomic.make (AList.make ())

    let set_on_tick_callbacks = Atomic.set on_tick_cbs_

    let tick () =
      sample_gc_metrics_if_needed ();
      Backend_impl.send_event backend Event.E_tick;
      List.iter (fun f -> f ()) (AList.get @@ Atomic.get on_tick_cbs_)

    let cleanup ~on_done () = Backend_impl.shutdown backend ~on_done
  end in
  (module M)
```

**Step 2: Add ticker thread and setup functions**

Append to `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
(** thread that calls [tick()] regularly, to help enforce timeouts *)
let setup_ticker_thread ~stop ~sleep_ms (module B : Collector.BACKEND) () =
  let sleep_s = float sleep_ms /. 1000. in
  let tick_loop () =
    try
      while not @@ Atomic.get stop do
        Thread.delay sleep_s;
        B.tick ()
      done
    with B_queue.Closed -> ()
  in
  start_bg_thread tick_loop

let setup_ ?(stop = Atomic.make false) ?(config : Config.t = Config.make ()) ()
    : unit =
  let backend = create_backend ~stop ~config () in
  Opentelemetry.Collector.set_backend backend;

  Self_trace.set_enabled config.common.self_trace;

  if config.ticker_thread then (
    (* at most a minute *)
    let sleep_ms = min 60_000 (max 2 config.ticker_interval_ms) in
    ignore (setup_ticker_thread ~stop ~sleep_ms backend () : Thread.t)
  )

let remove_backend () : unit =
  (* we don't need the callback, this runs in the same thread *)
  OT.Collector.remove_backend () ~on_done:ignore

let setup ?stop ?config ?(enable = true) () =
  if enable then setup_ ?stop ?config ()

let with_setup ?stop ?config ?(enable = true) () f =
  if enable then (
    setup_ ?stop ?config ();
    Fun.protect ~finally:remove_backend f
  ) else
    f ()
```

**Step 3: Build full library**

Run: `dune build src/client-ocurl-lwt/`
Expected: Build succeeds

**Step 4: Regenerate opam file**

Run: `dune build @all`
Expected: Generates `opentelemetry-client-ocurl-lwt.opam`

**Step 5: Commit**

```bash
git add src/client-ocurl-lwt/ opentelemetry-client-ocurl-lwt.opam
git commit -m "feat: complete client-ocurl-lwt public API

Add setup, create_backend, and cleanup functions

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: Add basic tests

**Files:**
- Create: `tests/ocurl-lwt/dune`
- Create: `tests/ocurl-lwt/test_urls.ml`

**Step 1: Create test directory**

Run: `mkdir -p tests/ocurl-lwt`

**Step 2: Create test dune file**

Create `tests/ocurl-lwt/dune`:

```ocaml
(tests
 (names test_urls)
 (package opentelemetry-client-ocurl-lwt)
 (libraries opentelemetry opentelemetry-client-ocurl-lwt))
```

**Step 3: Create basic URL configuration test**

Create `tests/ocurl-lwt/test_urls.ml` (adapted from client-ocurl tests):

```ocaml
module OT = Opentelemetry
module C = Opentelemetry_client_ocurl_lwt

let () =
  let config1 = C.Config.make () in
  Printf.printf "config1: %a\n%!" C.Config.pp config1;
  assert (config1.common.url_traces = "http://localhost:4318/v1/traces");
  assert (config1.common.url_metrics = "http://localhost:4318/v1/metrics");
  assert (config1.common.url_logs = "http://localhost:4318/v1/logs");
  ()

let () =
  let config2 = C.Config.make ~url:"http://example.com:1234" () in
  Printf.printf "config2: %a\n%!" C.Config.pp config2;
  assert (config2.common.url_traces = "http://example.com:1234/v1/traces");
  assert (config2.common.url_metrics = "http://example.com:1234/v1/metrics");
  assert (config2.common.url_logs = "http://example.com:1234/v1/logs");
  ()

let () =
  let config3 =
    C.Config.make ~url_traces:"http://example.com/traces"
      ~url_metrics:"http://example.com/metrics"
      ~url_logs:"http://example.com/logs" ()
  in
  Printf.printf "config3: %a\n%!" C.Config.pp config3;
  assert (config3.common.url_traces = "http://example.com/traces");
  assert (config3.common.url_metrics = "http://example.com/metrics");
  assert (config3.common.url_logs = "http://example.com/logs");
  ()

let () =
  let config4 = C.Config.make ~bg_threads:8 ~ticker_interval_ms:1000 () in
  Printf.printf "config4: %a\n%!" C.Config.pp config4;
  assert (config4.bg_threads = 8);
  assert (config4.ticker_interval_ms = 1000);
  ()

let () = print_endline "All URL tests passed"
```

**Step 4: Run tests**

Run: `dune runtest tests/ocurl-lwt/`
Expected: All tests pass

**Step 5: Commit**

```bash
git add tests/ocurl-lwt/
git commit -m "test: add basic tests for client-ocurl-lwt

Test URL configuration and basic setup

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Update documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add client-ocurl-lwt to documentation**

Modify `CLAUDE.md`, in the "Client Implementations" section (around line 21), add:

```markdown
- `src/client-ocurl/` - HTTP client using cURL (synchronous, thread-based)
- `src/client-ocurl-lwt/` - HTTP client using ezcurl-lwt (threads + Lwt for async HTTP)
- `src/client-cohttp-lwt/` - HTTP client using cohttp-lwt (asynchronous)
```

And in the "Library Structure" section (around line 57), add:

```markdown
- `opentelemetry-client-ocurl` - cURL-based HTTP collector client
- `opentelemetry-client-ocurl-lwt` - ezcurl-lwt-based HTTP collector client (threads + Lwt)
- `opentelemetry-client-cohttp-lwt` - cohttp-lwt HTTP collector client
```

**Step 2: Build to verify all changes**

Run: `make all`
Expected: Full build succeeds

**Step 3: Run full test suite**

Run: `make test`
Expected: All tests pass including new client-ocurl-lwt tests

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add client-ocurl-lwt to project documentation

Document new hybrid ezcurl-lwt client

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Final verification and testing

**Files:**
- None (verification only)

**Step 1: Clean build from scratch**

Run: `make clean && make all`
Expected: Clean build succeeds

**Step 2: Run all tests**

Run: `make test`
Expected: All tests pass

**Step 3: Check opam file was generated**

Run: `ls opentelemetry-client-ocurl-lwt.opam`
Expected: File exists

**Step 4: Verify package structure**

Run: `dune build @install`
Expected: Build succeeds, installable artifacts created

**Step 5: Manual smoke test (optional)**

Create a simple test program to verify basic functionality works:

```ocaml
(* test_smoke.ml *)
module OT = Opentelemetry
module C = Opentelemetry_client_ocurl_lwt

let () =
  let stop = Atomic.make false in
  let config = C.Config.make () in
  C.setup ~stop ~config ();

  (* Create a simple span *)
  let@ scope = OT.Trace.with_ "test-span" in
  Printf.printf "Created test span\n%!";

  (* Give time for background threads to process *)
  Unix.sleep 1;

  (* Clean shutdown *)
  Atomic.set stop true;
  C.remove_backend ();
  Printf.printf "Smoke test complete\n%!"
```

Run: `ocamlfind ocamlc -package opentelemetry,opentelemetry-client-ocurl-lwt -linkpkg test_smoke.ml -o test_smoke && ./test_smoke`
Expected: Runs without errors

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete client-ocurl-lwt implementation

Hybrid client using ezcurl-lwt for async HTTP with thread-based batching

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Notes

**DRY:** Reused B_queue, Batch modules from client-ocurl. Config pattern from opentelemetry.client.

**YAGNI:** Minimal implementation matching existing client patterns. No extra features.

**TDD:** Tests verify configuration and basic setup before complex functionality.

**Architecture tradeoffs:**
- Uses threads for batching (like client-ocurl) + Lwt for HTTP (like client-cohttp-lwt)
- Bridges Lwt/threads via Lwt.wait + Lwt_main.run in send_http_
- May have some overhead from bridging, but provides predictable batching with async HTTP
