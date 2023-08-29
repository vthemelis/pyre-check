(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
module BigList = Data_structures.BigList

let exception_to_error ~error ~message ~f =
  try f () with
  | exception_ ->
      Log.error "Error %s:\n%s" message (Exn.to_string exception_);
      Error error


module Usage = struct
  type error =
    | LoadError
    | Stale
  [@@deriving show { with_path = false }]

  type t =
    | Used
    | Unused of error
  [@@deriving show { with_path = false }]
end

module type SingleValueValueType = sig
  type t

  val name : string
end

(* Support storing / loading a single OCaml value into / from the shared memory, for caching
   purposes. *)
module MakeSingleValue (Value : SingleValueValueType) = struct
  let shared_memory_prefix = Hack_parallel.Std.Prefix.make ()

  module T = Memory.Serializer (struct
    type t = Value.t

    module Serialized = struct
      type t = Value.t

      let prefix = shared_memory_prefix

      let description = Value.name
    end

    let serialize = Fn.id

    let deserialize = Fn.id
  end)

  let load () =
    exception_to_error
      ~error:(Usage.Unused Usage.LoadError)
      ~message:(Format.asprintf "Loading %s from cache" Value.name)
      ~f:(fun () ->
        Log.info "Loading %s from cache..." Value.name;
        let value = T.load () in
        Log.info "Loaded %s from cache." Value.name;
        Ok value)


  let save value =
    exception_to_error
      ~error:()
      ~message:(Format.asprintf "Saving %s to cache" Value.name)
      ~f:(fun () ->
        Memory.SharedMemory.collect `aggressive;
        T.store value;
        Log.info "Saved %s to cache." Value.name;
        Ok ())
    |> ignore
end

module type KeyValueValueType = sig
  type t

  val prefix : Hack_parallel.Std.Prefix.t

  val description : string
end

(* Support storing / loading key-value pairs into / from the shared memory. *)
module MakeKeyValue (Key : Hack_parallel.Std.SharedMemory.KeyType) (Value : KeyValueValueType) =
struct
  module FirstClass =
    Hack_parallel.Std.SharedMemory.FirstClass.WithCache.Make
      (Key)
      (struct
        type t = Value.t

        let prefix = Value.prefix

        let description = Value.description
      end)

  (* The table handle and the keys, whose combination locates all entries in the shared memory that
     belong to this table. *)
  module Handle = struct
    type t = {
      first_class_handle: FirstClass.t;
      keys: Key.t BigList.t;
    }
  end

  module KeySet = FirstClass.KeySet

  type t = Handle.t

  let create () = { Handle.first_class_handle = FirstClass.create (); keys = BigList.empty }

  let add { Handle.first_class_handle; keys } key value =
    let keys = BigList.cons key keys in
    let () = FirstClass.add first_class_handle key value in
    { Handle.first_class_handle; keys }


  (* Partially invalidate the shared memory. *)
  let cleanup { Handle.first_class_handle; keys } =
    FirstClass.remove_batch first_class_handle (keys |> BigList.to_list |> FirstClass.KeySet.of_list)


  let of_alist list =
    let save_entry ~first_class_handle (key, value) = FirstClass.add first_class_handle key value in
    let first_class_handle = FirstClass.create () in
    List.iter list ~f:(save_entry ~first_class_handle);
    { Handle.first_class_handle; keys = list |> List.map ~f:fst |> BigList.of_list }


  let to_alist { Handle.first_class_handle; keys } =
    FirstClass.get_batch first_class_handle (keys |> BigList.to_list |> KeySet.of_list)
    |> FirstClass.KeyMap.elements
    |> List.filter_map ~f:(fun (key, value) ->
           match value with
           | Some value -> Some (key, value)
           | None -> None)


  let merge_same_handle
      { Handle.first_class_handle = left_first_class_handle; keys = left_keys }
      { Handle.first_class_handle = right_first_class_handle; keys = right_keys }
    =
    if not (FirstClass.equal left_first_class_handle right_first_class_handle) then
      failwith "Cannot merge with different handles"
    else
      {
        Handle.first_class_handle = left_first_class_handle;
        keys = BigList.merge left_keys right_keys;
      }


  module HandleSharedMemory = MakeSingleValue (struct
    type t = Handle.t

    let name = Format.asprintf "Handle of %s" Value.description
  end)

  let save_to_cache = HandleSharedMemory.save

  let load_from_cache = HandleSharedMemory.load

  module ReadOnly = struct
    type t = FirstClass.t

    let get = FirstClass.get

    let mem = FirstClass.mem
  end

  let read_only { Handle.first_class_handle; _ } = first_class_handle
end
