open Lwt.Infix
open Result
open Logs_syslog_lwt_common
open Logs_syslog

let udp_reporter ?hostname ip ?(port = 514) () =
  let sa = Lwt_unix.ADDR_INET (ip, port) in
  let s = Lwt_unix.(socket PF_INET SOCK_DGRAM 0) in
  let m = Lwt_mutex.create () in
  let rec send msg =
    Lwt.catch (fun () ->
        Lwt_mutex.lock m >>= fun () ->
        let b = Bytes.of_string msg in
        Lwt_unix.sendto s b 0 (String.length msg) [] sa >|= fun _ ->
        Lwt_mutex.unlock m)
      (function
        | Unix.Unix_error (Unix.EAGAIN, _, _) -> Lwt_mutex.unlock m ; send msg
        | Unix.Unix_error (e, f, _) ->
          Printf.eprintf "error in %s %s while sending to %s:%d\n%s %s\n"
            f (Unix.error_message e) (Unix.string_of_inet_addr ip) port
            (Ptime.to_rfc3339 (Ptime_clock.now ()))
            msg ;
          Lwt_mutex.unlock m ;
          Lwt.return_unit)
  in
  (match hostname with
   | Some x -> Lwt.return x
   | None -> Lwt_unix.gethostname ()) >|= fun host ->
  syslog_report_common host Ptime_clock.now send

let tcp_reporter ?hostname ip ?(port = 514) ?(framing = `Null) () =
  let sa = Lwt_unix.ADDR_INET (ip, port) in
  let s = ref None in
  let m = Lwt_mutex.create () in
  (match hostname with
   | Some x -> Lwt.return x
   | None -> Lwt_unix.gethostname ()) >>= fun host ->
  let connect () =
    let sock = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    Lwt_unix.(setsockopt sock SO_REUSEADDR true) ;
    Lwt_unix.(setsockopt sock SO_KEEPALIVE true) ;
    Lwt.catch
      (fun () -> Lwt_unix.connect sock sa >|= fun () -> s := Some sock ; Ok ())
      (function Unix.Unix_error (e, f, _) ->
         let err =
           Printf.sprintf "error %s in function %s while connecting to %s:%d"
             (Unix.error_message e) f (Unix.string_of_inet_addr ip) port
         in
         Lwt.return (Error err))
  in
  let reconnect k msg =
    (* always called with mutex m being locked by the current task! *)
    (* before returning, need to unlock! *)
    connect () >>= function
    | Ok () -> Lwt_mutex.unlock m ; k msg
    | Error e ->
      Printf.eprintf "%s while sending syslog message\n%s %s\n"
        e (Ptime.to_rfc3339 (Ptime_clock.now ())) msg ;
      Lwt_mutex.unlock m ;
      Lwt.return_unit
  in
  connect () >>= function
  | Error e -> Lwt.return (Error e)
  | Ok () ->
    let rec send omsg =
      Lwt_mutex.lock m >>= fun () ->
      match !s with
      | None -> reconnect send omsg
      | Some sock ->
        let msg = Bytes.of_string (frame_message omsg framing) in
        let len = Bytes.length msg in
        let rec aux idx =
          Lwt.catch (fun () ->
              let should = len - idx in
              Lwt_unix.send sock msg idx (len - idx) [] >>= fun n ->
              if n = should then
                (Lwt_mutex.unlock m ; Lwt.return_unit)
              else
                aux (idx + n))
            (function
              | Unix.Unix_error (Unix.EAGAIN, _, _) ->
                Lwt_mutex.unlock m ; send omsg
              | Unix.Unix_error (e, f, _) ->
                let err = Unix.error_message e in
                Printf.eprintf "error %s in function %s, reconnecting\n"
                  err f ;
                Lwt.catch
                  (fun () -> Lwt_unix.close sock)
                  (function Unix.Unix_error _ -> Lwt.return_unit) >>= fun () ->
                s := None ;
                reconnect send omsg)
            in
            aux 0
    in
    Lwt.return (Ok (syslog_report_common host Ptime_clock.now send))
