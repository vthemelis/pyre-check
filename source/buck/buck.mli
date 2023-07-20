(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** The library provides utilities for the type checker to interact with [Buck].

    From Pyre's perspective, a build system like Buck does one thing and one thing only: it copies a
    bunch of files from one location to another location. Specifically, the inputs to buck are:

    - A set of source files (e.g. .py, .pyi, etc.).
    - A (set of) "recipe" file telling the build system how the copying works. For buck, the recipes
      would be the TARGETS or BUCK files.

    Taking these inputs, Buck would copy each source file to a pre-determined location according to
    what the recipe says. It is usually the case that all source files are put under a common parent
    directory. We will refer to that directory as the "source root" here. It is usually the case
    that destinations of the source files are put under a common parent directory as well. And we
    will refer to that directory as "artifact root".

    Without Buck, type checking is straightforward: just run pyre with source directory set to the
    source root. But if the project being checked builds with Buck, things are not so simple. Buck
    is flexible enough to the extent that if Buck builds a project, it will create copies/symlinks
    from the source files to artifact files, where artifact files do not necessarily end up being
    placed in the same relative path as they are placed in the source directories. Running Pyre
    directly on the source root will often lead to incorrect result if any relocation happens.

    In order to "see through" these relocations, Pyre needs to understand how files are laid out in
    the artifact root, and it needs to perform type checking with source directory set to the
    artifact root instead of the source root. Such an additional build step introduces some new
    challenges that are not presented in a non-Buck settings:

    - Artifact roots are typically not exposed to the end user. Pyre users typically edits files
      under the source root and they expect the diagnostics generated by pyre would point them to
      those source files, not the built/copied files.
    - When running commands like `pyre query`, the user typically send the Pyre server file paths
      under the source root. The Pyre server then needs to translate these source paths into the
      corresponding artifact paths before looking up its internal state, as type checking was not
      performed on top of the source root so the server lookup cannot key on source paths directly.
    - It is usually the case that source roots are monitored by file watching services like
      [watchman] but the artifact roots are not. So when the Pyre server receives a filesystem
      update message, the paths are always under source root. Again, the incremental checks logic
      needs to somehow translate those update messages with source root paths into those with
      artifact root paths as the artifact root is what the core typing logic really sees.

    All three problems mentioned here are essentially path translation problems. To resolve these
    problems, the solution we take here is to interact with Buck to understand file layouts in the
    artifact paths, materialize the layout info into a data structure called {!module:BuildMap}
    (which supports efficient bi-directional path lookup), and populate the artifact path on the
    Pyre side according to materialized layout info. Besides construction, we also need to maintain
    the build map and the artifact directory on each incremental update ourselves, as Buck itself
    does not expose any easy-to-query incremental update functionalities.

    Overall, this library provides its downstream clients with 3 layers of abstraction:

    - The lowest abstraction layer is {!module:Raw}, which handles the low-level details of how Pyre
      communicates with Buck (e.g. how to shell out to the [buck] executable, how cli arguments are
      passed, how subprocess stdout/stderr are handled, etc.).
    - The middle abstraction layer is {!module:Interface}, which handles how one or more [buck]
      invocations can be organized to perform higher-level tasks (e.g. normalize targets, load
      source databases, etc.).
    - The highest abstraction layer is {!module:Builder}, which coordinates one or more [buck] tasks
      as well as Pyre's own link tree building tasks to offer push-button build state management.
      (e.g. "build this project", "incrementally update my build", etc.).*)

(** This module implements build map, which is the key data structure for solving the path
    translation problem for Buck. The build map represents a one-to-many association: there can be
    only one source file mapped to a given artifact file, but there can be multiple artifact files
    mapped to the same source file. Mappings are interpreted in an order-insensitive way: it does
    not matter which items are inserted before or after which. As long as two mappings hold the same
    combination of items, they will be considered equivalent.

    The map only holds relative paths. To pin down the absolute path, additional root directoiry
    info for the both sources and artifacts is required.

    One implicit assumption we make regarding the artifact paths is that the names of
    sub-directories under which the artifact files live do not conflict with the names of the
    artifact files themselves. For example, if there is a mapping for artifact file `a.py`, then we
    assume that no other artifact would live under a directory named `a.py`. Conversely, if there is
    a mapping for artifact `foo/a.py`, then we assume that no other artifact file would be named
    `foo`. This property is not enforced by any of the build map APIs due to the associated cost of
    the check, but it is nevertheless crucial for the correctness of many downstream clients. *)
module BuildMap : sig
  (** A partial build map is an link-tree-to-source mapping for all `.py` or `.pyi` files within a
      specific Buck target. It is usually build from a buck source-db JSON file. *)
  module Partial : sig
    type t [@@deriving sexp]

    (** An empty map. *)
    val empty : t

    (** Create a partial build map from an associative list. The list must conform to `(source_path,
        artifact_path)` format. Raise an exception if the given list contains duplicated keys. *)
    val of_alist_exn : (string * string) list -> t

    (** Create a partial build map from an associative list. The list must conform to `(source_path,
        artifact_path)` format. If duplicated keys exists, first item in the input list wins. *)
    val of_alist_ignoring_duplicates : (string * string) list -> t

    (** Create a partial build map from a JSON. The JSON must conform to Buck's Python source-db
        format. Raise an exception if the input JSON is malformed. *)
    val of_json_exn_ignoring_duplicates : Yojson.Safe.t -> t

    (** Create a partial build map from a JSON. The JSON must conform to Buck's Python
        source-db-no-deps format. Raise an exception if the input JSON is malformed. *)
    val of_json_exn_ignoring_duplicates_no_dependency : Yojson.Safe.t -> t

    (** [filter ~f m] returns a new partial build map [m'] that contains all mappings in [m] except
        the ones on which [f ~key ~data] returns [false]. *)
    val filter : t -> f:(key:string -> data:string -> bool) -> t

    (** Given two partial build maps [l] and [r], [merge ~resolve_conflict l r] returns a new
        partial build map [m] containing items in both maps. Specifically:

        - [m] will map [key] to [value] for [(key, value)] pairs that are present in exactly one of
          [l] and [r].
        - [m] will map [key] to [resolve_conflict ~key value0 value1] when both [l] and [r] contain
          a given key with [value0] and [value1], respectively. *)
    val merge : resolve_conflict:(key:string -> string -> string -> string) -> t -> t -> t
  end

  (** Result type for the [index] operation. *)
  module Indexed : sig
    type t

    (** Lookup the source path that corresponds to the given artifact path. If there is no such
        artifact, return [None]. Time complexity of this operation is O(1).*)
    val lookup_source : t -> string -> string option

    (** Lookup all artifact paths that corresponds to the given source path. If there is no such
        artifact, return an empty list. Time complexity of this operation is O(1).*)
    val lookup_artifact : t -> string -> string list
  end

  (** Result type for the [difference] operation. It represents a set of artifact paths where each
      path has an associated tag indicating whether the file is added, removed, or updated. *)
  module Difference : sig
    module Kind : sig
      type t =
        | New of string
        | Deleted
        | Changed of string
      [@@deriving sexp, compare]
    end

    type t [@@deriving sexp]

    (** Create a build map difference from an associative list. The list must conform to
        `(artifact_path, kind)` format. Raise an exception if the given list contains duplicated
        keys. *)
    val of_alist_exn : (string * Kind.t) list -> t

    (** Convert a build map difference into an associated list. Each element in the list is a pair
        consisting of both the artifact path and the kind of the update. *)
    val to_alist : t -> (string * Kind.t) list

    (** [merge a b] returns [Result.Ok c] where [c] includes artifact paths from both [a] and [b].
        If an artifact [path] is included in both [a] and [b] but the associated tags are different,
        [Result.Error path] will be returned instead. *)
    val merge : t -> t -> (t, string) Result.t
  end

  (** Type of the build map. *)
  type t

  (** Create a build map from a partial build map. This is intended to be the only API for build map
      creation. *)
  val create : Partial.t -> t

  (** Create a index for the given build map and return a pair of constant-time lookup functions
      that utilizes the index. *)
  val index : t -> Indexed.t

  (** Return the number of artifact files stored in the build map. *)
  val artifact_count : t -> int

  (** Convert a partial build map into an associated list. Each element in the list represent an
      (artifact_path, source_path) mapping. *)
  val to_alist : t -> (string * string) list

  (** [difference ~original current] computes the difference between the [original] build map and
      the [current] build map. Time complexity of this operation is O(n + m), where n and m are the
      sizes of the two build maps. *)
  val difference : original:t -> t -> Difference.t

  (** [strict_apply_difference ~difference:d original] tries to compute a new build map [current],
      such that [difference ~original current] equals [d]. It can be seen as an inverse operation of
      {!difference}.

      If the computation succeeds, [Result.Ok d] is returned. Otherwise, [Result.Error p] is
      returned, where [p] represents the artifact path that causes the operation to fail.

      Potentail reasons of failure:

      - [d] contains an artifact path [p] with tag [Deleted], but [p] cannot be found in [original].
      - [d] contains an artifact path [p] with tag [New], but [p] already has an associated source
        path in [original].
      - [d] contains an aritfact path [p] with tag [Changed], but [p] already has an associated
        source path in [original]. This is what makes this operation "strict": we do not allow
        {b any} pre-existing bindings in [original] to be redirected, even with the [Changed] tag.

      Time complexity of this operation is O(n + m), where n is the size of the original build map
      and m is the size of the difference. *)
  val strict_apply_difference : difference:Difference.t -> t -> (t, string) Result.t
end

(** This module provide utility functions for populating and incrementally updating artifact roots.

    All build-related APIs in this file assumes that file names and directory names do not overlap
    in any of the given build map (see documentation for {!module:BuildMap}). If this assumption is
    broken, build result will be non-deterministic due to race conditions between file
    creation/removal and directory creation/removal. *)
module Artifacts : sig
  (** Populate the artifact directory given a source root, an artifact root, and a build map. Return
      [Result.Ok ()] if the build succeeds, and [Result.Error message] otherwise, where [message]
      contains the error message.

      Specifically, what [populate] does is, for each source path in the build map, to calculate the
      corresponding path of the artifact, and create a symlink to the original source file at the
      said path. All source paths in the build map will be rooted at the [source_root] argument, and
      all artifact paths in the build map will be rooted at the [artifact_root] argument. There is
      no guarantee on the order in which the artifact symlink gets created -- this API only
      guarantees that when the returned promise is resolved and no error occurs, all artifacts will
      be created.

      If either [source_root] or [artifact_root] is not a directory, an error will be returned.
      During the build process, new directories and symlinks may be created under [artifact_root]
      \-- if any of the creation fails (e.g. creating a symlink at a location where there already
      exists a file, or when creating a directory at a location where there already exists a
      non-directory), the entire process fails. Directories created by this API will have the
      default permission of 0777 (unless adjusted by [umask]).

      Although in its typical usage [artifact_root] would be an empty directory prior to the full
      build, this API makes no attempt to check for that. It can be fully functional as long as
      pre-existing files under [artifact_root] do not have naming conflicts with any of the
      artifacts. If cleaness of the artifact directory is required, it is expected that the caller
      would take care of that before invoking [full_build]. *)
  val populate
    :  source_root:PyrePath.t ->
    artifact_root:PyrePath.t ->
    BuildMap.t ->
    (unit, string) Result.t Lwt.t

  (** Incrementally update the artifact directory given a source root, an artifact root, and a build
      map difference specificiation. Return [Result.Ok ()] if the build succeeds, and
      [Result.Error message] otherwise, where [message] contains the error message.

      Specifically, what an incremental update does is, for each artifact path in the difference
      spec, to figure out how to update the filesystem accordingly. If a new mapping is added,
      create a new artifact symlink at the corresponding location. If an old mapping is deleted,
      remove the old artifact symlink at the corresponding location. If the artifact is redirected
      to a different source file, update the symlink accordingly.

      All source paths in the build map will be rooted at the [source_root] argument, and all
      artifact paths in the build map will be rooted at the [artifact_root] argument. There is no
      guarantee on the order in which the artifact symlink gets updated -- this API only guarantees
      that when the returned promise is resolved and no error occurs, incremental build would be
      finished.

      If either [source_root] or [artifact_root] is not a directory, an error will be returned.
      During the build process, new directories and symlinks may be created under [artifact_root],
      and old symlinks may be deleted -- if any of the creation or removal fails (e.g. do not have
      the right permission to remove the files), the entire process fails. Directories created by
      this API will have the default permission of 0777 (unless adjusted by [umask]). *)
  val update
    :  source_root:PyrePath.t ->
    artifact_root:PyrePath.t ->
    BuildMap.Difference.t ->
    (unit, string) Result.t Lwt.t
end

(** This module provides a wrapper type that represents a normalized Buck target. *)
module Target : sig
  type t [@@deriving sexp, compare, hash]

  (** Create a [Target.t] out of a string. *)
  val of_string : string -> t

  val show : t -> string

  val pp : Format.formatter -> t -> unit
end

(** This module contains the low-level interfaces for invoking [buck] as an external tool. *)
module Raw : sig
  module ArgumentList : sig
    (** This type represents the argument list for a raw Buck invocation. *)
    type t [@@deriving sexp_of]

    (** Reconstruct the shell command Pyre uses to invoke Buck from an {!ArgumentList.t}. *)
    val to_buck_command : buck_command:string -> t -> string

    (** Number of arguments in the list*)
    val length : t -> int
  end

  (** Raised when external invocation of `buck` returns an error. The [exit_code] field is set to
      [None] if the external `buck` process gets stopped by a signal. The [additional_log] field
      contains the last few lines of Buck's log that get dumped on its stderr. *)
  exception
    BuckError of {
      buck_command: string;
      arguments: ArgumentList.t;
      description: string;
      exit_code: int option;
      additional_logs: string list;
    }
  [@@deriving sexp_of]

  (** This module contains utility structure to interact with Buck on command-line. *)
  module Command : sig
    module Output : sig
      (** Utility type to represent the result obtained via a Buck command invocation. *)
      type t = {
        stdout: string;
        build_id: string option;
      }
    end

    (** Utility type to represent the argument and return type for common command-line Buck
        interaction.

        Note that mode and isolation prefix are intentionally required to be specified separately,
        since Buck interpret them a bit differently from the rest of the arguments. *)
    type t = ?mode:string -> ?isolation_prefix:string -> string list -> Output.t Lwt.t
  end

  (** This module contains APIs specific to Buck1 *)
  module V1 : sig
    type t

    (** Create an instance of [t] based on system-installed Buck1. The [additional_log_size]
        parameter controls how many lines of Buck log to preserve when an {!BuckError} is raised. By
        default, the size is set to 0, which means no additional log will be kept. *)
    val create : ?additional_log_size:int -> unit -> t

    (** Create an instance of [t] from custom [query] and [build] behavior. Useful for unit testing. *)
    val create_for_testing : query:Command.t -> build:Command.t -> unit -> t

    (** Shell out to `buck1 query` with the given cli arguments. Returns the content of stdout. If
        the return code is not 0, raise [BuckError]. *)
    val query : t -> Command.t

    (** Shell out to `buck1 build` with the given cli arguments. Returns the content of stdout. If
        the return code is not 0, raise [BuckError]. *)
    val build : t -> Command.t
  end

  (** This module contains APIs specific to Buck2 *)
  module V2 : sig
    type t

    (** Create an instance of [t] based on system-installed Buck2. The [additional_log_size]
        parameter controls how many lines of Buck2 log to preserve when an {!BuckError} is raised.
        By default, the size is set to 0, which means no additional log will be kept. *)
    val create : ?additional_log_size:int -> unit -> t

    (** Create an instance of [t] from custom [bxl] behavior. Useful for unit testing. *)
    val create_for_testing : bxl:Command.t -> unit -> t

    (** Shell out to `buck2 bxl` with the given cli arguments. Returns the content of stdout. If the
        return code is not 0, raise [BuckError]. *)
    val bxl : t -> Command.t
  end
end

(** This module contains high-level interfaces for invoking [buck] as an external tool. It relies on
    the {!module:Raw} module to provide the lower-level knowledge on how the [buck] executable
    should be invoked. *)
module Interface : sig
  (** Raised when [buck] returns malformed JSONs *)
  exception JsonError of string

  (** The return type for initial builds. It contains a build map as well as a list of buck targets
      that are successfully included in the build. *)
  module BuildResult : sig
    type t = {
      build_map: BuildMap.t;
      targets: Target.t list;
    }
  end

  (** This module contains APIs specific to Buck1 *)
  module V1 : sig
    type t

    (** Create an instance of [t] from an instance of {!Raw.V1.t} and some buck options. Interfaces
        created this way is only compatible with Buck1. *)
    val create : ?mode:string -> ?isolation_prefix:string -> Raw.V1.t -> t

    module BuckChangedTargetsQueryOutput : sig
      type t = {
        source_base_path: string;
        artifact_base_path: string;
        artifacts_to_sources: (string * string) list;
      }

      val to_partial_build_map : t -> (BuildMap.Partial.t, string) Result.t

      val to_build_map_batch : t list -> (BuildMap.t, string) Result.t
    end

    (** Create an instance of [t] from custom [normalize_targets], [construct_build_map], and
        [query_owner_targets] behavior. Useful for unit testing. *)
    val create_for_testing
      :  normalize_targets:(string list -> Target.t list Lwt.t) ->
      construct_build_map:(Target.t list -> BuildResult.t Lwt.t) ->
      query_owner_targets:
        (targets:Target.t list -> PyrePath.t list -> BuckChangedTargetsQueryOutput.t list Lwt.t) ->
      unit ->
      t

    (** Given a list of buck target specifications (which may contain `...` or filter expression),
        query [buck] and return the set of individual targets which will be built.

        May raise {!Raw.BuckError} when `buck` invocation fails, or {!JsonError} when `buck` itself
        succeeds but its output cannot be parsed. *)
    val normalize_targets : t -> string list -> Target.t list Lwt.t

    (** Given a list of normalized Buck targets, invoke [buck] to construct the link tree as well as
        source databases. It then loads all generated source databases, and merge all of them into a
        single [BuildMap.t].

        Source-db merging may not always succeed when merge conflict cannot be resolved (see
        {!val:BuildMap.Partial.merge}). If it is deteced that the source-db for one target cannot be
        merged into the build map due to unresolvable conflict, a warning will be printed and the
        target will be dropped. If a target is dropped, it will not show up in the final target list
        returned from this API (alongside with the build map).

        May raise {!Raw.BuckError} when `buck` invocation fails, or {!JsonError} when `buck` itself
        succeeds but its output cannot be parsed. *)
    val construct_build_map : t -> Target.t list -> BuildResult.t Lwt.t

    (** Given a list of normalized Buck targets and a list of changed files, invoke [buck] to find
        out what owner targets of those changed files are beneath the given normalized target list,
        and finally return "local build map" for those owner targets in the form of
        [BuckChangedTargetsQueryOutput.t].

        May raise {!Raw.BuckError} when `buck` invocation fails, or {!JsonError} when `buck` itself
        succeeds but its output cannot be parsed. *)
    val query_owner_targets
      :  t ->
      targets:Target.t list ->
      PyrePath.t list ->
      BuckChangedTargetsQueryOutput.t list Lwt.t
  end

  (** This module contains APIs specific to Buck2 *)
  module V2 : sig
    type t

    (** Create an instance of [t] from an instance of {!Raw.V2.t} and some buck options. Interfaces
        created this way is only compatible with Buck2.*)
    val create : ?mode:string -> ?isolation_prefix:string -> ?bxl_builder:string -> Raw.V2.t -> t

    (** Create an instance of [t] from custom [construct_build_map] behavior. Useful for unit
        testing. *)
    val create_for_testing : construct_build_map:(string list -> BuildMap.t Lwt.t) -> unit -> t

    (** Given a list of Buck targets or target expressions, invoke [buck] to construct the link tree
        as well as source databases. It then loads all generated source databases, and merge all of
        them into a single [BuildMap.t].

        Source-db merging may not always succeed when merge conflict cannot be resolved (see
        {!val:BuildMap.Partial.merge}). If it is deteced that the source-db for one target cannot be
        merged into the build map due to unresolvable conflict, a warning will be printed and the
        target will be dropped.

        May raise {!Raw.BuckError} when `buck` invocation fails, or {!JsonError} when `buck` itself
        succeeds but its output cannot be parsed. *)
    val construct_build_map : t -> string list -> BuildMap.t Lwt.t
  end

  (** This module contains APIs specific to lazy Buck building.

      Lazy building is only supported for Buck2. The APIs are very simliar to those of
      {!Interface.V2}, except that targets to build are not specified upfront for the lazy case.
      Instead, the lazy builder is only given a set of source paths to construct the build map on,
      and the builder itself needs to figure out what are the corresponding targets for these source
      paths. *)
  module Lazy : sig
    type t

    (** Create an instance of [t] from an instance of {!Raw.V2.t} and some buck options. *)
    val create : ?mode:string -> ?isolation_prefix:string -> bxl_builder:string -> Raw.V2.t -> t

    (** Create an instance of [t] from custom [construct_build_map] behavior. Useful for unit
        testing. *)
    val create_for_testing : construct_build_map:(string list -> BuildMap.t Lwt.t) -> unit -> t

    (** Given a list of relative source paths, invoke [buck] to construct the source databases as
        well as relevant files referenced in the link tree. It then loads all generated source
        databases, and merge all of them into a single {!BuildMap.t}.

        Source-db merging may not always succeed when merge conflict cannot be resolved . If it is
        deteced that the source-db for one target cannot be merged into the build map due to
        unresolvable conflict, a warning will be printed and one of the conflicted target will be
        dropped.

        May raise {!Raw.BuckError} when `buck` invocation fails, or {!JsonError} when `buck` itself
        succeeds but its output cannot be parsed. *)
    val construct_build_map : t -> string list -> BuildMap.t Lwt.t
  end
end

(** This module contains highest-level interfaces for [buck]-related logic. It relies on
    Buck-related logic from {!module:Interface} to obtain information about the source files, and on
    filesystem-related logic from {!module:Artifacts} to create&maintain information about the
    artifact files. *)
module Builder : sig
  (** Raised when artifact building fails. See {!val:Artifacts.populate}. *)
  exception LinkTreeConstructionError of string

  (** This module contains APIs specific to classical, non-lazy Buck building, where the targets
      that need to be built are specified upfront. *)
  module Classic : sig
    type t

    (** {1 Creation} *)

    (** Create an instance of {!Builder.Classic.t} from an instance of {!Interface.V1.t} and some
        buck options. Builders created this way are only compatible with Buck1. *)
    val create : source_root:PyrePath.t -> artifact_root:PyrePath.t -> Interface.V1.t -> t

    (** Create an instance of {!Builder.Classic.t} from an instance of {!Interface.V2.t} and some
        buck options. Builders created with way are only compatible with Buck2. *)
    val create_v2 : source_root:PyrePath.t -> artifact_root:PyrePath.t -> Interface.V2.t -> t

    (** {1 Build} *)

    (** The return type for incremental builds. It contains a build map, a list of buck targets that
        are successfully included in the build, and a list of artifact files whose contents may be
        altered by the build . *)
    module IncrementalBuildResult : sig
      type t = {
        build_map: BuildMap.t;
        targets: Target.t list;
        changed_artifacts: ArtifactPath.Event.t list;
      }
    end

    (** Given a list of buck target specificaitons to build, construct a build map for the targets
        and create a Python link tree at the given artifact root according to the build map. Return
        the constructed build map along with a list of targets that are covered by the build map.

        Concretely, the entire build process can be broken down into 4 steps:

        - Query `buck` to desugar any `...` wildcard and filter expressions.
        - Run `buck build` to force-generating all Python files and source databases.
        - Load all source databases generated from the previous step, and merge all of them into a
          single {!BuildMap.t}.
        - Construct the link tree under [artifact_root] based on the content of the {!BuiltMap.t}.

        The following exceptions may be raised by this API:

        - {!exception: Interface.JsonError} if `buck` returns malformed or inconsistent JSON blobs.
        - {!exception: Raw.BuckError} if `buck` quits in any unexpected ways when shelling out to
          it.
        - {!exception: LinkTreeConstructionError} if any error is encountered when constructing the
          link tree from the build map.

        Note this API does not ensure the artifact root to be empty before the build starts. If
        cleaness of the artifact directory is desirable, it is expected that the caller would take
        care of that before its invocation. *)
    val build : targets:string list -> t -> Interface.BuildResult.t Lwt.t

    (** Given a build map, create the corresponding Python link tree at the given artifact root
        accordingly.

        In most cases, downstream clients are discouraged from invoking this API.
        {!val:Builder.Classic.build} should be used instead, since it does not force the clients to
        construct a build map by themselves and risk having the build map and the link tree
        inconsistent with what the target specification says. The only scenario where it makes sense
        to prefer {!val:restore} over {!val:build} is saved state loading: in that case, we already
        load the old build map from saved state so it is not needed (and not possible as well) to
        re-construct that build map from scratch all over again.

        The following exceptions may be raised by this API:

        - {!exception: LinkTreeConstructionError} if any error is encountered when constructing the
          link tree from the build map.

        Note this API does not ensure the artifact root to be empty before the build starts. If
        cleaness of the artifact directory is desirable, it is expected that the caller would take
        care of that before its invocation. *)
    val restore : build_map:BuildMap.t -> t -> unit Lwt.t

    (** Given a list of buck target specificaitons to build, fully construct a new build map for the
        targets and incrementally update the Python link tree at the given artifact root according
        to how the new build map changed compared to the old build map. Return the new build map
        along with a list of targets that are covered by the build map. This API may raise the same
        set of exceptions as {!build}.

        This API is guaranteed to rebuild the entire build map from scratch. It is guaranteed to
        produce the most correct and most up-to-date build map, but at the same time it is a costly
        operation at times. For faster incremental build, itt is recommended to use other variant of
        incremental build APIs if their pre-conditions are known to be satisfied. *)
    val full_incremental_build
      :  old_build_map:BuildMap.t ->
      targets:string list ->
      t ->
      IncrementalBuildResult.t Lwt.t

    (** Given a list of normalized targets to build, fully construct a new build map for the targets
        and incrementally update the Python link tree at the given artifact root according to how
        the new build map changed compared to the old build map. Return the new build map along with
        a list of targets that are covered by the build map. This API may raise the same set of
        exceptions as {!full_incremental_build}.

        The difference between this API and {!full_incremental_build} is that this API makes an
        additional assumption that the given incremental update does not change the set of targets
        to build. As a result, it can skip the target normalizing step entirely as performance
        optimization. Such an assumption usually holds when the incremental update does not touch
        any `BUCK` or `TARGETS` file -- callers are encouraged to verify this before deciding which
        incremental build API to invoke. *)
    val incremental_build_with_normalized_targets
      :  old_build_map:BuildMap.t ->
      targets:Target.t list ->
      t ->
      IncrementalBuildResult.t Lwt.t

    (** Given a list of normalized targets and changed/removed files, incrementally construct a new
        build map for the targets and incrementally update the Python link tree at the given
        artifact root accordingly. Return the new build map along with a list of targets that are
        covered by the build map. This API may raise the same set of exceptions as
        {!incremental_build_with_normalized_targets}.

        The difference between this API and {!incremental_build_with_normalized_targets} is that
        this API makes an additional assumption that the given incremental update does not change
        the contents of any generated file. As a result, it can skip both the target normalizing
        step and the `buck build` step, which is usually a huge performance bottleneck for
        incremental checks. *)
    val fast_incremental_build_with_normalized_targets
      :  old_build_map:BuildMap.t ->
      old_build_map_index:BuildMap.Indexed.t ->
      targets:Target.t list ->
      changed_paths:PyrePath.t list ->
      removed_paths:PyrePath.t list ->
      t ->
      IncrementalBuildResult.t Lwt.t

    (** {1 Lookup} *)

    (** Lookup the source path that corresponds to the given artifact path. If there is no such
        artifact, return [None]. Time complexity of this operation is O(1). The difference between
        this API and {!BuildMap.Indexed.lookup_source} is that the build map API only understands
        relative paths, while this API operates on full paths and takes care of
        relativizing/expanding the input/output paths against source/artifact root. *)
    val lookup_source : index:BuildMap.Indexed.t -> builder:t -> PyrePath.t -> PyrePath.t option

    (** Lookup all artifact paths that corresponds to the given source path. If there is no such
        artifact, return an empty list. Time complexity of this operation is O(1).

        The difference between this API and {!BuildMap.Indexed.lookup_artifact} is that the build
        map API only understands relative paths, while this API operates on full paths and takes
        care of relativizing/expanding the input/output paths against artifact/source root.*)
    val lookup_artifact : index:BuildMap.Indexed.t -> builder:t -> PyrePath.t -> PyrePath.t list

    (** {1 Misc} *)

    (** Return an identifier of the builder (for logging purpose). *)
    val identifier_of : t -> string
  end

  (** This module contains APIs specific to lazy Buck building.

      Lazy building is only supported for Buck2. The APIs are very simliar to those of {!Builder},
      except that targets to build are not specified upfront for the lazy case. Instead, the lazy
      builder is only given a set of source paths to construct the build map on, and the builder
      itself needs to figure out what are the corresponding targets for these source paths. *)
  module Lazy : sig
    type t

    (** {1 Creation} *)

    (** Create an instance of [Builder.t] from an instance of {!Interface.Lazy.t} and some buck
        options. Builders created this way are only compatible with Buck2. *)
    val create : source_root:PyrePath.t -> artifact_root:PyrePath.t -> Interface.Lazy.t -> t

    (** {1 Build} *)

    (** The return type for incremental builds. It contains a build map and a list of artifact files
        whose contents may be altered by the build . *)
    module IncrementalBuildResult : sig
      type t = {
        build_map: BuildMap.t;
        changed_artifacts: ArtifactPath.Event.t list;
      }
    end

    (** Given a list of source path, re-construct a new build map for the owning targets and
        incrementally update the Python link tree at the given artifact root according to how the
        new build map changed compared to the old build map. Return the new build map along with a
        list of artifacts that are changed by the build.

        Concretely, the entire build process can be broken down into 4 steps:

        - Run `buck bxl` to build and load source databases into {!BuildMap.t} (see
          {!Interface.Lazy.construct_build_map}).
        - Construct the link tree under [artifact_root] based on the content of the newly built
          {!BuiltMap.t}. Note that this step is carried out incrementally: we compare the new build
          map with [old_build_map], and only perform the minimum amount of filesystem operations to
          update files under [artifact_root].

        The following exceptions may be raised by this API:

        - {!exception: Raw.BuckError} if `buck` quits in any unexpected ways when shelling out to
          it.
        - {!exception: Interface.JsonError} if `buck` returns malformed or inconsistent JSON blobs.
        - {!exception: LinkTreeConstructionError} if any error is encountered when constructing the
          link tree from the build map.

        Note this API does not ensure the artifact root to be empty before the build starts. If
        cleaness of the artifact directory is desirable, it is expected that the caller would take
        care of that before its invocation. *)
    val incremental_build
      :  old_build_map:BuildMap.t ->
      source_paths:SourcePath.t list ->
      t ->
      IncrementalBuildResult.t Lwt.t

    (** {1 Lookup} *)

    (** Lookup the source path that corresponds to the given artifact path. If there is no such
        artifact, return [None]. Time complexity of this operation is O(1). The difference between
        this API and {!BuildMap.Indexed.lookup_source} is that the build map API only understands
        relative paths, while this API operates on full paths and takes care of
        relativizing/expanding the input/output paths against source/artifact root. *)
    val lookup_source
      :  index:BuildMap.Indexed.t ->
      builder:t ->
      ArtifactPath.t ->
      SourcePath.t option

    (** Lookup all artifact paths that corresponds to the given source path. If there is no such
        artifact, return an empty list. Time complexity of this operation is O(1).

        The difference between this API and {!BuildMap.Indexed.lookup_artifact} is that the build
        map API only understands relative paths, while this API operates on full paths and takes
        care of relativizing/expanding the input/output paths against artifact/source root.*)
    val lookup_artifact
      :  index:BuildMap.Indexed.t ->
      builder:t ->
      SourcePath.t ->
      ArtifactPath.t list
  end
end
