(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* ModuleTracker: layer of the environment stack
 * - upstream: None, this is the lowest-level environment
 * - downstream: AstEnvironment
 *
 * It is responsible for:
 * - understanding the mapping between module names (which we call `qualifiers`)
 *   and actual files, including the precedence of directories and of stubs.
 * - actually loading code (the AstEnvironment calls down to ModuleTracker)
 * - specifically in the Overlay case, knowing about in-memory code that should
 *   take precedence over filesystem code to handle unsaved changes.
 *
 * Most of the complexity involves understanding the mapping between module
 * names and files, both initially and in incremental updates. This is handled
 * by the Layouts submodule, which independently tracks two notions of modules:
 * - explicit modules, which actually have a python file
 * - implicit modules, corresponding to directories that contain python files
 *   but that lack an `__init__.py`
 *
 * In order to support different performance tradeoffs, there are two different
 * implementations of the Layouts interface:
 * - An eager tracker that crawls the filesystem at initialization
 * - A lazy tracker that only reads directories when looking up a specific
 *   module name; this skips the filesystem crawl but is more complex, and to
 *   be performant it also requires maintaining a directory read cache.
 *
 * Importantly, the lazy tracker disables operations that require listing all
 * modules (becasue that requires the directory crawl). As a result, many
 * higher-level queries such as getting all type errors or the full class
 * hierarchy may not be performed in an environment that uses lazy tracking.
 *)

open Core
open Ast
open Pyre

(* ModuleTracker.t is the underlying raw filesystem access and storage logic
 * that supports all module-finding in Pyre, including both O(request)
 * operations such as finding a module path and O(project) operations such
 * as listing modules.
 *
 * But ModuleTracker.ReadOnly.t only exposes the non-global O(request)
 * operations. Any code needing module listing must instead use a
 * GlobalModulePathsApi.t constructed directly from the read-write module
 * tracker.
 *
 * We do this to provide more type-safety, guaranteeing that Pyre's core
 * analysis (which is built out of read-only environments) never relies
 * on O(project) operations, which in turn is what makes a lazy IDE
 * that scales well to massive source trees possible.
 *)
module ReadOnly = struct
  type t = {
    look_up_qualifier: Reference.t -> SourceCodeApi.ModuleLookup.t;
    code_of_module_path: ModulePath.t -> Parsing.LoadResult.t;
    controls: unit -> EnvironmentControls.t;
  }

  let controls { controls; _ } = controls ()

  let look_up_qualifier { look_up_qualifier; _ } = look_up_qualifier

  let code_of_module_path { code_of_module_path; _ } = code_of_module_path
end

module Overlay = struct
  type t = {
    parent: ReadOnly.t;
    overlaid_code: string Hashtbl.M(ModulePath).t;
    overlaid_qualifiers: Reference.Hash_set.t;
  }

  let owns_qualifier { overlaid_qualifiers; _ } qualifier =
    Hash_set.mem overlaid_qualifiers qualifier


  let from_read_only parent =
    {
      parent;
      overlaid_code = Hashtbl.create (module ModulePath);
      overlaid_qualifiers = Reference.Hash_set.create ();
    }


  let update_overlaid_code { parent; overlaid_code; overlaid_qualifiers; _ } ~code_updates =
    let add_or_update_code ~code_update module_path =
      let qualifier = ModulePath.qualifier module_path in
      let () =
        match code_update with
        | SourceCodeIncrementalApi.Overlay.CodeUpdate.NewCode new_code ->
            Hashtbl.set overlaid_code ~key:module_path ~data:new_code
        | SourceCodeIncrementalApi.Overlay.CodeUpdate.ResetCode ->
            Hashtbl.remove overlaid_code module_path
      in
      let () = Hash_set.add overlaid_qualifiers qualifier in
      SourceCodeIncrementalApi.UpdateResult.ModuleUpdate.NewExplicit module_path
    in
    let process_code_update (artifact_path, code_update) =
      let configuration = ReadOnly.controls parent |> EnvironmentControls.configuration in
      ArtifactPaths.module_path_of_artifact_path ~configuration artifact_path
      >>| add_or_update_code ~code_update
    in
    List.filter_map code_updates ~f:process_code_update


  let read_only { parent; overlaid_code; _ } =
    let code_of_module_path module_path =
      match Hashtbl.find overlaid_code module_path with
      | Some code -> Result.Ok code
      | _ -> ReadOnly.code_of_module_path parent module_path
    in
    { parent with code_of_module_path }
end

module RawModulePathSet = Stdlib.Set.Make (ModulePath.Raw)

(* NOTE: This comparator is expected to operate on module paths that share the same qualifier and
   should_type_check flag. Do NOT use it on aribitrary module paths. *)
(* TODO: Find a way to avoid having this function to start with, possibly by cachings raw module
   paths instead of module paths. *)
let same_module_compare
    ~configuration
    { ModulePath.raw = left_raw; _ }
    { ModulePath.raw = right_raw; _ }
  =
  ModulePath.Raw.priority_aware_compare ~configuration left_raw right_raw


module ModulePaths = struct
  module Finder = struct
    type t = {
      valid_suffixes: String.Set.t;
      excludes: Str.regexp list;
    }

    let create ({ Configuration.Analysis.excludes; _ } as configuration) =
      {
        valid_suffixes =
          ".py" :: ".pyi" :: Configuration.Analysis.extension_suffixes configuration
          |> String.Set.of_list;
        excludes;
      }


    let is_valid_filename_raw { valid_suffixes; _ } raw_path =
      let extension =
        Filename.split_extension raw_path
        |> snd
        >>| (fun extension -> "." ^ extension)
        |> Option.value ~default:""
      in
      (* Don't bother with hidden files as they are non-importable in Python by default *)
      (not (String.is_prefix (Filename.basename raw_path) ~prefix:"."))
      (* Only consider files with valid suffix *)
      && Set.mem valid_suffixes extension


    let is_valid_filename finder artifact_path =
      ArtifactPath.raw artifact_path |> PyrePath.absolute |> is_valid_filename_raw finder


    let mark_visited visited_paths path =
      match Hash_set.strict_add visited_paths path with
      | Result.Ok () -> false
      | _ -> true


    let python_file_filter finder ~visited_paths path =
      is_valid_filename_raw finder path && not (mark_visited visited_paths path)


    let package_directory_filter { excludes; _ } ~visited_paths ~root_path path =
      (* Don't bother with hidden directories (except in the case where the root itself is hidden)
         as they are non-importable in Python by default *)
      ((not (String.is_prefix (Filename.basename path) ~prefix:".")) || String.equal path root_path)
      (* Do not scan excluding directories to speed up the traversal *)
      && (not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0)))
      && not (mark_visited visited_paths path)


    let find_all ({ Configuration.Analysis.source_paths; search_paths; _ } as configuration) =
      let finder = create configuration in
      let visited_paths = String.Hash_set.create () in
      let search_roots =
        List.append
          (List.map ~f:SearchPath.to_path source_paths)
          (List.map ~f:SearchPath.to_path search_paths)
      in
      List.map search_roots ~f:(fun root ->
          let root_path = PyrePath.absolute root in
          let directory_filter = package_directory_filter finder ~visited_paths ~root_path in
          let file_filter = python_file_filter finder ~visited_paths in
          PyrePath.list ~file_filter ~directory_filter ~root () |> List.map ~f:ArtifactPath.create)
      |> List.concat
      |> List.filter_map ~f:(ArtifactPaths.module_path_of_artifact_path ~configuration)
  end

  module LazyFinder = struct
    let directory_paths ~configuration qualifier =
      let relative =
        match Reference.as_list qualifier with
        | [] -> ""
        | parts -> Filename.of_parts parts
      in
      let find_in_root search_path =
        let root = SearchPath.get_root search_path in
        let candidate_path = PyrePath.create_relative ~root ~relative in
        if PyrePath.directory_exists candidate_path then
          Some candidate_path
        else
          None
      in
      Configuration.Analysis.search_paths configuration |> List.filter_map ~f:find_in_root


    module Cache =
      Hack_parallel.Std.SharedMemory.FirstClass.WithCache.Make
        (SharedMemoryKeys.ReferenceKey)
        (struct
          type t = ModulePath.t list Reference.Map.Tree.t

          let prefix = Hack_parallel.Std.Prefix.make ()

          let description = "CachedDirectoryRead"
        end)

    type t = {
      cache: Cache.t;
      configuration: Configuration.Analysis.t;
    }

    let create configuration = { cache = Cache.create (); configuration }

    let find_module_paths_inside_directories_all_search_paths_no_cache ~configuration qualifier =
      let finder = Finder.create configuration in
      let list_directory path =
        (* Technically this operation is subject to race conditions, so be careful here *)
        try
          PyrePath.read_directory_ordered path
          |> List.map ~f:ArtifactPath.create
          |> List.filter ~f:(Finder.is_valid_filename finder)
        with
        | Sys_error _ -> []
      in
      let module_paths =
        directory_paths ~configuration qualifier
        |> List.concat_map ~f:list_directory
        |> List.filter_map ~f:(ArtifactPaths.module_path_of_artifact_path ~configuration)
      in
      let sort_by_qualifier so_far module_path =
        Reference.Map.Tree.update so_far (ModulePath.qualifier module_path) ~f:(function
            | None -> [module_path]
            | Some module_paths -> module_path :: module_paths)
      in
      List.fold module_paths ~init:Reference.Map.Tree.empty ~f:sort_by_qualifier


    (* Given a qualifier, find all ModulePath.t values corresponding to directories whose relative
       path match that qualfiier (across all search roots). *)
    let find_module_paths_inside_directories_all_search_paths { cache; configuration } qualifier =
      match Cache.get cache qualifier with
      | Some value -> value
      | None ->
          let value =
            find_module_paths_inside_directories_all_search_paths_no_cache ~configuration qualifier
          in
          let () = Cache.add cache qualifier value in
          value


    let invalidate { cache; _ } qualifier =
      Reference.this_and_all_parents qualifier |> Cache.KeySet.of_list |> Cache.remove_batch cache


    (* Given a qualifier, find all ModulePath.t values for that qualifier (across all search roots).
       Note: we try all possible parent directories to support python files with multiple dots in
       them. *)
    let find_module_paths ~lazy_finder:({ configuration; _ } as lazy_finder) qualifier =
      let files =
        Reference.this_and_all_parents qualifier
        |> List.map ~f:(fun parent_qualifier ->
               find_module_paths_inside_directories_all_search_paths lazy_finder parent_qualifier
               |> (fun map -> Reference.Map.Tree.find map qualifier)
               |> Option.value ~default:[])
        |> Stdlib.List.flatten
      in
      List.sort files ~compare:(same_module_compare ~configuration)


    let find_submodule_paths ~lazy_finder qualifier =
      find_module_paths_inside_directories_all_search_paths lazy_finder qualifier
      |> Reference.Map.Tree.data
      |> List.concat
      |> List.map ~f:ModulePath.raw
      |> RawModulePathSet.of_list
  end

  module Update = struct
    type t =
      | NewOrChanged of ModulePath.t
      | Remove of ModulePath.t

    let create ~configuration { ArtifactPath.Event.kind; path } =
      match ArtifactPaths.module_path_of_artifact_path ~configuration path with
      | None ->
          Log.log ~section:`Server "`%a` not found in search path." ArtifactPath.pp path;
          None
      | Some module_path ->
          let result =
            match kind with
            | ArtifactPath.Event.Kind.CreatedOrChanged -> NewOrChanged module_path
            | ArtifactPath.Event.Kind.Deleted -> Remove module_path
            | ArtifactPath.Event.Kind.Unknown ->
                if PyrePath.file_exists (ArtifactPath.raw path) then
                  NewOrChanged module_path
                else
                  Remove module_path
          in
          Some result


    let module_path = function
      | NewOrChanged module_path
      | Remove module_path ->
          module_path


    let from_artifact_events ~configuration events =
      (* Since the logic in `process_module_path_update` is not idempotent, we don't want any
         duplicate ArtifactPaths in our module_path updates *)
      List.dedup_and_sort ~compare:ArtifactPath.Event.compare events
      |> List.filter ~f:(fun { ArtifactPath.Event.path; _ } ->
             Finder.is_valid_filename (Finder.create configuration) path)
      |> List.filter_map ~f:(create ~configuration)
  end
end

module LazyTracking = struct
  module Table = struct
    module type LazyValue = sig
      type t [@@deriving compare]

      val empty : t

      val description : string

      val produce : lazy_finder:ModulePaths.LazyFinder.t -> Reference.t -> t
    end

    module Make (Value : LazyValue) = struct
      module SharedMemory =
        Memory.FirstClass.WithCache.Make
          (SharedMemoryKeys.ReferenceKey)
          (struct
            type t = Value.t [@@deriving compare]

            let prefix = Hack_parallel.Std.Prefix.make ()

            let description = Value.description
          end)

      type t = {
        shared_memory: SharedMemory.t;
        lazy_finder: ModulePaths.LazyFinder.t;
      }

      let create ~lazy_finder = { shared_memory = SharedMemory.create (); lazy_finder }

      let set { shared_memory; _ } qualifier value =
        SharedMemory.remove_batch shared_memory (SharedMemory.KeySet.of_list [qualifier]);
        SharedMemory.add shared_memory qualifier value;
        ()


      let remove table qualifier = set table qualifier Value.empty

      let key_exists { shared_memory; _ } qualifier = SharedMemory.mem shared_memory qualifier

      let find ({ shared_memory; lazy_finder } as table) qualifier =
        match SharedMemory.get shared_memory qualifier with
        | Some value -> Some value
        | None ->
            let value = Value.produce ~lazy_finder qualifier in
            let () = set table qualifier value in
            Some value
    end
  end
end

module ExplicitModules = struct
  module Value = struct
    (* A list of paths that map to the same qualifier, ordered by priority. *)
    type t = ModulePath.t list [@@deriving compare]

    let empty = []

    let description = "ExplicitModules"

    let module_path = function
      | module_path :: _ -> Some module_path
      | [] -> None


    let fail_on_module_path_invariant ~description ~left ~right =
      let failure_message =
        Format.asprintf
          "Invariant violation (%s): left = %s, right = %s"
          description
          (ModulePath.sexp_of_t left |> Sexp.to_string)
          (ModulePath.sexp_of_t right |> Sexp.to_string)
      in
      failwith failure_message


    let insert_module_path ~configuration ~to_insert existing_paths =
      let rec insert sofar = function
        | [] -> List.rev_append sofar [to_insert]
        | current_path :: rest as existing -> (
            match same_module_compare ~configuration to_insert current_path with
            | 0 ->
                (* We have the following precondition for files that are in the same module: *)
                (* `same_module_compare a b = 0` implies `equal a b` *)
                if not (ModulePath.equal to_insert current_path) then
                  fail_on_module_path_invariant
                    ~description:"Module paths that compare with 0 should be equal when inserting"
                    ~left:to_insert
                    ~right:current_path;
                (* Duplicate entry detected. Do nothing *)
                existing_paths
            | x when x < 0 -> List.rev_append sofar (to_insert :: existing)
            | _ -> insert (current_path :: sofar) rest)
      in
      insert [] existing_paths


    let remove_module_path ~configuration ~to_remove existing_paths =
      let equal_raw_paths { ModulePath.raw = left; _ } { ModulePath.raw = right; _ } =
        ModulePath.Raw.equal left right
      in
      let rec remove sofar = function
        | [] -> existing_paths
        | current_path :: rest -> (
            match same_module_compare ~configuration to_remove current_path with
            | 0 ->
                let () =
                  (* For removed files, we only check for equality on relative path & priority. *)
                  (* There's a corner case (where an in-project file's symlink gas been removed)
                     that may cause `removed` to have a different `should_type_check` flag, since we
                     cannot follow a deleted symlink. *)
                  if not (equal_raw_paths to_remove current_path) then
                    fail_on_module_path_invariant
                      ~description:
                        "Module paths that compare with 0 should have same raw path when removing"
                      ~left:to_remove
                      ~right:current_path
                in
                List.rev_append sofar rest
            | x when x < 0 -> existing_paths
            | _ -> remove (current_path :: sofar) rest)
      in
      remove [] existing_paths
  end

  module Update = struct
    type t =
      | New of ModulePath.t
      | Changed of ModulePath.t
      | Delete of Reference.t
    [@@deriving sexp, compare]

    let merge_updates updates =
      let table = Reference.Table.create () in
      let process_update update =
        match update with
        | New ({ ModulePath.qualifier; _ } as module_path) ->
            let update = function
              | None -> update
              | Some (Delete _) -> Changed module_path
              | Some (New _) ->
                  let message =
                    Format.asprintf "Illegal state: double new module %a" Reference.pp qualifier
                  in
                  failwith message
              | Some (Changed _) ->
                  let message =
                    Format.asprintf
                      "Illegal state: new after changed module %a"
                      Reference.pp
                      qualifier
                  in
                  failwith message
            in
            Hashtbl.update table qualifier ~f:update
        | Changed ({ ModulePath.qualifier; _ } as module_path) ->
            let update = function
              | None
              | Some (Changed _) ->
                  update
              | Some (New _) -> New module_path
              | Some (Delete _) ->
                  let message =
                    Format.asprintf
                      "Illegal state: changing a deleted module %a"
                      Reference.pp
                      qualifier
                  in
                  failwith message
            in
            Hashtbl.update table qualifier ~f:update
        | Delete qualifier ->
            let update = function
              | None
              | Some (Changed _) ->
                  Some update
              | Some (New _) ->
                  let message =
                    Format.asprintf
                      "Illegal state: delete after new module %a"
                      Reference.pp
                      qualifier
                  in
                  failwith message
              | Some (Delete _) ->
                  let message =
                    Format.asprintf "Illegal state: double delete module %a" Reference.pp qualifier
                  in
                  failwith message
            in
            Hashtbl.change table qualifier ~f:update
      in
      List.iter updates ~f:process_update;
      Hashtbl.data table
  end

  module Table = struct
    module Api = struct
      type t = {
        should_skip_update: Reference.t -> bool;
        find: Reference.t -> Value.t option;
        set: Reference.t -> Value.t -> unit;
        remove: Reference.t -> unit;
        data: unit -> Value.t list;
      }

      let update_module_paths
          ~configuration
          ~module_path_updates
          { find; set; remove; should_skip_update; _ }
        =
        (* Process a single module_path update *)
        let process_module_path_update ~configuration module_path_update =
          let ({ ModulePath.qualifier; _ } as module_path) =
            ModulePaths.Update.module_path module_path_update
          in
          if should_skip_update qualifier then
            None
          else
            match module_path_update with
            | ModulePaths.Update.NewOrChanged _ -> (
                match find qualifier with
                | None ->
                    (* New file for a new module *)
                    set qualifier [module_path];
                    Some (Update.New module_path)
                | Some module_paths ->
                    let new_module_paths =
                      Value.insert_module_path ~configuration ~to_insert:module_path module_paths
                    in
                    let new_module_path = List.hd_exn new_module_paths in
                    set qualifier new_module_paths;
                    if ModulePath.equal new_module_path module_path then
                      (* Updating a shadowing file means the module gets changed *)
                      Some (Update.Changed module_path)
                    else (* Updating a shadowed file should not trigger any reanalysis *)
                      None)
            | ModulePaths.Update.Remove _ -> (
                find qualifier
                >>= fun module_paths ->
                match module_paths with
                | [] ->
                    (* This should never happen but handle it just in case *)
                    remove qualifier;
                    None
                | old_module_path :: _ -> (
                    match
                      Value.remove_module_path ~configuration ~to_remove:module_path module_paths
                    with
                    | [] ->
                        (* Last remaining file for the module gets removed. *)
                        remove qualifier;
                        Some (Update.Delete qualifier)
                    | new_module_path :: _ as new_module_paths ->
                        set qualifier new_module_paths;
                        if ModulePath.equal old_module_path new_module_path then
                          (* Removing a shadowed file should not trigger any reanalysis *)
                          None
                        else (* Removing module_path un-shadows another source file. *)
                          Some (Update.Changed new_module_path)))
        in
        (* Make sure we have only one update per module *)
        List.filter_map module_path_updates ~f:(process_module_path_update ~configuration)
        |> Update.merge_updates
    end

    module Eager = struct
      type t = Value.t Reference.Table.t

      let create ~configuration module_paths =
        let explicit_modules = Reference.Table.create () in
        let process_module_path ({ ModulePath.qualifier; _ } as module_path) =
          let update_table = function
            | None -> [module_path]
            | Some module_paths ->
                Value.insert_module_path ~configuration ~to_insert:module_path module_paths
          in
          Hashtbl.update explicit_modules qualifier ~f:update_table
        in
        List.iter module_paths ~f:process_module_path;
        explicit_modules


      let to_api eager =
        let should_skip_update _ = false in
        let find qualifier = Hashtbl.find eager qualifier in
        let set qualifier value = Hashtbl.set eager ~key:qualifier ~data:value in
        let remove qualifier = Hashtbl.remove eager qualifier in
        let data () = Hashtbl.data eager in
        Api.{ should_skip_update; find; set; remove; data }
    end

    module Lazy = struct
      include LazyTracking.Table.Make (struct
        include Value

        let produce = ModulePaths.LazyFinder.find_module_paths
      end)

      let to_api table =
        let should_skip_update qualifier = not (key_exists table qualifier) in
        Api.
          {
            should_skip_update;
            find = find table;
            set = set table;
            remove = remove table;
            data =
              (fun () ->
                failwith
                  "Lazy module trackers cannot support APIs that require listing all qualifiers");
          }
    end
  end
end

module ImplicitModules = struct
  (* Given a ModulePath.t, determine the qualifier of the parent (the key in our
     ImplicitModules.Table) and the ModulePath.Raw.t representing this child *)
  let parent_qualifier_and_raw { ModulePath.raw; qualifier; _ } =
    Reference.prefix qualifier >>| fun parent_qualifier -> parent_qualifier, raw


  module Value = struct
    (* This represents the raw paths of all *explicit* children. We treat a namespace package as
       importable only when it has regular python files as children, i.e. when this set is
       nonempty. *)
    type t = RawModulePathSet.t [@@deriving compare]

    let empty = RawModulePathSet.empty

    let description = "ImplicitModules"

    let should_treat_as_importable explicit_children =
      not (RawModulePathSet.is_empty explicit_children)
  end

  module Update = struct
    type t =
      | New of Reference.t
      | Delete of Reference.t
    [@@deriving sexp, compare]
  end

  module Table = struct
    module Api = struct
      type t = {
        should_skip_update: Reference.t -> bool;
        find: Reference.t -> Value.t option;
        set: Reference.t -> Value.t -> unit;
      }

      module Existence = struct
        type t = {
          existed_before: bool;
          exists_after: bool;
        }

        let to_update ~qualifier { existed_before; exists_after } =
          match existed_before, exists_after with
          | false, true -> Some (Update.New qualifier)
          | true, false -> Some (Update.Delete qualifier)
          | true, true
          | false, false ->
              None
      end

      let update_module_paths ~module_path_updates { find; set; should_skip_update } =
        let process_module_path_update previous_existence module_path_update =
          let module_path = ModulePaths.Update.module_path module_path_update in
          match parent_qualifier_and_raw module_path with
          | None -> previous_existence
          | Some (qualifier, raw_child) ->
              if should_skip_update qualifier then
                previous_existence
              else (* Get the previous state and new state *)
                let previous_explicit_children =
                  find qualifier |> Option.value ~default:RawModulePathSet.empty
                in
                let next_explicit_children =
                  match module_path_update with
                  | ModulePaths.Update.NewOrChanged _ ->
                      RawModulePathSet.add raw_child previous_explicit_children
                  | ModulePaths.Update.Remove _ ->
                      RawModulePathSet.remove raw_child previous_explicit_children
                in
                (* update implicit_modules as a side effect *)
                let () = set qualifier next_explicit_children in
                (* As we fold the updates, track existince before-and-after *)
                let next_existence =
                  let open Existence in
                  Map.update previous_existence qualifier ~f:(function
                      | None ->
                          {
                            existed_before =
                              Value.should_treat_as_importable previous_explicit_children;
                            exists_after = Value.should_treat_as_importable next_explicit_children;
                          }
                      | Some { existed_before; _ } ->
                          {
                            existed_before;
                            exists_after = Value.should_treat_as_importable next_explicit_children;
                          })
                in
                next_existence
        in
        List.fold module_path_updates ~init:Reference.Map.empty ~f:process_module_path_update
        |> Map.filter_mapi ~f:(fun ~key ~data -> Existence.to_update ~qualifier:key data)
        |> Map.data
    end

    module Eager = struct
      type t = Value.t Reference.Table.t

      let create explicit_modules =
        let implicit_modules = Reference.Table.create () in
        let process_module_path module_path =
          match parent_qualifier_and_raw module_path with
          | None -> ()
          | Some (parent_qualifier, raw) ->
              Hashtbl.update implicit_modules parent_qualifier ~f:(function
                  | None -> RawModulePathSet.singleton raw
                  | Some paths -> RawModulePathSet.add raw paths)
        in
        Hashtbl.iter explicit_modules ~f:(List.iter ~f:process_module_path);
        implicit_modules


      let to_api eager =
        let should_skip_update _ = false in
        let find qualifier = Hashtbl.find eager qualifier in
        let set qualifier data = Hashtbl.set eager ~key:qualifier ~data in
        Api.{ should_skip_update; find; set }
    end

    module Lazy = struct
      include LazyTracking.Table.Make (struct
        include Value

        let produce = ModulePaths.LazyFinder.find_submodule_paths
      end)

      let to_api table =
        let should_skip_update qualifier = not (key_exists table qualifier) in
        Api.{ should_skip_update; find = find table; set = set table }
    end
  end
end

module Layouts = struct
  module Api = struct
    type t = {
      explicit_modules: ExplicitModules.Table.Api.t;
      implicit_modules: ImplicitModules.Table.Api.t;
      process_module_path_updates: ModulePaths.Update.t list -> unit;
      store: unit -> unit;
    }

    let combine_explicits_and_implicit_module_updates explicit_updates implicit_updates =
      (* Explicit updates should shadow implicit updates *)
      let explicitly_modified_qualifiers = Reference.Hash_set.create () in
      let explicits =
        let process_explicit_update = function
          | ExplicitModules.Update.New ({ ModulePath.qualifier; _ } as module_path)
          | ExplicitModules.Update.Changed ({ ModulePath.qualifier; _ } as module_path) ->
              Hash_set.add explicitly_modified_qualifiers qualifier;
              SourceCodeIncrementalApi.UpdateResult.ModuleUpdate.NewExplicit module_path
          | ExplicitModules.Update.Delete qualifier ->
              Hash_set.add explicitly_modified_qualifiers qualifier;
              SourceCodeIncrementalApi.UpdateResult.ModuleUpdate.Delete qualifier
        in
        List.map explicit_updates ~f:process_explicit_update
      in
      let implicits =
        let process_implicit_update = function
          | ImplicitModules.Update.New qualifier ->
              if Hash_set.mem explicitly_modified_qualifiers qualifier then
                None
              else
                Some (SourceCodeIncrementalApi.UpdateResult.ModuleUpdate.NewImplicit qualifier)
          | ImplicitModules.Update.Delete qualifier ->
              if Hash_set.mem explicitly_modified_qualifiers qualifier then
                None
              else
                Some (SourceCodeIncrementalApi.UpdateResult.ModuleUpdate.Delete qualifier)
        in
        List.filter_map implicit_updates ~f:process_implicit_update
      in
      List.append explicits implicits


    let update
        ~configuration
        ~events
        { explicit_modules; implicit_modules; process_module_path_updates; _ }
      =
      let module_path_updates = ModulePaths.Update.from_artifact_events ~configuration events in
      let () = process_module_path_updates module_path_updates in
      let explicit_updates =
        ExplicitModules.Table.Api.update_module_paths
          ~configuration
          ~module_path_updates
          explicit_modules
      in
      let implicit_updates =
        ImplicitModules.Table.Api.update_module_paths ~module_path_updates implicit_modules
      in
      let updates =
        combine_explicits_and_implicit_module_updates explicit_updates implicit_updates
      in
      Log.log
        ~section:`Server
        "Explicit Module Update: %a"
        Sexp.pp
        [%message (explicit_updates : ExplicitModules.Update.t list)];
      Log.log
        ~section:`Server
        "Implicit Module Update: %a"
        Sexp.pp
        [%message (implicit_updates : ImplicitModules.Update.t list)];
      updates


    let module_path_of_qualifier { explicit_modules = { find; _ }; _ } ~qualifier =
      find qualifier >>= ExplicitModules.Value.module_path


    let is_implicit_module { implicit_modules = { find; _ }; _ } ~qualifier =
      find qualifier
      >>| ImplicitModules.Value.should_treat_as_importable
      |> Option.value ~default:false


    let look_up_qualifier layouts ~qualifier =
      match module_path_of_qualifier layouts ~qualifier with
      | Some module_path -> SourceCodeApi.ModuleLookup.Explicit module_path
      | None ->
          if is_implicit_module layouts ~qualifier then
            SourceCodeApi.ModuleLookup.Implicit
          else
            SourceCodeApi.ModuleLookup.NotFound


    let all_module_paths { explicit_modules = { data; _ }; _ } = data () |> List.concat

    let module_paths { explicit_modules = { data; _ }; _ } =
      data () |> List.filter_map ~f:ExplicitModules.Value.module_path


    let store { store; _ } = store ()
  end

  module Eager = struct
    type t = {
      explicit_modules: ExplicitModules.Table.Eager.t;
      implicit_modules: ImplicitModules.Table.Eager.t;
    }

    let create ~controls =
      let configuration = EnvironmentControls.configuration controls in
      let module_paths =
        match EnvironmentControls.in_memory_sources controls with
        | None -> ModulePaths.Finder.find_all configuration
        | Some in_memory_sources -> List.map in_memory_sources ~f:fst
      in
      let explicit_modules = ExplicitModules.Table.Eager.create ~configuration module_paths in
      let implicit_modules = ImplicitModules.Table.Eager.create explicit_modules in
      { explicit_modules; implicit_modules }


    module Serializer = Memory.Serializer (struct
      type nonrec t = t

      module Serialized = struct
        type t = (Reference.t * ModulePath.t list) list * (Reference.t * RawModulePathSet.t) list

        let prefix = Hack_parallel.Std.Prefix.make ()

        let description = "Module tracker"
      end

      let serialize { explicit_modules; implicit_modules } =
        Hashtbl.to_alist explicit_modules, Hashtbl.to_alist implicit_modules


      let deserialize (module_data, implicits_data) =
        {
          explicit_modules = Reference.Table.of_alist_exn module_data;
          implicit_modules = Reference.Table.of_alist_exn implicits_data;
        }
    end)

    let to_api ({ explicit_modules; implicit_modules } as layouts) =
      Api.
        {
          explicit_modules = ExplicitModules.Table.Eager.to_api explicit_modules;
          implicit_modules = ImplicitModules.Table.Eager.to_api implicit_modules;
          process_module_path_updates = ignore;
          store = (fun () -> Serializer.store layouts);
        }
  end

  module Lazy = struct
    type t = {
      lazy_finder: ModulePaths.LazyFinder.t;
      explicit_modules: ExplicitModules.Table.Lazy.t;
      implicit_modules: ImplicitModules.Table.Lazy.t;
    }

    let create ~controls =
      let lazy_finder =
        EnvironmentControls.configuration controls |> ModulePaths.LazyFinder.create
      in
      let explicit_modules = ExplicitModules.Table.Lazy.create ~lazy_finder in
      let implicit_modules = ImplicitModules.Table.Lazy.create ~lazy_finder in
      { lazy_finder; explicit_modules; implicit_modules }


    let process_module_path_updates ~lazy_finder module_path_updates =
      let invalidate_cache module_path_update =
        ModulePaths.Update.module_path module_path_update
        |> ModulePath.qualifier
        |> ModulePaths.LazyFinder.invalidate lazy_finder
      in
      List.iter module_path_updates ~f:invalidate_cache


    let to_api { lazy_finder; explicit_modules; implicit_modules } =
      Api.
        {
          explicit_modules = ExplicitModules.Table.Lazy.to_api explicit_modules;
          implicit_modules = ImplicitModules.Table.Lazy.to_api implicit_modules;
          process_module_path_updates = process_module_path_updates ~lazy_finder;
          store = (fun () -> failwith "Lazy ModuleTrackers cannot be stored");
        }
  end

  let create ~controls =
    if EnvironmentControls.use_lazy_module_tracking controls then
      Lazy.create ~controls |> Lazy.to_api
    else
      Eager.create ~controls |> Eager.to_api


  let load ~controls:_ = Eager.Serializer.load () |> Eager.to_api
end

module Base = struct
  type t = {
    layouts: Layouts.Api.t;
    controls: EnvironmentControls.t;
    code_of_module_path: ModulePath.t -> Parsing.LoadResult.t;
  }

  let load_raw_code ~configuration module_path =
    let path = ArtifactPaths.artifact_path_of_module_path ~configuration module_path in
    try Ok (ArtifactPath.raw path |> File.create |> File.content_exn) with
    | Sys_error error ->
        Error (Format.asprintf "Cannot open file `%a` due to: %s" ArtifactPath.pp path error)


  let make_code_of_module_path ~controls =
    let configuration = EnvironmentControls.configuration controls in
    match EnvironmentControls.in_memory_sources controls with
    | None -> load_raw_code ~configuration
    | Some in_memory_sources ->
        let in_memory_sources =
          let table = Reference.Table.create () in
          let add_pair (module_path, code) =
            Hashtbl.set table ~key:(ModulePath.qualifier module_path) ~data:code
          in
          List.iter in_memory_sources ~f:add_pair;
          table
        in
        let code_of_module_path ({ ModulePath.qualifier; _ } as module_path) =
          match Hashtbl.find in_memory_sources qualifier with
          | Some code -> Ok code
          | None -> load_raw_code ~configuration module_path
        in
        code_of_module_path


  let create controls =
    Log.info "Building module tracker...";
    let timer = Timer.start () in
    let layouts = Layouts.create ~controls in
    let code_of_module_path = make_code_of_module_path ~controls in
    Statistics.performance ~name:"module tracker built" ~timer ~phase_name:"Module tracking" ();
    { layouts; controls; code_of_module_path }


  let controls { controls; _ } = controls

  let update { layouts; controls; _ } ~events =
    let timer = Timer.start () in
    EnvironmentControls.assert_allow_updates controls;
    let result =
      let configuration = EnvironmentControls.configuration controls in
      Layouts.Api.update layouts ~configuration ~events
    in
    Statistics.performance ~name:"module tracker updated" ~timer ~phase_name:"Module tracking" ();
    result


  module Serializer = struct
    let store_layouts { layouts; _ } = Layouts.Api.store layouts

    let from_stored_layouts ~controls () =
      let configuration = EnvironmentControls.configuration controls in
      let layouts = Layouts.load ~controls in
      { layouts; controls; code_of_module_path = load_raw_code ~configuration }
  end

  let all_module_paths { layouts; _ } = Layouts.Api.all_module_paths layouts

  let module_paths { layouts; _ } = Layouts.Api.module_paths layouts

  let read_only { layouts; controls; code_of_module_path; _ } =
    let look_up_qualifier qualifier = Layouts.Api.look_up_qualifier layouts ~qualifier in
    { ReadOnly.look_up_qualifier; code_of_module_path; controls = (fun () -> controls) }


  let overlay tracker = read_only tracker |> Overlay.from_read_only

  module AssumeGlobalModuleListing = struct
    let global_module_paths_api tracker =
      GlobalModulePathsApi.create (fun () -> module_paths tracker)
  end
end

include Base
