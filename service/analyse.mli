module Analysis : sig
  type t

  val opam_files : t -> string list
  val is_duniverse : t -> bool
end

val examine : Current_git.Commit.t Current.t -> Analysis.t Current.t
(** [examine src] returns a list of "*.opam" files in [src]. *)
