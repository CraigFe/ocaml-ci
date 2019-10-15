open Current.Syntax

module Git = Current_git
module Github = Current_github
module Docker = Current_docker.Default

let pool_size =
  match Conf.profile with
  | `Production -> 20
  | `Dev -> 1

(* Limit number of concurrent builds. *)
let pool = Current.Pool.create ~label:"docker" pool_size

(* Maximum time for one Docker build. *)
let timeout = Duration.of_hour 1

(* Link for GitHub statuses. *)
let url ~owner ~name ~hash = Uri.of_string (Printf.sprintf "https://ci.ocamllabs.io/github/%s/%s/commit/%s" owner name hash)

let weekly = Current_cache.Schedule.v ~valid_for:(Duration.of_day 7) ()

let github_status_of_state ~head result =
  let+ head = head
  and+ result = result in
  let { Github.Repo_id.owner; name } = Github.Api.Commit.repo_id head in
  let hash = Github.Api.Commit.hash head in
  let url = url ~owner ~name ~hash in
  match result with
  | Ok _              -> Github.Api.Status.v ~url `Success ~description:"Passed"
  | Error (`Active _) -> Github.Api.Status.v ~url `Pending
  | Error (`Msg m)    -> Github.Api.Status.v ~url `Failure ~description:m

let set_active_refs ~repo xs =
  let+ repo = repo
  and+ xs = xs in
  let repo = Github.Api.Repo.id repo in
  Index.set_active_refs ~repo (
    xs |> List.map @@ fun x ->
    let commit = Github.Api.Commit.id x in
    let gref = Git.Commit_id.gref commit in
    let hash = Git.Commit_id.hash commit in
    (gref, hash)
  );
  xs

let build_with_docker ~repo src =
  let info =
    let+ info = Analyse.examine src in
    let opam_files = Analyse.Analysis.opam_files info in
    if opam_files = [] then failwith "No opam files found!";
    info
  in
  let build variant =
    let dockerfile =
      let+ base = Docker.pull ~schedule:weekly ("ocurrent/opam:" ^ variant)
      and+ repo = repo
      and+ info = info in
      Opam_build.dockerfile ~base ~info ~repo
    in
    variant, Docker.build ~timeout ~pool ~pull:false ~dockerfile (`Git src);
  in
  [
    build "alpine-3.10-ocaml-4.08";
    build "debian-10-ocaml-4.08";
  ]

let local_test repo () =
  let src = Git.Local.head_commit repo in
  let repo = Current.return { Github.Repo_id.owner = "local"; name = "test" } in
  build_with_docker ~repo src
  |> List.map (fun (_variant, build) -> Current.ignore_value build)
  |> Current.all

let v ~app () =
  Github.App.installations app |> Current.list_iter ~pp:Github.Installation.pp @@ fun installation ->
  let repos = Github.Installation.repositories installation in
  repos |> Current.list_iter ~pp:Github.Api.Repo.pp @@ fun repo ->
  let refs = Github.Api.Repo.ci_refs repo |> set_active_refs ~repo in
  refs |> Current.list_iter ~pp:Github.Api.Commit.pp @@ fun head ->
  let src = Git.fetch (Current.map Github.Api.Commit.id head) in
  let builds =
    let repo = Current.map Github.Api.Repo.id repo in
    build_with_docker ~repo src in
  let jobs = builds
             |> List.map (fun (variant, build) ->
                 let+ x = Current.Analysis.get build in
                 (variant, Current.Analysis.job_id x)
               )
             |> Current.list_seq
  in
  let index =
    let+ commit = head
    and+ jobs = jobs in
    Index.record ~commit jobs
  in
  let set_status =
    builds
    |> List.map (fun (_variant, build) -> Current.ignore_value build)
    |> Current.all
    |> Current.state
    |> github_status_of_state ~head
    |> Github.Api.Commit.set_status head "ocaml-ci"
  in
  Current.all [index; set_status]
