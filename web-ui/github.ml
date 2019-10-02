open Lwt.Infix

module Capability = Capnp_rpc_lwt.Capability
module Client = Ocaml_ci_api.Client
module Server = Cohttp_lwt_unix.Server
module Response = Cohttp.Response.Make(Server.IO)
module Transfer_IO = Cohttp__Transfer_io.Make(Server.IO)

let errorf fmt =
  fmt |> Fmt.kstrf @@ fun msg -> Error (`Msg msg)

let normal_response x =
  x >|= fun x -> `Response x

let respond_error status body =
  let headers = Cohttp.Header.init_with "Content-Type" "text/plain" in
  Server.respond_error ~status ~headers ~body () |> normal_response

let commit_url ~owner ~name commit =
  Printf.sprintf "/github/%s/%s/commit/%s" owner name commit

let format_refs ~owner ~name refs =
  let open Tyxml.Html in
  ul (
    Client.Ref_map.to_seq refs |> List.of_seq |> List.map @@ fun (branch, commit) ->
    li [a ~a:[a_href (commit_url ~owner ~name commit)] [txt branch]]
  )

let with_ref r fn =
  Lwt.finalize
    (fun () -> fn r)
    (fun () -> Capnp_rpc_lwt.Capability.dec_ref r; Lwt.return_unit)

let stream_logs job (data, next) writer =
  let header, footer =
    let body = Template.instance Tyxml.Html.[
        pre [txt "@@@"]
      ] in
    Astring.String.cut ~sep:"@@@" body |> Option.get
  in
  Transfer_IO.write writer (header ^ data) >>= fun () ->
  let rec aux next =
    Current_rpc.Job.log job ~start:next >>= function
    | Ok ("", _) ->
      Transfer_IO.write writer footer
    | Ok (data, next) ->
      Transfer_IO.write writer data >>= fun () ->
      aux next
    | Error (`Capnp ex) ->
      Log.warn (fun f -> f "Error fetching logs: %a" Capnp_rpc.Error.pp ex);
      Transfer_IO.write writer (Fmt.strf "ocaml-ci error: %a@." Capnp_rpc.Error.pp ex)
  in
  aux next

let repo_get ~owner ~name ~repo = function
  | [] ->
    begin
      Client.Repo.refs repo >>= function
      | Error `Capnp ex -> respond_error `Bad_request (Fmt.to_to_string Capnp_rpc.Error.pp ex)
      | Ok refs ->
        let body = Template.instance [
            format_refs ~owner ~name refs
          ] in
        Server.respond_string ~status:`OK ~body () |> normal_response
    end
  | ["commit"; commit] ->
    begin
      with_ref (Client.Repo.job_of_commit repo commit) @@ fun job ->
      Current_rpc.Job.log job ~start:0L >>= function
      | Error `Capnp ex -> respond_error `Bad_request (Fmt.to_to_string Capnp_rpc.Error.pp ex)
      | Ok chunk ->
        let headers =
          (* Otherwise, an nginx reverse proxy will wait for the whole log before sending anything. *)
          Cohttp.Header.init_with "X-Accel-Buffering" "no"
        in
        let res = Cohttp.Response.make ~status:`OK ~flush:true ~encoding:Cohttp.Transfer.Chunked ~headers () in
        let write _ic oc =
          let flush = Cohttp.Response.flush res in
          let writer = Transfer_IO.make_writer ~flush Cohttp.Transfer.Chunked oc in
          Lwt.finalize
            (fun () ->
               stream_logs job chunk writer >>= fun () ->
               Server.IO.write oc "0\r\n\r\n"
            )
            (fun () ->
               Capability.dec_ref job;
               Lwt.return_unit
            )
        in
        Capability.inc_ref job;
        Lwt.return (`Expert (res, write))
    end
  | _ ->
      Server.respond_not_found () |> normal_response

let get ~backend = function
  | owner :: name :: path ->
    Backend.ci backend >>= fun ci ->
    with_ref (Client.CI.org ci owner) @@ fun org ->
    with_ref (Client.Org.repo org name) @@ fun repo ->
    repo_get ~owner ~name ~repo path
  | _ ->
    Server.respond_not_found () |> normal_response
