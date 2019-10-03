open Current.Syntax

module Git = Current_git
module Github = Current_github
module Docker = Current_docker.Default

let pool_size =
  match Conf.profile with
  | `Production -> 20
  | `Dev -> 1

(* Limit number of concurrent builds. *)
let pool = Lwt_pool.create pool_size Lwt.return

(* Maximum time for one Docker build. *)
let timeout = Duration.of_hour 1

(* Link for GitHub statuses. *)
let url ~owner ~name ~hash = Uri.of_string (Printf.sprintf "https://ci.ocamllabs.io/github/%s/%s/commit/%s" owner name hash)

let weekly = Current_cache.Schedule.v ~valid_for:(Duration.of_day 7) ()

let crunch_list items = Dockerfile.(crunch (empty @@@ items))

(* Group opam files by directory.
   e.g. ["a/a1.opam"; "a/a2.opam"; "b/b1.opam"] ->
        [("a", ["a/a1.opam"; "a/a2.opam"]);
         ("b", ["b/b1.opam"])
        ] *)
let group_opam_files =
  ListLabels.fold_left ~init:[] ~f:(fun acc x ->
      let item = Fpath.v x in
      let dir = Fpath.parent item in
      match acc with
      | (prev_dir, prev_items) :: rest when Fpath.equal dir prev_dir -> (prev_dir, x :: prev_items) :: rest
      | _ -> (dir, [x]) :: acc
    )

(* Generate Dockerfile instructions to copy all the files in [items] into the
   image, creating the necessary directories first, and then pin them all. *)
let pin_opam_files groups =
  let open Dockerfile in
  let dirs = groups |> List.map (fun (dir, _) -> Printf.sprintf "%S" (Fpath.to_string dir)) |> String.concat " " in
  (run "mkdir -p %s" dirs @@@ (
    groups |> List.map (fun (dir, files) ->
        copy ~src:files ~dst:(Fpath.to_string dir) ()
      )
  )) @@ crunch_list (
    groups |> List.map (fun (dir, files) ->
        files
        |> List.map (fun file ->
            run "opam pin add -yn %s.dev %S" (Filename.basename file |> Filename.chop_extension) (Fpath.to_string dir)
          )
        |> crunch_list
      )
  )

let download_cache = "--mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000"

(* Generate a Dockerfile for building all the opam packages in the build context. *)
let dockerfile ~base ~info =
  let opam_files = Analyse.Analysis.opam_files info in
  let groups = group_opam_files opam_files in
  let dirs = groups |> List.map (fun (dir, _) -> Printf.sprintf "%S" (Fpath.to_string dir)) |> String.concat " " in
  let open Dockerfile in
  comment "syntax = docker/dockerfile:experimental" @@
  from (Docker.Image.hash base) @@
  workdir "/src" @@
  run "sudo chown opam /src" @@
  pin_opam_files groups @@
  run "%s opam install %s --show-actions --deps-only -t | awk '/- install/{print $3}' | xargs opam depext -iy" download_cache dirs @@
  copy ~chown:"opam" ~src:["."] ~dst:"/src/" () @@
  run "%s opam install -tv ." download_cache

let github_status_of_state ~repo ~head result =
  let+ repo = repo
  and+ head = head
  and+ result = result in
  let { Github.Repo_id.owner; name } = repo in
  let hash = Github.Api.Commit.hash head in
  let url = url ~owner ~name ~hash in
  match result with
  | Ok _              -> Github.Api.Status.v ~url `Success ~description:"Passed"
  | Error (`Active _) -> Github.Api.Status.v ~url `Pending
  | Error (`Msg m)    -> Github.Api.Status.v ~url `Failure ~description:m

let set_active_refs ~repo xs =
  let+ repo = repo
  and+ xs = xs in
  Index.set_active_refs ~repo (
    xs |> List.map @@ fun x ->
    let commit = Github.Api.Commit.id x in
    let gref = Git.Commit_id.gref commit in
    let hash = Git.Commit_id.hash commit in
    (gref, hash)
  );
  xs

let v ~app () =
  Github.App.installations app |> Current.list_iter ~pp:Github.Installation.pp @@ fun installation ->
  let github = Current.map Github.Installation.api installation in
  let repos = Github.Installation.repositories installation in
  repos |> Current.list_iter ~pp:Github.Repo_id.pp @@ fun repo ->
  let refs = Github.Api.ci_refs_dyn github repo |> set_active_refs ~repo in
  refs |> Current.list_iter ~pp:Github.Api.Commit.pp @@ fun head ->
  let src = Git.fetch (Current.map Github.Api.Commit.id head) in
  let dockerfile =
    let+ base = Docker.pull ~schedule:weekly "ocurrent/opam:alpine-3.10-ocaml-4.08"
    and+ info = Analyse.examine src in
    let opam_files = Analyse.Analysis.opam_files info in
    if opam_files = [] then failwith "No opam files found!";
    dockerfile ~base ~info
  in
  let build = Docker.build ~timeout ~pool ~pull:false ~dockerfile (`Git src) in
  let index =
    let+ commit = head
    and+ job_id = Current.Analysis.get build |> Current.(map Analysis.job_id) in
    Option.iter (Index.record ~commit) job_id
  in
  let set_status =
    build
    |> Current.state
    |> github_status_of_state ~repo ~head
    |> Github.Api.Commit.set_status head "ocaml-ci"
  in
  Current.all [index; set_status]
