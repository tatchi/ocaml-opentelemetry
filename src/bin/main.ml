module Otel = Opentelemetry

let inner () =
  match Otel.Scope.get_surrounding () with
  | None -> print_endline "no surrounding scope"
  | Some scope ->
    print_endline "got surrounding scope";
    let event = Otel.Event.make "adding event from inner to outer scope" in
    Otel.Scope.add_event scope (fun () -> event);
    (* let span_id = scope.span_id in *)
    Trace.with_span ~__FUNCTION__ ~__FILE__ ~__LINE__ "my trace span"
    @@ fun _span -> Thread.delay 0.3

let bar () =
  Otel.Trace.with_ "inner trace" @@ fun _inner_scope ->
  inner ();
  Thread.delay 1.0;
  prerr_endline "world"

let foo () =
  print_endline "hello";
  Otel.Trace.with_ "my trace" ~attrs:[ "hello", `String "world" ]
  @@ fun scope ->
  (* Otel.Metrics.(emit [ gauge ~name:"foo.x" [ int 42 ] ]); *)
  let trace_id = scope.trace_id in
  (* let span_id = scope.span_id in *)
  let event = Otel.Event.make "my event!" in
  Otel.Scope.add_event scope (fun () -> event);
  bar ()

let () =
  Otel.Globals.service_name := "coco";
  Otel.GC_metrics.basic_setup ();
  Otel.Globals.add_global_attribute "global attribute" (`String "coucou");
  let config =
    Opentelemetry_client_ocurl.Config.make ~debug:true
      ~url:"http://localhost:4318" ()
  in
  Opentelemetry_trace.setup ();
  Opentelemetry_client_ocurl.with_setup ~config () @@ fun () -> foo ()
