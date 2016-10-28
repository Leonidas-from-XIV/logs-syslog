open Logs_syslog

let syslog_report_common host now send =
  let report src level ~over k msgf =
    let source = Logs.Src.name src in
    let timestamp = now () in
    let k tags _ =
      let msg = message ~host ~source ~tags level timestamp (flush ()) in
      let bytes = Syslog_message.encode msg in
      let unblock () = over () ; Lwt.return_unit in
      Lwt.finalize (fun () -> send bytes) unblock |> Lwt.ignore_result ; k ()
    in
    msgf @@ fun ?header:_h ?(tags = Logs.Tag.empty) fmt ->
    Format.kfprintf (k tags) ppf fmt
  in
  { Logs.report }
