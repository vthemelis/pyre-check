(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* TODO(T132410158) Add a module-level doc comment. *)

open Base

exception JsonError of string

module BuckOptions = struct
  type t = {
    raw: Raw.t;
    mode: string option;
    isolation_prefix: string option;
    use_buck2: bool;
  }
end

module BuildResult = struct
  type t = {
    build_map: BuildMap.t;
    targets: Target.t list;
  }
end

module IncompatibleMergeItem = struct
  type t = {
    key: string;
    left_value: string;
    right_value: string;
  }
  [@@deriving sexp, compare]
end

exception FoundIncompatibleMergeItem of IncompatibleMergeItem.t

let resolve_merge_conflict_by_name ~key left_value right_value =
  if String.equal left_value right_value then
    left_value
  else
    raise (FoundIncompatibleMergeItem { IncompatibleMergeItem.key; left_value; right_value })


let resolve_merge_conflict_by_name_and_content ~source_root ~key left_value right_value =
  let read_file path = Stdio.In_channel.read_all (PyrePath.absolute path) in
  let content_equal left_value right_value =
    let left_content =
      PyrePath.create_relative ~root:source_root ~relative:left_value |> read_file
    in
    let right_content =
      PyrePath.create_relative ~root:source_root ~relative:right_value |> read_file
    in
    String.equal left_content right_content
  in
  if String.equal left_value right_value then
    left_value
  else if content_equal left_value right_value then
    let () =
      Log.info
        "Found conflicting source paths `%s` and `%s` but their contents appear to be the same. \
         Picking the former as the source of truth."
        left_value
        right_value
    in
    left_value
  else
    raise (FoundIncompatibleMergeItem { IncompatibleMergeItem.key; left_value; right_value })


module BuckChangedTargetsQueryOutput = struct
  type t = {
    source_base_path: string;
    artifact_base_path: string;
    artifacts_to_sources: (string * string) list;
  }
  [@@deriving sexp, compare]

  let to_partial_build_map { source_base_path; artifact_base_path; artifacts_to_sources } =
    let to_build_mapping (artifact, source) =
      Filename.concat artifact_base_path artifact, Filename.concat source_base_path source
    in
    match BuildMap.Partial.of_alist (List.map artifacts_to_sources ~f:to_build_mapping) with
    | `Duplicate_key artifact ->
        let message = Format.sprintf "Overlapping artifact file detected: %s" artifact in
        Result.Error message
    | `Ok partial_build_map -> Result.Ok partial_build_map


  let to_build_map_batch outputs =
    let rec merge ~sofar = function
      | [] -> Result.Ok (BuildMap.create sofar)
      | output :: rest -> (
          match to_partial_build_map output with
          | Result.Error _ as error -> error
          | Result.Ok next_build_map -> (
              try
                let sofar =
                  BuildMap.Partial.merge
                    sofar
                    next_build_map
                    ~resolve_conflict:resolve_merge_conflict_by_name
                in
                merge ~sofar rest
              with
              | FoundIncompatibleMergeItem { IncompatibleMergeItem.key; _ } ->
                  let message = Format.sprintf "Overlapping artifact file detected: %s" key in
                  Result.Error message))
    in
    merge ~sofar:BuildMap.Partial.empty outputs
end

type t = {
  normalize_targets: string list -> Target.t list Lwt.t;
  (* NOTE(grievejia): This function is intentionally not exposed to downstream clients of the [Buck]
     module, as we are still unsure whether to rely on it or not in the long term. *)
  query_owner_targets:
    targets:Target.t list -> PyrePath.t list -> BuckChangedTargetsQueryOutput.t list Lwt.t;
  construct_build_map: source_root:PyrePath.t -> Target.t list -> BuildResult.t Lwt.t;
}

module V1 = struct
  let source_database_suffix = "#source-db"

  let query_buck_for_normalized_targets
      { BuckOptions.raw; mode; isolation_prefix; use_buck2 = _ }
      target_specifications
    =
    match target_specifications with
    | [] -> Lwt.return "{}"
    | _ ->
        List.concat
          [
            (* Force `buck` to hand back structured JSON output instead of plain text. *)
            ["--json"];
            (* Mark the query as coming from `pyre` for `buck`, to make troubleshooting easier. *)
            ["--config"; "client.id=pyre"];
            [
              (* Build all python-related rules. *)
              "kind(\"python_binary|python_library|python_test\", %s)"
              (* Certain Python-related rules are exposed as `configured_alias` which cannot be
                 picked up by the preceding query. *)
              ^ " + kind(\"python_binary|python_test\", deps(kind(configured_alias, %s), 1))"
              (* Don't bother with generated rules. *)
              ^ " - attrfilter(labels, generated, %s)"
              (* `python_unittest()` sources are separated into a macro-generated library, so make
                 sure we include those. *)
              ^ " + attrfilter(labels, unittest-library, %s)"
              ^ (* Provide an opt-out label so that rules can avoid type-checking (e.g. some
                   libraries wrap generated sources which are expensive to build and therefore
                   typecheck). *)
              " - attrfilter(labels, no_pyre, %s)";
            ];
            target_specifications;
          ]
        |> Raw.query ?mode ?isolation_prefix raw


  let query_buck_for_changed_targets
      ~targets
      { BuckOptions.raw; mode; isolation_prefix; use_buck2 = _ }
      source_paths
    =
    match targets with
    | [] -> Lwt.return "{}"
    | targets -> (
        match source_paths with
        | [] -> Lwt.return "{}"
        | source_paths ->
            let target_string =
              (* Targets need to be quoted since `buck query` can fail with syntax errors if target
                 name contains special characters like `=`. *)
              let quote_string value = Format.sprintf "\"%s\"" value in
              let quote_target target = Target.show target |> quote_string in
              List.map targets ~f:quote_target |> String.concat ~sep:" "
            in
            List.concat
              [
                ["--json"];
                ["--config"; "client.id=pyre"];
                [
                  (* This will get only those owner targets that are beneath our targets or the
                     dependencies of our targets. *)
                  Format.sprintf "owner(%%s) ^ deps(set(%s))" target_string;
                ];
                List.map source_paths ~f:PyrePath.show;
                (* These attributes are all we need to locate the source and artifact relative
                   paths. *)
                ["--output-attributes"; "srcs"; "buck.base_path"; "buck.base_module"; "base_module"];
              ]
            |> Raw.query ?mode ?isolation_prefix raw)


  let run_buck_build_for_targets { BuckOptions.raw; mode; isolation_prefix; use_buck2 = _ } targets =
    match targets with
    | [] -> Lwt.return "{}"
    | _ ->
        List.concat
          [
            (* Force `buck` to hand back structured JSON output instead of plain text. *)
            ["--show-full-json-output"];
            (* Mark the query as coming from `pyre` for `buck`, to make troubleshooting easier. *)
            ["--config"; "client.id=pyre"];
            List.map targets ~f:(fun target ->
                Format.sprintf "%s%s" (Target.show target) source_database_suffix);
          ]
        |> Raw.build ?mode ?isolation_prefix raw
end

module V2 = struct
  let source_database_suffix = "[source-db]"

  let query_buck_for_normalized_targets
      { BuckOptions.raw; mode; isolation_prefix; use_buck2 = _ }
      target_specifications
    =
    match target_specifications with
    | [] -> Lwt.return "{}"
    | _ ->
        List.concat
          [
            (* Force `buck` to hand back structured JSON output instead of plain text. *)
            ["--json"];
            (* Force `buck` to opt-out fancy tui logging. *)
            ["--console=simple"];
            (* Mark the query as coming from `pyre` for `buck`, to make troubleshooting easier. *)
            ["--config"; "client.id=pyre"];
            [
              "kind(\"python_binary|python_library|python_test\", %s)"
              (* Don't bother with generated rules. *)
              ^ " - attrfilter(labels, generated, %s)"
              (* `python_unittest()` sources are separated into a macro-generated library, so make
                 sure we include those. *)
              ^ " + attrfilter(labels, unittest-library, %s)"
              ^ (* Provide an opt-out label so that rules can avoid type-checking (e.g. some
                   libraries wrap generated sources which are expensive to build and therefore
                   typecheck). *)
              " - attrfilter(labels, no_pyre, %s)";
            ];
            target_specifications;
          ]
        |> Raw.query ?mode ?isolation_prefix raw


  let query_buck_for_changed_targets ~targets:_ _ _ =
    failwith "Changed targets query is currently not implemented for Buck2"


  let run_buck_build_for_targets { BuckOptions.raw; mode; isolation_prefix; use_buck2 = _ } targets =
    match targets with
    | [] -> Lwt.return "{}"
    | _ ->
        List.concat
          [
            (* Force `buck` to opt-out fancy tui logging. *)
            ["--console=simple"];
            (* Force `buck` to hand back structured JSON output that contains absolute paths. *)
            ["--show-full-json-output"];
            (* Mark the query as coming from `pyre` for `buck`, to make troubleshooting easier. *)
            ["--config"; "client.id=pyre"];
            List.map targets ~f:(fun target ->
                Format.sprintf "%s%s" (Target.show target) source_database_suffix);
          ]
        |> Raw.build ?mode ?isolation_prefix raw


  let build_map_key = "build_map"

  let built_targets_count_key = "built_targets_count"

  let dropped_targets_key = "dropped_targets"

  module BuckBxlBuilderOutput = struct
    module Conflict = struct
      type t = {
        conflict_with: string;
        artifact_path: string;
        preserved_source_path: string;
        dropped_source_path: string;
      }
      [@@deriving sexp, compare, of_yojson { strict = false }]
    end

    type t = {
      build_map: BuildMap.t;
      target_count: int;
      conflicts: (Target.t * Conflict.t) list;
    }
  end

  let parse_merged_sourcedb merged_sourcedb : BuckBxlBuilderOutput.t =
    let open Yojson.Safe in
    try
      let build_map =
        Util.member build_map_key merged_sourcedb
        |> BuildMap.Partial.of_json_exn_ignoring_duplicates_no_dependency
        |> BuildMap.create
      in
      let target_count = Util.member built_targets_count_key merged_sourcedb |> Util.to_int in
      let conflicts =
        let conflict_of_yojson json =
          match BuckBxlBuilderOutput.Conflict.of_yojson json with
          | Result.Ok conflict -> conflict
          | Result.Error message ->
              let message = Format.sprintf "Cannot parse conflict item: %s" message in
              raise (JsonError message)
        in
        Util.member dropped_targets_key merged_sourcedb
        |> Util.to_assoc
        |> List.map ~f:(fun (target, conflict_json) ->
               Target.of_string target, conflict_of_yojson conflict_json)
      in
      { BuckBxlBuilderOutput.build_map; target_count; conflicts }
    with
    | Yojson.Json_error message
    | Util.Type_error (message, _) ->
        raise (JsonError message)


  let parse_bxl_output bxl_output =
    let open Yojson.Safe in
    try
      let merged_sourcedb_path =
        from_string ~fname:"buck bxl output" bxl_output |> Util.member "db" |> Util.to_string
      in
      from_file merged_sourcedb_path |> parse_merged_sourcedb
    with
    | Yojson.Json_error message
    | Util.Type_error (message, _)
    | Sys_error message ->
        raise (JsonError message)
end

let get_source_database_suffix { BuckOptions.use_buck2; _ } =
  if use_buck2 then
    V2.source_database_suffix
  else
    V1.source_database_suffix


let query_buck_for_normalized_targets
    ({ BuckOptions.use_buck2; _ } as buck_options)
    target_specifications
  =
  if use_buck2 then
    V2.query_buck_for_normalized_targets buck_options target_specifications
  else
    V1.query_buck_for_normalized_targets buck_options target_specifications


let query_buck_for_changed_targets
    ~targets
    ({ BuckOptions.use_buck2; _ } as buck_options)
    source_paths
  =
  if use_buck2 then
    V2.query_buck_for_changed_targets ~targets buck_options source_paths
  else
    V1.query_buck_for_changed_targets ~targets buck_options source_paths


let run_buck_build_for_targets ({ BuckOptions.use_buck2; _ } as buck_options) targets =
  if use_buck2 then
    V2.run_buck_build_for_targets buck_options targets
  else
    V1.run_buck_build_for_targets buck_options targets


let parse_buck_normalized_targets_query_output query_output =
  let open Yojson.Safe in
  try
    from_string ~fname:"buck query output" query_output
    |> Util.to_assoc
    |> List.map ~f:(fun (_, targets_json) ->
           Util.to_list targets_json |> List.map ~f:Util.to_string)
    |> List.concat_no_order
    |> List.dedup_and_sort ~compare:String.compare
  with
  | Yojson.Json_error message
  | Util.Type_error (message, _) ->
      raise (JsonError message)


let parse_buck_changed_targets_query_output query_output =
  let open Yojson.Safe in
  try
    let parse_target_json target_json =
      let source_base_path = Util.member "buck.base_path" target_json |> Util.to_string in
      let artifact_base_path =
        match Util.member "buck.base_module" target_json with
        | `String base_module -> String.tr ~target:'.' ~replacement:'/' base_module
        | _ -> source_base_path
      in
      let artifact_base_path =
        match Util.member "base_module" target_json with
        | `String base_module -> String.tr ~target:'.' ~replacement:'/' base_module
        | _ -> artifact_base_path
      in
      let artifacts_to_sources =
        match Util.member "srcs" target_json with
        | `Assoc targets_to_sources ->
            List.map targets_to_sources ~f:(fun (target, source_json) ->
                target, Util.to_string source_json)
            |> List.filter ~f:(function
                   | _, source when String.is_prefix ~prefix:"//" source ->
                       (* This can happen for custom rules. *)
                       false
                   | _ -> true)
        | _ -> []
      in
      { BuckChangedTargetsQueryOutput.source_base_path; artifact_base_path; artifacts_to_sources }
    in
    from_string ~fname:"buck changed paths query output" query_output
    |> Util.to_assoc
    |> List.map ~f:(fun (_, target_json) -> parse_target_json target_json)
  with
  | Yojson.Json_error message
  | Util.Type_error (message, _) ->
      raise (JsonError message)


let parse_buck_build_output query_output =
  let open Yojson.Safe in
  try
    from_string ~fname:"buck build output" query_output
    |> Util.to_assoc
    |> List.map ~f:(fun (target, path_json) -> target, Util.to_string path_json)
  with
  | Yojson.Json_error message
  | Util.Type_error (message, _) ->
      raise (JsonError message)


let load_partial_build_map_from_json json =
  let filter_mapping ~key ~data:_ =
    match key with
    | "__manifest__.py"
    | "__test_main__.py"
    | "__test_modules__.py" ->
        (* These files are not useful for type checking but create many conflicts when merging
           different targets. *)
        false
    | _ -> true
  in
  BuildMap.Partial.of_json_exn_ignoring_duplicates json |> BuildMap.Partial.filter ~f:filter_mapping


let load_partial_build_map path =
  let open Lwt.Infix in
  let path = PyrePath.absolute path in
  Lwt_io.(with_file ~mode:Input path read)
  >>= fun content ->
  try
    Yojson.Safe.from_string ~fname:path content |> load_partial_build_map_from_json |> Lwt.return
  with
  | Yojson.Safe.Util.Type_error (message, _)
  | Yojson.Safe.Util.Undefined (message, _) ->
      raise (JsonError message)
  | Yojson.Json_error message -> raise (JsonError message)


let normalize_targets_with_options buck_options target_specifications =
  let open Lwt.Infix in
  Log.info "Collecting buck targets to build...";
  query_buck_for_normalized_targets buck_options target_specifications
  >>= fun query_output ->
  let targets =
    parse_buck_normalized_targets_query_output query_output |> List.map ~f:Target.of_string
  in
  Log.info "Collected %d targets" (List.length targets);
  Lwt.return targets


let query_owner_targets_with_options buck_options ~targets changed_paths =
  let open Lwt.Infix in
  Log.info "Running `buck query`...";
  query_buck_for_changed_targets ~targets buck_options changed_paths
  >>= fun query_output -> Lwt.return (parse_buck_changed_targets_query_output query_output)


(* Run `buck build` on the given target with the `#source-db` flavor. This will make `buck`
   construct its link tree and for each target, dump a source-db JSON file containing how files in
   the link tree corresponds to the final Python artifacts. Return a list containing the input
   targets as well as the corresponding location of the source-db JSON file. Note that targets in
   the returned list is not guaranteed to be in the same order as the input list.

   May raise [Buck.Raw.BuckError] when `buck` invocation fails, or [Buck.Builder.JsonError] when
   `buck` itself succeeds but its output cannot be parsed. *)
let build_source_databases buck_options targets =
  let open Lwt.Infix in
  Log.info "Building Buck source databases...";
  run_buck_build_for_targets buck_options targets
  >>= fun build_output ->
  let source_database_suffix_length = get_source_database_suffix buck_options |> String.length in
  parse_buck_build_output build_output
  |> List.map ~f:(fun (target, path) ->
         ( String.drop_suffix target source_database_suffix_length |> Target.of_string,
           PyrePath.create_absolute path ))
  |> Lwt.return


let merge_target_and_build_map
    ~resolve_conflict
    (target_and_build_maps_sofar, build_map_sofar)
    (next_target, next_build_map)
  =
  let open BuildMap.Partial in
  try
    let merged_build_map = merge build_map_sofar next_build_map ~resolve_conflict in
    (next_target, next_build_map) :: target_and_build_maps_sofar, merged_build_map
  with
  | FoundIncompatibleMergeItem { IncompatibleMergeItem.key; left_value; right_value } ->
      Log.warning "Cannot include target for type checking: %s" (Target.show next_target);
      (* For better error message, try to figure out which target casued the conflict. *)
      let conflicting_target =
        let match_target ~key (target, build_map) =
          if contains ~key build_map then Some target else None
        in
        List.find_map target_and_build_maps_sofar ~f:(match_target ~key)
      in
      Log.info
        "... file `%s` has already been mapped to `%s`%s but the target maps it to `%s` instead. "
        key
        left_value
        (Option.value_map conflicting_target ~default:"" ~f:(Format.sprintf " by `%s`"))
        right_value;
      target_and_build_maps_sofar, build_map_sofar


let load_and_merge_build_maps ~resolve_conflict target_and_source_database_paths =
  let open Lwt.Infix in
  let number_of_targets_to_load = List.length target_and_source_database_paths in
  Log.info "Loading source databases for %d targets..." number_of_targets_to_load;
  let rec fold ~sofar = function
    | [] -> Lwt.return sofar
    | (next_target, next_build_map_path) :: rest ->
        load_partial_build_map next_build_map_path
        >>= fun next_build_map ->
        let sofar =
          merge_target_and_build_map sofar (next_target, next_build_map) ~resolve_conflict
        in
        fold ~sofar rest
  in
  fold target_and_source_database_paths ~sofar:([], BuildMap.Partial.empty)
  >>= fun (reversed_target_and_build_maps, merged_build_map) ->
  let targets = List.rev_map reversed_target_and_build_maps ~f:fst in
  if List.length targets < number_of_targets_to_load then
    Log.warning
      "One or more targets get dropped by Pyre due to potential conflicts. For more details, see \
       https://fburl.com/pyre-target-conflict";
  Lwt.return { BuildResult.targets; build_map = BuildMap.create merged_build_map }


(* Unlike [load_and_merge_build_maps], this function assumes build maps are already loaded into
   memory and just try to merge them synchronously. Its main purpose is to facilitate testing of the
   [merge_target_and_build_map] function. *)
let merge_build_maps ~resolve_conflict target_and_build_maps =
  let reversed_target_and_build_maps, merged_build_map =
    List.fold
      target_and_build_maps
      ~init:([], BuildMap.Partial.empty)
      ~f:(merge_target_and_build_map ~resolve_conflict)
  in
  let targets = List.rev_map reversed_target_and_build_maps ~f:fst in
  targets, BuildMap.create merged_build_map


let load_and_merge_source_databases ~source_root target_and_source_database_paths =
  (* Make sure the targets are in a determinstic order. This is important to make the merging
     process deterministic later. Note that our dependency on the ordering of the target also
     implies that the loading process is non-parallelizable. *)
  List.sort target_and_source_database_paths ~compare:(fun (left_target, _) (right_target, _) ->
      Target.compare left_target right_target)
  |> load_and_merge_build_maps
       ~resolve_conflict:(resolve_merge_conflict_by_name_and_content ~source_root)


let construct_build_map_with_options buck_options ~source_root normalized_targets =
  let open Lwt.Infix in
  build_source_databases buck_options normalized_targets
  >>= fun target_and_source_database_paths ->
  load_and_merge_source_databases ~source_root target_and_source_database_paths


let do_create ?mode ?isolation_prefix ~use_buck2 raw =
  let buck_options = { BuckOptions.mode; isolation_prefix; raw; use_buck2 } in
  {
    normalize_targets = normalize_targets_with_options buck_options;
    query_owner_targets = query_owner_targets_with_options buck_options;
    construct_build_map = construct_build_map_with_options buck_options;
  }


let create ?mode ?isolation_prefix raw = do_create ?mode ?isolation_prefix ~use_buck2:false raw

let create_v2 ?mode ?isolation_prefix ?bxl_builder:_ raw =
  do_create ?mode ?isolation_prefix ~use_buck2:true raw


let create_for_testing ~normalize_targets ~construct_build_map () =
  let query_owner_targets ~targets:_ _ =
    failwith "`query_owner_targets` invoked but not implemented"
  in
  { normalize_targets; construct_build_map; query_owner_targets }


let normalize_targets { normalize_targets; _ } target_specifications =
  normalize_targets target_specifications


let query_owner_targets { query_owner_targets; _ } ~targets paths =
  query_owner_targets ~targets paths


let construct_build_map { construct_build_map; _ } ~source_root normalized_targets =
  construct_build_map ~source_root normalized_targets
