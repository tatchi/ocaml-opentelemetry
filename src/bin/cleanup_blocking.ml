let () =
  Sys.catch_break true;
  let cleanup () =
    print_endline "at exit begin";
    Unix.sleep 2;
    print_endline "at exit end"
  in
  try
    print_endline "start";
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle
         (fun _i ->
           print_endline "Signal_handle";
           cleanup ();
           exit 130));
    Unix.sleep 2;
    at_exit cleanup
  with Sys.Break ->
    print_endline "catch break";
    cleanup ()
