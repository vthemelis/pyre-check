(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Newserver
open NewServerTest
module Path = Pyre.Path

let test_initialize context =
  let internal_state = ref "uninitiailzed" in
  let build_system_initializer =
    let initialize () =
      internal_state := "initialized";
      Lwt.return (BuildSystem.create_for_testing ())
    in
    BuildSystem.Initializer.create_for_testing ~initialize ()
  in
  let test_initialize _ =
    (* Verify that the build system has indeed been initiailzed. *)
    assert_equal ~ctxt:context ~cmp:String.equal ~printer:Fn.id "initialized" !internal_state;
    Lwt.return_unit
  in
  ScratchProject.setup
    ~context
    ~include_typeshed_stubs:false
    ~include_helper_builtins:false
    ~build_system_initializer
    []
  |> ScratchProject.test_server_with ~f:test_initialize


let test_cleanup context =
  let internal_state = ref "uncleaned" in
  let build_system_initializer =
    let initialize () =
      let cleanup () =
        internal_state := "cleaned";
        Lwt.return_unit
      in
      Lwt.return (BuildSystem.create_for_testing ~cleanup ())
    in
    BuildSystem.Initializer.create_for_testing ~initialize ()
  in
  let open Lwt.Infix in
  let server_configuration =
    ScratchProject.setup ~context ~include_typeshed_stubs:false ~include_helper_builtins:false []
    |> ScratchProject.server_configuration_of
  in
  Caml.Filename.set_temp_dir_name "/tmp";
  Start.start_server
    server_configuration
    ~build_system_initializer
    ~on_exception:(fun exn -> raise exn)
    ~on_started:(fun _ ->
      (* Shutdown the server immediately after it is started. *)
      Lwt.return Start.ExitStatus.Ok)
  >>= fun _ ->
  (* Verify that the build system has indeed been cleaned up. *)
  assert_equal ~ctxt:context ~cmp:String.equal ~printer:Fn.id "cleaned" !internal_state;
  Lwt.return_unit


let test_type_errors context =
  let test_source_path =
    (* The real value will be deterimend once the server starts. *)
    ref (Path.create_absolute "uninitialized")
  in
  let test_artifact_path = Path.create_absolute "/foo/test.py" in
  let build_system_initializer =
    let initialize () =
      let lookup_source path =
        if Path.equal path !test_source_path then
          Some test_artifact_path
        else
          None
      in
      let lookup_artifact path =
        if Path.equal path test_artifact_path then
          [!test_source_path]
        else
          []
      in
      Lwt.return (BuildSystem.create_for_testing ~lookup_source ~lookup_artifact ())
    in
    BuildSystem.Initializer.create_for_testing ~initialize ()
  in
  let test_type_errors client =
    let open Lwt.Infix in
    let global_root =
      Client.current_server_state client
      |> fun { ServerState.server_configuration = { ServerConfiguration.global_root; _ }; _ } ->
      global_root
    in
    test_source_path := Path.create_relative ~root:global_root ~relative:"test.py";
    let expected_error =
      Analysis.AnalysisError.Instantiated.of_yojson
        (`Assoc
          [
            "line", `Int 1;
            "column", `Int 0;
            "stop_line", `Int 1;
            "stop_column", `Int 11;
            "path", `String "/foo/test.py";
            "code", `Int (-1);
            "name", `String "Revealed type";
            ( "description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "long_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "concise_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            "inference", `Assoc [];
            "define", `String "test.$toplevel";
          ])
      |> Result.ok_or_failwith
    in
    Client.assert_response
      client
      ~request:(Request.DisplayTypeError [])
      ~expected:(Response.TypeErrors [expected_error])
    >>= fun () ->
    Client.assert_response
      client
      ~request:(Request.DisplayTypeError ["/foo/test.py"])
      ~expected:(Response.TypeErrors [expected_error])
  in
  ScratchProject.setup
    ~context
    ~include_typeshed_stubs:false
    ~include_helper_builtins:false
    ~build_system_initializer
    ["test.py", "reveal_type(42)"]
  |> ScratchProject.test_server_with ~f:test_type_errors


let test_update context =
  let internal_state = ref "unupdated" in
  let test_source_path = Path.create_absolute "/foo/test.py" in
  let test_artifact_path =
    (* The real value will be deterimend once the server starts. *)
    ref (Path.create_absolute "uninitialized")
  in
  let build_system_initializer =
    let initialize () =
      let lookup_source path =
        if Path.equal path !test_artifact_path then
          Some test_source_path
        else
          None
      in
      let lookup_artifact path =
        if Path.equal path test_source_path then
          [!test_artifact_path]
        else
          []
      in
      let update actual_paths =
        assert_equal
          ~ctxt:context
          ~cmp:[%compare.equal: Path.t list]
          ~printer:(fun paths -> List.map paths ~f:Path.show |> String.concat ~sep:", ")
          [test_source_path]
          actual_paths;
        internal_state := "updated";
        Lwt.return []
      in
      Lwt.return (BuildSystem.create_for_testing ~update ~lookup_source ~lookup_artifact ())
    in
    BuildSystem.Initializer.create_for_testing ~initialize ()
  in
  let test_update client =
    let open Lwt.Infix in
    let root =
      Client.current_server_state client
      |> fun { ServerState.server_configuration = { ServerConfiguration.global_root; _ }; _ } ->
      global_root
    in
    test_artifact_path := Path.create_relative ~root ~relative:"test.py";

    File.create !test_artifact_path ~content:"reveal_type(42)" |> File.write;
    Client.send_request client (Request.IncrementalUpdate [Path.absolute test_source_path])
    >>= fun _ ->
    (* Verify that the build system has indeed been updated. *)
    assert_equal ~ctxt:context ~cmp:String.equal ~printer:Fn.id "updated" !internal_state;
    (* Verify that recheck has indeed happened. *)
    let expected_error =
      Analysis.AnalysisError.Instantiated.of_yojson
        (`Assoc
          [
            "line", `Int 1;
            "column", `Int 0;
            "stop_line", `Int 1;
            "stop_column", `Int 11;
            "path", `String "/foo/test.py";
            "code", `Int (-1);
            "name", `String "Revealed type";
            ( "description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "long_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "concise_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            "inference", `Assoc [];
            "define", `String "test.$toplevel";
          ])
      |> Result.ok_or_failwith
    in
    Client.assert_response
      client
      ~request:(Request.DisplayTypeError [])
      ~expected:(Response.TypeErrors [expected_error])
    >>= fun () -> Lwt.return_unit
  in
  ScratchProject.setup
    ~context
    ~include_typeshed_stubs:false
    ~include_helper_builtins:false
    ~build_system_initializer
    ["test.py", "reveal_type(True)"]
  |> ScratchProject.test_server_with ~f:test_update


let test_buck_update context =
  (* Count how many times target renormalization has happened. *)
  let query_counter = ref 0 in
  let assert_query_counter expected =
    assert_equal ~ctxt:context ~cmp:Int.equal ~printer:Int.to_string expected !query_counter
  in

  let get_buck_build_system () =
    let raw =
      let query _ =
        incr query_counter;
        Lwt.return "{}"
      in
      let build _ = Lwt.return {| { "sources": {}, "dependencies": {} } |} in
      Buck.Raw.create_for_testing ~query ~build ()
    in
    let source_root = bracket_tmpdir context |> Path.create_absolute in
    let artifact_root = bracket_tmpdir context |> Path.create_absolute in
    {
      ServerConfiguration.Buck.mode = None;
      isolation_prefix = None;
      targets = ["//foo:target"];
      source_root;
      artifact_root;
    }
    |> BuildSystem.Initializer.buck ~raw
    |> BuildSystem.Initializer.run
  in
  let open Lwt.Infix in
  get_buck_build_system ()
  >>= fun buck_build_system ->
  (* Normalization will happen once upon initialization. *)
  assert_query_counter 1;

  (* Normalization won't happen if no target file changes. *)
  BuildSystem.update buck_build_system []
  >>= fun _ ->
  assert_query_counter 1;
  BuildSystem.update buck_build_system [Path.create_absolute "/foo/derp.py"]
  >>= fun _ ->
  assert_query_counter 1;

  (* Normalization will happen if target file has changes. *)
  BuildSystem.update buck_build_system [Path.create_absolute "/foo/TARGETS"]
  >>= fun _ ->
  assert_query_counter 2;
  BuildSystem.update buck_build_system [Path.create_absolute "/foo/BUCK"]
  >>= fun _ ->
  assert_query_counter 3;
  Lwt.return_unit


let () =
  "build_system_test"
  >::: [
         "initialize" >:: OUnitLwt.lwt_wrapper test_initialize;
         "cleanup" >:: OUnitLwt.lwt_wrapper test_cleanup;
         "type_errors" >:: OUnitLwt.lwt_wrapper test_type_errors;
         "update" >:: OUnitLwt.lwt_wrapper test_update;
         "buck_update" >:: OUnitLwt.lwt_wrapper test_buck_update;
       ]
  |> Test.run
