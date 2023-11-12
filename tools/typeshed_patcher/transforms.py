# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
This module provides libcst transform classes for applying various
stub patches to open-source typeshed stubs.
"""
from __future__ import annotations

from typing import Protocol, Sequence

import libcst
import libcst.codemod

from . import patch


def statements_from_content(content: str) -> Sequence[libcst.BaseStatement]:
    """
    Given a content string (originating from a patch toml file),
    parse statements as a CST so that we can apply them in a
    libcst transform.
    """
    module = libcst.parse_module(content)
    return module.body


class ParentScopePatcher(Protocol):
    def __call__(
        self,
        existing_body: Sequence[libcst.BaseStatement],
    ) -> Sequence[libcst.BaseStatement]:
        ...


class PatchTransform(libcst.codemod.ContextAwareTransformer):

    CONTEXT_KEY = "PatchTransform"

    parent: str
    current_names: list[str]
    found_parent: bool

    def __init__(
        self,
        parent: patch.QualifiedName,
        parent_scope_patcher: ParentScopePatcher,
    ) -> None:
        super().__init__(libcst.codemod.CodemodContext())
        self.parent_scope_patcher = parent_scope_patcher
        # State to track current scope name and find the parent
        self.parent = parent.to_string()
        self.current_names = []
        self.found_parent = False

    def get_current_name(self) -> str:
        return ".".join(self.current_names)

    def pop_current_name(self) -> str:
        this_name = self.get_current_name()
        self.current_names.pop()
        return this_name

    def is_parent(self, current_name: str) -> bool:
        if current_name == self.parent:
            if self.found_parent:
                raise ValueError(f"Encountered two classes with name {self.parent}")
            else:
                self.found_parent = True
            return True
        else:
            return False

    def visit_ClassDef(
        self,
        node: libcst.ClassDef,
    ) -> None:
        self.current_names.append(node.name.value)

    def transform_parent_class(
        self,
        node: libcst.ClassDef,
    ) -> libcst.ClassDef:
        """
        Add statements to a class body.

        This update code has to cope with LibCST's need to to distinguish
        between indented vs non-indented bodies. As a result, there are two
        layers of bodies to deal with. Moreover, if the outer body is not
        indented then we will need to coerce the body to be indented
        before adding statements.
        """
        outer_body = node.body
        if isinstance(outer_body, libcst.IndentedBlock):
            new_outer_body = outer_body.with_changes(
                body=self.parent_scope_patcher(outer_body.body)
            )
        else:
            inner_body_as_base_statements = [
                statement
                if isinstance(statement, libcst.BaseStatement)
                else libcst.SimpleStatementLine(body=[statement])
                for statement in outer_body.body
            ]
            new_outer_body = libcst.IndentedBlock(
                body=self.parent_scope_patcher(inner_body_as_base_statements)
            )
        return node.with_changes(body=new_outer_body)

    def leave_ClassDef(
        self,
        original_node: libcst.ClassDef,
        updated_node: libcst.ClassDef,
    ) -> libcst.ClassDef:
        current_name = self.pop_current_name()
        if self.is_parent(current_name):
            return self.transform_parent_class(updated_node)
        else:
            return updated_node

    def transform_parent_module(
        self,
        node: libcst.Module,
    ) -> libcst.Module:
        return node.with_changes(body=self.parent_scope_patcher(node.body))

    def leave_Module(
        self,
        original_node: libcst.Module,
        updated_node: libcst.Module,
    ) -> libcst.Module:
        if self.is_parent(self.get_current_name()):
            out = self.transform_parent_module(updated_node)
        else:
            out = updated_node
        if not self.found_parent:
            raise ValueError(f"Did not find any classes matching {self.parent}")
        return out


class AddTransform(PatchTransform):
    def __init__(
        self,
        parent: patch.QualifiedName,
        content: str,
        add_position: patch.AddPosition,
    ) -> None:
        def patch_parent_body(
            existing_body: Sequence[libcst.BaseStatement],
        ) -> Sequence[libcst.BaseStatement]:
            statements_to_add = statements_from_content(content)
            if add_position == patch.AddPosition.TOP_OF_SCOPE:
                return [
                    *statements_to_add,
                    *existing_body,
                ]
            elif add_position == patch.AddPosition.BOTTOM_OF_SCOPE:
                return [
                    *existing_body,
                    *statements_to_add,
                ]
            else:
                raise RuntimeError(f"Unexpected add_position value {add_position}")

        super().__init__(
            parent=parent,
            parent_scope_patcher=patch_parent_body,
        )


def matches_name(
    name: str,
    statement: libcst.BaseStatement | libcst.BaseSmallStatement,
) -> bool:
    """
    Given a statement in the parent scope, determine whether it
    matches the name (used for delete and replace actions).

    Note that we don't match all possible forms - for example
    currently definitions inside of an if-block will be skipped.
    As a result it is important that transform classes always
    verify that they found their target name and raise otherwise,
    so that we'll be alerted if the code needs to be generalized.
    """
    if isinstance(statement, libcst.SimpleStatementLine):
        if len(statement.body) != 1:
            raise ValueError(
                f"Did not expect compound statement line {statement} "
                "in a stub scope we patch."
            )
        return matches_name(name, statement.body[0])
    if isinstance(statement, libcst.AnnAssign):
        target = statement.target
        if isinstance(target, libcst.Name):
            return target.value == name
        else:
            raise ValueError(
                "Did not expect non-name target {target} "
                "of AnnAssign in a stub scope we patch."
            )
    if isinstance(statement, libcst.FunctionDef):
        return statement.name.value == name
    if isinstance(statement, libcst.ClassDef):
        return statement.name.value == name
    # Note: we currently don't support a number of more complex
    # cases, such as patching inside an if block.
    else:
        return False


class DeleteTransform(PatchTransform):
    def __init__(
        self,
        parent: patch.QualifiedName,
        name: str,
    ) -> None:
        def patch_parent_body(
            existing_body: Sequence[libcst.BaseStatement],
        ) -> Sequence[libcst.BaseStatement]:
            new_body = [
                statement
                for statement in existing_body
                if not matches_name(name, statement)
            ]
            # Always make sure we successfully deleted the target. This
            # might fail if the target has disappeared, or if our
            # `matches_name` logic needs to be extended.
            if len(new_body) == len(existing_body):
                raise ValueError(f"Could not find deletion target {name} in {parent}")
            # There's an edge case where we delete the entire scope body;
            # we can deal with this by inserting a pass.
            if len(new_body) == 0:
                new_body = [libcst.SimpleStatementLine([libcst.Pass()])]
            return new_body

        super().__init__(
            parent=parent,
            parent_scope_patcher=patch_parent_body,
        )


def run_transform(code: str, transform: PatchTransform) -> str:
    original_module = libcst.parse_module(code)
    transformed_module = transform.transform_module(original_module)
    return transformed_module.code
