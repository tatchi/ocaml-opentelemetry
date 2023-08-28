open Lwt.Syntax

let emit_stuff () =
  let* () = Lwt_unix.sleep 2.0 in
  Lwt.return_unit

let cleanup () =
  print_endline "at exit begin";
  let+ () = emit_stuff () in
  print_endline "at exit end"

let signal_waiter () =
  let waiter, wakener = Lwt.wait () in
  let handler signum =
    Format.eprintf "%s caught: stopping@."
      (if signum = Sys.sigint then
        "SIGINT"
      else if signum = Sys.sigterm then
        "SIGTERM"
      else
        "Signal");
    Lwt.wakeup_later wakener (128 - signum)
  in
  let _ = Lwt_unix.on_signal Sys.sigint handler in
  let _ = Lwt_unix.on_signal Sys.sigterm handler in
  waiter

let run' () =
  (* Sys.catch_break true; *)
  let p () =
    print_endline "start";
    let* () = Lwt_unix.sleep 2.0 in
    print_endline "end";
    Lwt.return_unit
  in
  let* () =
    Lwt.catch p (fun _ ->
        print_endline "finalize";
        Lwt.return_unit)
  in
  print_endline "END MAIN";
  Lwt.return_unit

let run () =
  let w = Lwt_mvar.create_empty () in
  let on_exist () =
    let* exit_code = Lwt.pick [ Lwt_mvar.take w; signal_waiter () ] in
    Printf.printf "exit_code = %d\n%!" exit_code;
    cleanup ()
  in
  let go () =
    let* () = run' () in
    Lwt_mvar.put w 0
  in
  Lwt.join [ go (); on_exist () ]

let () = Lwt_main.run @@ run ()
