(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type t

module PyrePysaApi = Analysis.PyrePysaApi

(* Add the files that contain any of the given callables. *)
val from_callables
  :  scheduler:Scheduler.t ->
  pyre_api:PyrePysaApi.ReadOnly.t ->
  resolve_module_path:(Ast.Reference.t -> Interprocedural.RepositoryPath.t option) ->
  callables:Interprocedural.Target.t list ->
  t

val empty : t

val is_empty : t -> bool

val write_to_file : path:PyrePath.t -> t -> unit
