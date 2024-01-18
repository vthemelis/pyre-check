(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

val infer
  :  environment:Analysis.TypeEnvironment.ReadOnly.t ->
  global_module_paths_api:Analysis.GlobalModulePathsApi.t ->
  user_models:Registry.t ->
  Registry.t
