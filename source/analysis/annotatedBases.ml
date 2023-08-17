(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Core
open Ast
open Pyre

let base_is_from_placeholder_stub base_expression ~aliases ~from_empty_stub =
  let parsed = Expression.delocalize base_expression |> Type.create ~aliases in
  match parsed with
  | Type.Primitive primitive
  | Parametric { name = primitive; _ } ->
      Reference.create primitive |> fun reference -> from_empty_stub reference
  | _ -> false


let extends_placeholder_stub_class
    { Node.value = { ClassSummary.bases = { base_classes; metaclass; _ }; _ }; _ }
    ~aliases
    ~from_empty_stub
  =
  let metaclass_is_from_placeholder_stub =
    metaclass
    >>| base_is_from_placeholder_stub ~aliases ~from_empty_stub
    |> Option.value ~default:false
  in
  List.exists base_classes ~f:(base_is_from_placeholder_stub ~aliases ~from_empty_stub)
  || metaclass_is_from_placeholder_stub
