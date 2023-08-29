(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Ast
open Expression

module Heap : sig
  type t

  val empty : t

  val from_source : Source.t -> t
end

module SharedMemory : sig
  type t

  val create : unit -> t

  val add_heap : t -> Heap.t -> t

  val from_qualifiers
    :  handle:t ->
    scheduler:Scheduler.t ->
    environment:Analysis.TypeEnvironment.ReadOnly.t ->
    qualifiers:Reference.t list ->
    t

  module ReadOnly : sig
    type t

    val get : t -> Reference.t -> StringLiteral.t option
  end

  val read_only : t -> ReadOnly.t
end
