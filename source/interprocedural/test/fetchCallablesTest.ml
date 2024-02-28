(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Core
open Interprocedural

let test_callables context =
  let assert_callables ?(additional_sources = []) ?(source_filename = "test.py") source ~expected =
    let configuration, source_code_api, pyre_api =
      let scratch_project =
        Test.ScratchProject.setup ~context ((source_filename, source) :: additional_sources)
      in
      ( Test.ScratchProject.configuration_of scratch_project,
        Test.ScratchProject.get_untracked_source_code_api scratch_project,
        Test.ScratchProject.pyre_pysa_read_only_api scratch_project )
    in
    let source =
      Analysis.SourceCodeApi.source_of_qualifier source_code_api (Ast.Reference.create "test")
      |> Option.value_exn
    in
    FetchCallables.from_source ~configuration ~pyre_api ~include_unit_tests:false ~source
    |> FetchCallables.get ~definitions:true ~stubs:true
    |> List.sort ~compare:Target.compare
    |> assert_equal
         ~printer:(List.to_string ~f:Target.show_pretty)
         ~cmp:(List.equal Target.equal)
         expected
  in
  assert_callables
    {|
    class C:
      def foo() -> int:
        ...
    |}
    ~expected:
      [
        Target.Function { name = "test.$toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "$class_toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
      ];
  assert_callables
    ~additional_sources:["placeholder.py", "# pyre-placeholder-stub"]
    {|
      import placeholder
      class C(placeholder.Base):
        def foo() -> int:
          ...
    |}
    ~expected:
      [
        Target.Function { name = "test.$toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "$class_toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
      ];
  assert_callables
    {|
      import unittest
      class C(unittest.case.TestCase):
        def foo() -> int:
          ...
    |}
    ~expected:[];
  assert_callables
    {|
      import pytest
      class C:
        def foo() -> int:
          ...
    |}
    ~expected:
      [
        Target.Function { name = "test.$toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "$class_toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
      ];
  assert_callables
    {|
      import pytest
      def test_int() -> int:
        return 0
      class C:
        def foo() -> int:
          ...
    |}
    ~expected:[];
  assert_callables
    {|
      from pytest import raises
      def test_int() -> int:
        return 0
      class C:
        def foo() -> int:
          ...
    |}
    ~expected:[];
  assert_callables
    {|
      import pytest.raises as throws
      def test_int() -> int:
        return 0
      class C:
        def foo() -> int:
          ...
    |}
    ~expected:[];
  assert_callables
    {|
      import pytest
      class C:
        def foo() -> int:
          ...
        def test_int() -> int:
          return 0
    |}
    ~expected:[];
  assert_callables
    {|
      import foo.pytest
      def test_int() -> int:
        return 0
      class C:
        def foo() -> int:
          ...
    |}
    ~expected:
      [
        Target.Function { name = "test.$toplevel"; kind = Normal };
        Target.Function { name = "test.test_int"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "$class_toplevel"; kind = Normal };
        Target.Method { class_name = "test.C"; method_name = "foo"; kind = Normal };
      ];
  assert_callables
    "pass"
    ~additional_sources:
      [
        ( "stub.pyi",
          {|
            class Toplevel:
              some_field: int
              def foo() -> int:
                ...
          |}
        );
      ]
    ~expected:[Target.Function { name = "test.$toplevel"; kind = Normal }];

  assert_callables
    ~source_filename:"test.pyi"
    {|
      class Toplevel:
        some_field: int
        def foo() -> int:
          ...
    |}
    ~expected:[Target.Method { class_name = "test.Toplevel"; method_name = "foo"; kind = Normal }]


let () = "staticAnalysis" >::: ["callables" >:: test_callables] |> Test.run
