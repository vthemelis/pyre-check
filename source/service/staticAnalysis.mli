(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Analysis
open Ast
open Interprocedural

module Cache : sig
  type t

  val load : scheduler:Scheduler.t -> configuration:Configuration.Analysis.t -> enabled:bool -> t

  val class_hierarchy_graph : t -> (unit -> ClassHierarchyGraph.t) -> ClassHierarchyGraph.t

  val initial_callables : t -> (unit -> FetchCallables.t) -> FetchCallables.t

  val override_graph
    :  t ->
    (unit -> OverrideGraph.Heap.cap_overrides_result) ->
    OverrideGraph.Heap.cap_overrides_result
end

val type_check
  :  scheduler:Scheduler.t ->
  configuration:Configuration.Analysis.t ->
  cache:Cache.t ->
  TypeEnvironment.t

val parse_and_save_decorators_to_skip : inline_decorators:bool -> Configuration.Analysis.t -> unit

val purge_shared_memory : environment:TypeEnvironment.t -> qualifiers:Reference.t list -> unit
