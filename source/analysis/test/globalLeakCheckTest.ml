(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Analysis
open Test

let run_check_module
    ~type_environment
    ({ Ast.Source.module_path = { Ast.ModulePath.qualifier; _ }; _ } as source)
  =
  source
  |> Preprocessing.defines ~include_toplevels:false ~include_nested:true
  |> List.map ~f:(GlobalLeakCheck.check_define ~type_environment ~qualifier)
  |> List.concat


let assert_global_leak_errors ~context =
  let check ~environment ~source =
    run_check_module ~type_environment:(TypeEnvironment.read_only environment) source
  in
  assert_errors ~context ~check


let test_global_assignment context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors {|
      def foo():
         x = y
    |} [];
  assert_global_leak_errors {|
      my_global: int = 1
      def foo():
        x = 1
    |} [];
  assert_global_leak_errors
    (* my_global here is not actually a global, this is a valid assignment *)
    {|
      my_global: int = 1
      def foo():
        my_global = 2
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        non_local = 2
        def inner():
          non_local = 3
        inner()
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_global = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_global, y = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        x, my_global = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        (my_global, my_global), my_global = (1, 2), 3
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global`.";
      "Global leak [3100]: Data is leaked to global `test.my_global`.";
      "Global leak [3100]: Data is leaked to global `test.my_global`.";
    ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        def inner():
          global my_global
          my_global = 2
        inner()
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         if my_global := 0:
           pass
    |}
    [ (* TODO (T142189949): leaks should be detected on walrus operator assignment to globals *) ];

  ()


let test_list_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global.append(123)
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global[0] = 123
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def insert_global_list() -> None:
        my_global.insert(0, 1)
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def extend_global_list() -> None:
        local_list = [1]
        my_global.extend(local_list)
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def iadd_global_list() -> None:
        global global_list
        global_list += [1]
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        (my_global[0], y) = 123, 456
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];

  ()


let test_dict_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_global["x"] = 1
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def update_global_dict() -> None:
        local_dict = {1: "a", 2: "b"}
        my_global.update(local_dict)
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def setdefault_global_dict() -> None:
        global_dict.setdefault(1, "a")
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def union_update_global_dict() -> None:
        global my_global
        local_dict = {1: "a", 2: "b"}
        my_global |= local_dict
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        (my_global["x"], y) = 1, 2
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];

  ()


let test_set_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def add_global_set() -> None:
        my_global.add(1)
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def update_my_global() -> None:
        my_global.update({15})
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def ior_my_global() -> None:
        global my_global
        my_global |= {1, 2, 3}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def intersection_update_my_global() -> None:
        my_global.intersection_update({50, 23})
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def iand_my_global() -> None:
        global my_global
        my_global &= {50, 23}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def difference_update_my_global() -> None:
        my_global.difference_update({39, 180})
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def isub_my_global() -> None:
        global my_global
        my_global -= {39, 180}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def symmetric_difference_update_my_global() -> None:
        my_global.symmetric_difference_update({1, 2, 3})
    |}
    [ (* TODO (T142189949): leaks should be detected for global mutable function calls *) ];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def ixor_my_global() -> None:
        global my_global
        my_global ^= {1, 2, 3}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global`."];

  ()


let test_object_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass(1)

      def foo():
        my_global.x = 2
    |}
    [ (* TODO (T142189949): leaks should be detected on object attribute mutations *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

        def set_x(x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass(1)

      def foo():
        my_global.set_x(2)
    |}
    [ (* TODO (T142189949): leaks should be detected on object attribute mutations *) ];
  assert_global_leak_errors
    {|
    class MyClass:
      x: int
      def __init__(self, x: int) -> None:
        self.x = x

    def foo():
      MyClass.x = 2
    |}
    [ (* TODO (T142189949): leaks should be detected on class attribute mutations *) ];

  ()


let test_invalid_global_statements context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        return my_global
    |}
    [ (* TODO (T142189949): a global should not be able to be returned by a function *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         y = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected on global assignment to a local variable *) ];
  (* TODO (T142189949): leaks should be detected on global assignment to a local variable through
     tuple deconstruction *)
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         x, y = my_global, 1
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_list = []
        my_list.append(my_global)
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_dict = {}
        my_dict["my_global"] = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_dict = {}
        my_dict[my_global] = "my_global"
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_set = set()
        my_set.add(my_global)
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: int = 1

      def foo():
        my_obj = MyClass()
        my_obj.x = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: int = 1

      def foo():
        MyClass().x = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass()

      def foo():
        my_local = my_global.x
    |}
    [ (* TODO (T142189949): should this be allowed? *) ];

  ()


let () =
  "global_leaks"
  >::: [
         "global_assignment" >:: test_global_assignment;
         "list_global_leaks" >:: test_list_global_leaks;
         "dict_global_leaks" >:: test_dict_global_leaks;
         "set_global_leaks" >:: test_set_global_leaks;
         "object_global_leaks" >:: test_object_global_leaks;
         "invalid_global_statements" >:: test_invalid_global_statements;
       ]
  |> Test.run
