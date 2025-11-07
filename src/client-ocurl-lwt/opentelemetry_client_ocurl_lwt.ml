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
    let* r =
      try%lwt
        let headers = Config.Env.get_headers () in
        let headers =
          ("Content-Type", "application/x-protobuf")
          :: ("Accept", "application/x-protobuf")
          :: headers
        in

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
