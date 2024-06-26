(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Given a source path, return the corresponding module names for that path. This API will take
    into account any potential path translation done by the {!BuildSystem.t}.*)
val qualifiers_of_source_path_with_build_system
  :  build_system:BuildSystem.t ->
  source_code_api:Analysis.SourceCodeApi.t ->
  SourcePath.t ->
  Ast.Reference.t list

(** Given a Python module name, Return path to the corresponding Python source file as a string.
    This API will take into account any potential path translation done by the {!BuildSystem.t}. *)
val absolute_source_path_of_qualifier_with_build_system
  :  build_system:BuildSystem.t ->
  source_code_api:Analysis.SourceCodeApi.t ->
  Ast.Reference.t ->
  string option
