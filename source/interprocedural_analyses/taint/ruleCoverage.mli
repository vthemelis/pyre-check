(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module CoveredRule : sig
  type t = {
    rule_code: int;
    kind_coverage: KindCoverage.t;
  }
  [@@deriving eq, show]

  val is_covered : kind_coverage:KindCoverage.t -> Rule.t -> t option

  module Set : Data_structures.SerializableSet.S with type elt = t
end

module IntSet : Stdlib.Set.S with type elt = Int.t

type t = {
  covered_rules: CoveredRule.Set.t;
  uncovered_rule_codes: IntSet.t;
}
[@@deriving eq, show]

val empty : t

val from_rules : kind_coverage:KindCoverage.t -> Rule.t list -> t

val write_to_file : path:PyrePath.t -> t -> unit
