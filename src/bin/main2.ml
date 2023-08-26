let () =
  try
    let pid = Unix.getpid () in
    Printf.printf "pid = %d\n%!" pid;
    Sys.catch_break true;
    (* Sys.set_signal Sys.sigint
       (Sys.Signal_handle (fun _ -> print_endline "Custom SIGINT handler")); *)
    (* ignore (Thread.sigmask Unix.SIG_BLOCK [ 2 ] : _ list); *)
    Thread.delay 10.0
  with _ -> print_endline "catched"
