(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Core
open Analysis
open Ast
open Expression

let recognized_callable_target_types = Type.Set.of_list [Type.Primitive "TestCallableTarget"]

let redirect ~pyre_in_context { Call.callee; arguments } =
  let is_async_task base =
    PyrePysaApi.InContext.resolve_expression_to_type pyre_in_context base
    |> fun annotation -> Set.exists recognized_callable_target_types ~f:(Type.equal annotation)
  in
  match Node.value callee with
  | Name (Name.Attribute { base; attribute = "async_delay" | "async_schedule"; _ })
    when is_async_task base ->
      Some { Call.callee = base; arguments }
  | _ -> None
