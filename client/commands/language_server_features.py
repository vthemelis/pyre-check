# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
TODO(T132414938) Add a module-level docstring
"""


from __future__ import annotations

import dataclasses
import enum

from typing import Dict, Optional

from .. import configuration as configuration_module

from . import frontend_configuration


class _Availability(enum.Enum):
    ENABLED = "enabled"
    DISABLED = "disabled"

    @staticmethod
    def from_enabled(enabled: bool) -> _Availability:
        return _Availability.ENABLED if enabled else _Availability.DISABLED

    def is_enabled(self) -> bool:
        return self == _Availability.ENABLED

    def is_disabled(self) -> bool:
        return self == _Availability.DISABLED


class _AvailabilityWithShadow(enum.Enum):
    ENABLED = "enabled"
    DISABLED = "disabled"
    SHADOW = "shadow"

    @staticmethod
    def from_enabled(enabled: bool) -> _AvailabilityWithShadow:
        return (
            _AvailabilityWithShadow.ENABLED
            if enabled
            else _AvailabilityWithShadow.DISABLED
        )

    def is_enabled(self) -> bool:
        return self == _AvailabilityWithShadow.ENABLED

    def is_shadow(self) -> bool:
        return self == _AvailabilityWithShadow.SHADOW

    def is_disabled(self) -> bool:
        return self == _AvailabilityWithShadow.DISABLED


class TypeCoverageAvailability(enum.Enum):
    DISABLED = "disabled"
    FUNCTION_LEVEL = "function_level"
    EXPRESSION_LEVEL = "expression_level"


HoverAvailability = _Availability
DefinitionAvailability = _AvailabilityWithShadow
ReferencesAvailability = _Availability
DocumentSymbolsAvailability = _Availability
StatusUpdatesAvailability = _Availability
TypeErrorsAvailability = _Availability
UnsavedChangesAvailability = _Availability


@dataclasses.dataclass(frozen=True)
class LanguageServerFeatures:
    hover: HoverAvailability = HoverAvailability.DISABLED
    definition: DefinitionAvailability = DefinitionAvailability.DISABLED
    document_symbols: DocumentSymbolsAvailability = DocumentSymbolsAvailability.DISABLED
    references: ReferencesAvailability = ReferencesAvailability.DISABLED
    status_updates: StatusUpdatesAvailability = StatusUpdatesAvailability.ENABLED
    type_coverage: TypeCoverageAvailability = TypeCoverageAvailability.DISABLED
    type_errors: TypeErrorsAvailability = TypeErrorsAvailability.ENABLED
    unsaved_changes: UnsavedChangesAvailability = UnsavedChangesAvailability.DISABLED

    @staticmethod
    def create(
        configuration: frontend_configuration.Base,
        hover: Optional[HoverAvailability],
        definition: Optional[DefinitionAvailability],
        document_symbols: Optional[DocumentSymbolsAvailability],
        references: Optional[ReferencesAvailability],
        type_coverage: Optional[TypeCoverageAvailability],
        unsaved_changes: Optional[UnsavedChangesAvailability],
        type_errors: TypeErrorsAvailability = TypeErrorsAvailability.ENABLED,
        status_updates: StatusUpdatesAvailability = StatusUpdatesAvailability.ENABLED,
    ) -> LanguageServerFeatures:
        return LanguageServerFeatures(
            hover=hover or LanguageServerFeatures.hover,
            definition=definition or LanguageServerFeatures.definition,
            document_symbols=document_symbols
            or LanguageServerFeatures.document_symbols,
            references=references or LanguageServerFeatures.references,
            status_updates=status_updates,
            type_coverage=type_coverage or LanguageServerFeatures.type_coverage,
            type_errors=type_errors,
            unsaved_changes=unsaved_changes or LanguageServerFeatures.unsaved_changes,
        )

    def capabilities(self) -> Dict[str, bool]:
        return {
            "hover_provider": not self.hover.is_disabled(),
            "definition_provider": not self.definition.is_disabled(),
            "document_symbol_provider": not self.document_symbols.is_disabled(),
            "references_provider": not self.references.is_disabled(),
        }
