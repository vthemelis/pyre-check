(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Analysis
open Ast
open Expression

module RegularTargets : sig
  type t = {
    implicit_self: bool;
    collapse_tito: bool;
    return_type: Type.t;
    targets: Target.t list;
  }
  [@@deriving eq, show]
end

module RawCallees : sig
  type t =
    | ConstructorTargets of {
        new_targets: Target.t list;
        init_targets: Target.t list;
        return_type: Type.t;
      }
    | RegularTargets of RegularTargets.t
    | HigherOrderTargets of {
        higher_order_function: RegularTargets.t;
        callable_argument: int * RegularTargets.t;
      }
  [@@deriving eq, show]

  val pp_option : Format.formatter -> t option -> unit
end

module Callees : sig
  type t =
    | Callees of RawCallees.t
    | SyntheticCallees of RawCallees.t String.Map.Tree.t
  [@@deriving eq, show]
end

val call_graph_of_define
  :  environment:Analysis.TypeEnvironment.ReadOnly.t ->
  define:Ast.Statement.Define.t ->
  Callees.t Ast.Location.Map.t

val call_name : Call.t -> string

val resolve_ignoring_optional : resolution:Resolution.t -> Ast.Expression.t -> Type.t

val redirect_special_calls : resolution:Resolution.t -> Call.t -> Call.t

module SharedMemory : sig
  val add : callable:Target.callable_t -> callees:Callees.t Location.Map.t -> unit

  (* Attempts to read the call graph for the given callable from shared memory. If it doesn't exist,
     computes the call graph and writes to shard memory. *)
  val get_or_compute
    :  callable:Target.callable_t ->
    environment:Analysis.TypeEnvironment.ReadOnly.t ->
    define:Ast.Statement.Define.t ->
    Callees.t Ast.Location.Map.t

  val remove : Target.callable_t list -> unit
end

val create_callgraph
  :  ?use_shared_memory:bool ->
  environment:TypeEnvironment.ReadOnly.t ->
  source:Source.t ->
  DependencyGraph.callgraph
