# Client-OCurl-Lwt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add opentelemetry-client-ocurl-lwt package using ezcurl-lwt for fully async Lwt-based HTTP telemetry export

**Architecture:** Fully Lwt-based like client-cohttp-lwt. Uses opentelemetry.client.Batch for batching, ezcurl-lwt for HTTP. No threads, all async. Push triggers async emit checks, ticker thread ensures timeout-based emits.

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
  opentelemetry.client
  pbrt
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

let[@inline] ( let@ ) f x = f x

let spf = Printf.sprintf

let tid () = Thread.id @@ Thread.self ()
```

**Step 4: Create config.mli interface**

Create `src/client-ocurl-lwt/config.mli`:

```ocaml
type t = Opentelemetry_client.Config.t
(** Configuration.

    To build one, use {!make} below. This might be extended with more fields in
    the future. *)

val pp : Format.formatter -> t -> unit

val make : (unit -> t) Opentelemetry_client.Config.make
(** Make a configuration {!t}. *)

module Env : Opentelemetry_client.Config.ENV
```

**Step 5: Create config.ml implementation**

Create `src/client-ocurl-lwt/config.ml`:

```ocaml
type t = Opentelemetry_client.Config.t

let pp = Opentelemetry_client.Config.pp

let make = Opentelemetry_client.Config.make

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
  ocurl
  (lwt
   (>= "5.3"))
  (lwt_ppx
   (>= "2.0"))
  (alcotest :with-test))
 (synopsis "Collector client for opentelemetry, using ezcurl-lwt"))
```

**Step 7: Build to verify structure**

Run: `dune build src/client-ocurl-lwt/`
Expected: Build succeeds or fails only because main .mli/.ml files are empty

**Step 8: Commit**

```bash
git add src/client-ocurl-lwt/ dune-project
git commit -m "feat: add client-ocurl-lwt package structure

Create new package using ezcurl-lwt for fully async Lwt-based export

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: Implement public interface (.mli file)

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli`

**Step 1: Write the interface file**

Write to `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli`:

```ocaml
(*
   TODO: more options from
   https://opentelemetry.io/docs/reference/specification/protocol/exporter/
   *)

open Common_

val get_headers : unit -> (string * string) list

val set_headers : (string * string) list -> unit
(** Set http headers that are sent on every http query to the collector. *)

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

val remove_backend : unit -> unit Lwt.t
(** Shutdown current backend
    @since NEXT_RELEASE *)

val with_setup :
  ?stop:bool Atomic.t ->
  ?config:Config.t ->
  ?enable:bool ->
  unit ->
  (unit -> 'a Lwt.t) ->
  'a Lwt.t
(** [with_setup () f] is like [setup(); f()] but takes care of cleaning up after
    [f()] returns See {!setup} for more details. *)
```

**Step 2: Build to check interface**

Run: `dune build src/client-ocurl-lwt/`
Expected: Build fails with "Unbound module" errors (implementation not done yet)

**Step 3: Commit**

```bash
git add src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.mli
git commit -m "feat: add public interface for client-ocurl-lwt

Define API matching client-cohttp-lwt pattern with Lwt

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Implement HTTP client module

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
module Signal = Opentelemetry_client.Signal
module Batch = Opentelemetry_client.Batch
open Opentelemetry
open Common_

let set_headers = Config.Env.set_headers

let get_headers = Config.Env.get_headers

external reraise : exn -> 'a = "%reraise"
(** This is equivalent to [Lwt.reraise]. We inline it here so we don't force to
    use Lwt's latest version *)

let needs_gc_metrics = Atomic.make false

let last_gc_metrics = Atomic.make (Mtime_clock.now ())

let timeout_gc_metrics = Mtime.Span.(20 * s)

let gc_metrics = ref []
(* side channel for GC, appended to {!E_metrics}'s data *)

(* capture current GC metrics if {!needs_gc_metrics} is true,
   or it has been a long time since the last GC metrics collection,
   and push them into {!gc_metrics} for later collection *)
let sample_gc_metrics_if_needed () =
  let now = Mtime_clock.now () in
  let alarm = Atomic.compare_and_set needs_gc_metrics true false in
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
    gc_metrics := l :: !gc_metrics
  )

type error =
  [ `Status of int * Opentelemetry.Proto.Status.status
  | `Failure of string
  | `Sysbreak
  ]

let n_errors = Atomic.make 0

let n_dropped = Atomic.make 0

let report_err_ = function
  | `Sysbreak -> Printf.eprintf "opentelemetry: ctrl-c captured, stopping\n%!"
  | `Failure msg ->
    Format.eprintf "@[<2>opentelemetry: export failed: %s@]@." msg
  | `Status (code, { Opentelemetry.Proto.Status.code = scode; message; details })
    ->
    let pp_details out l =
      List.iter
        (fun s -> Format.fprintf out "%S;@ " (Bytes.unsafe_to_string s))
        l
    in
    Format.eprintf
      "@[<2>opentelemetry: export failed with@ http code=%d@ status \
       {@[code=%ld;@ message=%S;@ details=[@[%a@]]@]}@]@."
      code scode
      (Bytes.unsafe_to_string message)
      pp_details details
```

**Step 2: Implement HTTP client module**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
module Httpc : sig
  type t

  val create : unit -> t

  val send :
    t ->
    url:string ->
    decode:[ `Dec of Pbrt.Decoder.t -> 'a | `Ret of 'a ] ->
    string ->
    ('a, error) result Lwt.t

  val cleanup : t -> unit
end = struct
  open Opentelemetry.Proto
  open Lwt.Syntax

  type t = unit

  let create () : t = ()

  let cleanup _self = ()

  (* send the content to the remote endpoint/path *)
  let send (_self : t) ~url ~decode (bod : string) : ('a, error) result Lwt.t =
    let open Lwt.Syntax in

    let* r =
      try%lwt
        let headers = Config.Env.get_headers () in
        let headers = ("Content-Type", "application/x-protobuf") :: headers in

        let+ result =
          Ezcurl_lwt.post ~headers ~params:[] ~url ~content:(`String bod) ()
        in
        Ok result
      with e -> Lwt.return @@ Error e
    in
    match r with
    | Error e ->
      let err =
        `Failure
          (spf "sending signals via http POST to %S\nfailed with:\n%s" url
             (Printexc.to_string e))
      in
      Lwt.return @@ Error err
    | Ok (Ok { Ezcurl.code; body; _ }) ->
      if code >= 200 && code < 300 then (
        match decode with
        | `Ret x -> Lwt.return @@ Ok x
        | `Dec f ->
          let dec = Pbrt.Decoder.of_string body in
          let r =
            try Ok (f dec)
            with e ->
              let bt = Printexc.get_backtrace () in
              Error
                (`Failure
                   (spf "decoding failed with:\n%s\n%s" (Printexc.to_string e)
                      bt))
          in
          Lwt.return r
      ) else (
        let dec = Pbrt.Decoder.of_string body in

        let r =
          try
            let status = Status.decode_pb_status dec in
            Error (`Status (code, status))
          with e ->
            let bt = Printexc.get_backtrace () in
            Error
              (`Failure
                 (spf
                    "httpc: decoding of status (url=%S, code=%d) failed with:\n\
                     %s\n\
                     status: %S\n\
                     %s"
                    url code (Printexc.to_string e) body bt))
        in
        Lwt.return r
      )
    | Ok (Error (code, msg)) ->
      Lwt.return @@ Error (`Failure (spf "curl error %s: %s" (Curl.strerror code) msg))
end
```

**Step 3: Build to verify Httpc compiles**

Run: `dune build src/client-ocurl-lwt/`
Expected: Partial build, may fail on missing emitter functions

**Step 4: Commit**

```bash
git add src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml
git commit -m "feat: implement HTTP client with ezcurl-lwt

Add Lwt-based HTTP POST using ezcurl-lwt

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Implement EMITTER module

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`

**Step 1: Add EMITTER interface**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
(** An emitter. This is used by {!Backend} below to forward traces/metrics/…
    from the program to whatever collector client we have. *)
module type EMITTER = sig
  open Opentelemetry.Proto

  val push_trace : Trace.resource_spans list -> unit

  val push_metrics : Metrics.resource_metrics list -> unit

  val push_logs : Logs.resource_logs list -> unit

  val set_on_tick_callbacks : (unit -> unit) AList.t -> unit

  val tick : unit -> unit

  val cleanup : on_done:(unit -> unit) -> unit -> unit
end
```

**Step 2: Implement mk_emitter function (part 1: setup)**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
(* make an emitter.

   exceptions inside should be caught, see
   https://opentelemetry.io/docs/reference/specification/error-handling/ *)
let mk_emitter ~stop ~(config : Config.t) () : (module EMITTER) =
  let open Proto in
  let open Lwt.Syntax in
  (* local helpers *)
  let open struct
    let timeout =
      if config.batch_timeout_ms > 0 then
        Some Mtime.Span.(config.batch_timeout_ms * ms)
      else
        None

    let batch_traces : Trace.resource_spans Batch.t =
      Batch.make ?batch:config.batch_traces ?timeout ()

    let batch_metrics : Metrics.resource_metrics Batch.t =
      Batch.make ?batch:config.batch_metrics ?timeout ()

    let batch_logs : Logs.resource_logs Batch.t =
      Batch.make ?batch:config.batch_logs ?timeout ()

    let on_tick_cbs_ = Atomic.make (AList.make ())

    let set_on_tick_callbacks = Atomic.set on_tick_cbs_

    let send_http_ (httpc : Httpc.t) ~url data : unit Lwt.t =
      let* r = Httpc.send httpc ~url ~decode:(`Ret ()) data in
      match r with
      | Ok () -> Lwt.return ()
      | Error `Sysbreak ->
        Printf.eprintf "ctrl-c captured, stopping\n%!";
        Atomic.set stop true;
        Lwt.return ()
      | Error err ->
        (* TODO: log error _via_ otel? *)
        Atomic.incr n_errors;
        report_err_ err;
        (* avoid crazy error loop *)
        Lwt_unix.sleep 3.

    let send_metrics_http client (l : Metrics.resource_metrics list) =
      Signal.Encode.metrics l |> send_http_ client ~url:config.url_metrics

    let send_traces_http client (l : Trace.resource_spans list) =
      Signal.Encode.traces l |> send_http_ client ~url:config.url_traces

    let send_logs_http client (l : Logs.resource_logs list) =
      Signal.Encode.logs l |> send_http_ client ~url:config.url_logs

    (* emit metrics, if the batch is full or timeout lapsed *)
    let emit_metrics_maybe ~now ?force httpc : bool Lwt.t =
      match Batch.pop_if_ready ?force ~now batch_metrics with
      | None -> Lwt.return false
      | Some l ->
        let batch = !gc_metrics @ l in
        gc_metrics := [];
        let+ () = send_metrics_http httpc batch in
        true

    let emit_traces_maybe ~now ?force httpc : bool Lwt.t =
      match Batch.pop_if_ready ?force ~now batch_traces with
      | None -> Lwt.return false
      | Some l ->
        let+ () = send_traces_http httpc l in
        true

    let emit_logs_maybe ~now ?force httpc : bool Lwt.t =
      match Batch.pop_if_ready ?force ~now batch_logs with
      | None -> Lwt.return false
      | Some l ->
        let+ () = send_logs_http httpc l in
        true

    let[@inline] guard_exn_ where f =
      try f ()
      with e ->
        let bt = Printexc.get_backtrace () in
        Printf.eprintf
          "opentelemetry-ocurl-lwt: uncaught exception in %s: %s\n%s\n%!" where
          (Printexc.to_string e) bt

    let emit_all_force (httpc : Httpc.t) : unit Lwt.t =
      let now = Mtime_clock.now () in
      let+ (_ : bool) = emit_traces_maybe ~now ~force:true httpc
      and+ (_ : bool) = emit_logs_maybe ~now ~force:true httpc
      and+ (_ : bool) = emit_metrics_maybe ~now ~force:true httpc in
      ()

    (* thread that calls [tick()] regularly, to help enforce timeouts *)
    let setup_ticker_thread ~tick ~finally () =
      let rec tick_thread () =
        if Atomic.get stop then (
          finally ();
          Lwt.return ()
        ) else
          let* () = Lwt_unix.sleep 0.5 in
          let* () = tick () in
          tick_thread ()
      in
      Lwt.async tick_thread
  end in
  let httpc = Httpc.create () in

  let module M = struct
    (* we make sure that this is thread-safe, even though we don't have a
       background thread. There can still be a ticker thread, and there
       can also be several user threads that produce spans and call
       the emit functions. *)

    let push_to_batch b e =
      match Batch.push b e with
      | `Ok -> ()
      | `Dropped -> Atomic.incr n_errors

    let push_trace e =
      let@ () = guard_exn_ "push trace" in
      push_to_batch batch_traces e;
      let now = Mtime_clock.now () in
      Lwt.async (fun () ->
          let+ (_ : bool) = emit_traces_maybe ~now httpc in
          ())

    let push_metrics e =
      let@ () = guard_exn_ "push metrics" in
      sample_gc_metrics_if_needed ();
      push_to_batch batch_metrics e;
      let now = Mtime_clock.now () in
      Lwt.async (fun () ->
          let+ (_ : bool) = emit_metrics_maybe ~now httpc in
          ())

    let push_logs e =
      let@ () = guard_exn_ "push logs" in
      push_to_batch batch_logs e;
      let now = Mtime_clock.now () in
      Lwt.async (fun () ->
          let+ (_ : bool) = emit_logs_maybe ~now httpc in
          ())

    let set_on_tick_callbacks = set_on_tick_callbacks

    let tick_ () =
      if Config.Env.get_debug () then
        Printf.eprintf "tick (from %d)\n%!" (tid ());
      sample_gc_metrics_if_needed ();
      List.iter
        (fun f ->
          try f ()
          with e ->
            Printf.eprintf "on tick callback raised: %s\n"
              (Printexc.to_string e))
        (AList.get @@ Atomic.get on_tick_cbs_);
      let now = Mtime_clock.now () in
      let+ (_ : bool) = emit_traces_maybe ~now httpc
      and+ (_ : bool) = emit_logs_maybe ~now httpc
      and+ (_ : bool) = emit_metrics_maybe ~now httpc in
      ()

    let () = setup_ticker_thread ~tick:tick_ ~finally:ignore ()

    (* if called in a blocking context: work in the background *)
    let tick () = Lwt.async tick_

    let cleanup ~on_done () =
      if Config.Env.get_debug () then
        Printf.eprintf "opentelemetry: exiting…\n%!";
      Lwt.async (fun () ->
          let* () = emit_all_force httpc in
          Httpc.cleanup httpc;
          on_done ();
          Lwt.return ())
  end in
  (module M)
```

**Step 3: Build to verify emitter compiles**

Run: `dune build src/client-ocurl-lwt/`
Expected: Partial build, may fail on Backend module

**Step 4: Commit**

```bash
git add src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml
git commit -m "feat: implement EMITTER with async batching

Add Lwt-based push, emit, and ticker logic

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Implement Backend and public API

**Files:**
- Modify: `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`

**Step 1: Implement Backend functor**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
module Backend
    (Arg : sig
      val stop : bool Atomic.t

      val config : Config.t
    end)
    () : Opentelemetry.Collector.BACKEND = struct
  include (val mk_emitter ~stop:Arg.stop ~config:Arg.config ())

  open Opentelemetry.Proto
  open Opentelemetry.Collector

  let send_trace : Trace.resource_spans list sender =
    {
      send =
        (fun l ~ret ->
          (if Config.Env.get_debug () then
             let@ () = Lock.with_lock in
             Format.eprintf "send spans %a@."
               (Format.pp_print_list Trace.pp_resource_spans)
               l);
          push_trace l;
          ret ());
    }

  let last_sent_metrics = Atomic.make (Mtime_clock.now ())

  let timeout_sent_metrics = Mtime.Span.(5 * s)
  (* send metrics from time to time *)

  let signal_emit_gc_metrics () =
    if Config.Env.get_debug () then
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
      [
        make_resource_metrics
          [
            sum ~name:"otel.export.dropped" ~is_monotonic:true
              [
                int
                  ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                  ~now:(Mtime.to_uint64_ns now) (Atomic.get n_dropped);
              ];
            sum ~name:"otel.export.errors" ~is_monotonic:true
              [
                int
                  ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                  ~now:(Mtime.to_uint64_ns now) (Atomic.get n_errors);
              ];
          ];
      ]
    ) else
      []

  let send_metrics : Metrics.resource_metrics list sender =
    {
      send =
        (fun m ~ret ->
          (if Config.Env.get_debug () then
             let@ () = Lock.with_lock in
             Format.eprintf "send metrics %a@."
               (Format.pp_print_list Metrics.pp_resource_metrics)
               m);

          let m = List.rev_append (additional_metrics ()) m in
          push_metrics m;
          ret ());
    }

  let send_logs : Logs.resource_logs list sender =
    {
      send =
        (fun m ~ret ->
          (if Config.Env.get_debug () then
             let@ () = Lock.with_lock in
             Format.eprintf "send logs %a@."
               (Format.pp_print_list Logs.pp_resource_logs)
               m);

          push_logs m;
          ret ());
    }
end
```

**Step 2: Implement public API functions**

Continue `src/client-ocurl-lwt/opentelemetry_client_ocurl_lwt.ml`:

```ocaml
let create_backend ?(stop = Atomic.make false) ?(config = Config.make ()) () =
  let module B =
    Backend
      (struct
        let stop = stop

        let config = config
      end)
      ()
  in
  (module B : OT.Collector.BACKEND)

let setup_ ?stop ?config () : unit =
  let backend = create_backend ?stop ?config () in
  OT.Collector.set_backend backend;
  ()

let setup ?stop ?config ?(enable = true) () =
  if enable then setup_ ?stop ?config ()

let remove_backend () : unit Lwt.t =
  let done_fut, done_u = Lwt.wait () in
  OT.Collector.remove_backend ~on_done:(fun () -> Lwt.wakeup_later done_u ()) ();
  done_fut

let with_setup ?stop ?(config = Config.make ()) ?(enable = true) () f : _ Lwt.t
    =
  if enable then (
    let open Lwt.Syntax in
    setup_ ?stop ~config ();

    Lwt.catch
      (fun () ->
        let* res = f () in
        let+ () = remove_backend () in
        res)
      (fun exn ->
        let* () = remove_backend () in
        reraise exn)
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
git commit -m "feat: complete client-ocurl-lwt implementation

Add Backend functor and public API with Lwt

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

Create `tests/ocurl-lwt/test_urls.ml`:

```ocaml
module OT = Opentelemetry
module C = Opentelemetry_client_ocurl_lwt

let () =
  let config1 = C.Config.make () in
  Printf.printf "config1: %a\n%!" C.Config.pp config1;
  assert (config1.url_traces = "http://localhost:4318/v1/traces");
  assert (config1.url_metrics = "http://localhost:4318/v1/metrics");
  assert (config1.url_logs = "http://localhost:4318/v1/logs");
  ()

let () =
  let config2 = C.Config.make ~url:"http://example.com:1234" () in
  Printf.printf "config2: %a\n%!" C.Config.pp config2;
  assert (config2.url_traces = "http://example.com:1234/v1/traces");
  assert (config2.url_metrics = "http://example.com:1234/v1/metrics");
  assert (config2.url_logs = "http://example.com:1234/v1/logs");
  ()

let () =
  let config3 =
    C.Config.make ~url_traces:"http://example.com/traces"
      ~url_metrics:"http://example.com/metrics"
      ~url_logs:"http://example.com/logs" ()
  in
  Printf.printf "config3: %a\n%!" C.Config.pp config3;
  assert (config3.url_traces = "http://example.com/traces");
  assert (config3.url_metrics = "http://example.com/metrics");
  assert (config3.url_logs = "http://example.com/logs");
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

Test URL configuration

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Update documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add client-ocurl-lwt to documentation**

Modify `CLAUDE.md`, in the "Client Implementations" section (around line 21), update to:

```markdown
- `src/client-ocurl/` - HTTP client using cURL (synchronous, thread-based)
- `src/client-ocurl-lwt/` - HTTP client using ezcurl-lwt (async Lwt-based)
- `src/client-cohttp-lwt/` - HTTP client using cohttp-lwt (async Lwt-based)
```

And in the "Library Structure" section (around line 57), update to:

```markdown
- `opentelemetry-client-ocurl` - cURL-based HTTP collector client (thread-based)
- `opentelemetry-client-ocurl-lwt` - ezcurl-lwt-based HTTP collector client (Lwt async)
- `opentelemetry-client-cohttp-lwt` - cohttp-lwt HTTP collector client (Lwt async)
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

Document new Lwt-based ezcurl-lwt client

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Final verification

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

**Step 5: Format code**

Run: `make format`
Expected: Code formatted successfully

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete client-ocurl-lwt implementation

Fully async Lwt-based client using ezcurl-lwt for HTTP

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Notes

**DRY:** Uses opentelemetry.client.Batch and Config. HTTP logic adapted from client-cohttp-lwt pattern.

**YAGNI:** Minimal implementation matching client-cohttp-lwt architecture. No extra features.

**TDD:** Tests verify configuration before complex functionality.

**Architecture:**
- Fully Lwt-based, no threads for batching
- Uses opentelemetry.client.Batch for shared batching logic
- ezcurl-lwt for async HTTP instead of cohttp-lwt
- Simpler config (wraps opentelemetry.client.Config.t directly)
- Async push triggers emit checks, ticker thread ensures timeout-based emits
