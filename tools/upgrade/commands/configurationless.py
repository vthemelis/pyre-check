# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import argparse
import logging
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Collection, List, Optional, Set

from .. import filesystem
from ..configuration import Configuration
from ..repository import Repository
from .command import Command

LOG: logging.Logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ConfigurationlessOptions:
    global_configuration: Configuration
    local_configuration: Configuration

    @property
    def ignore_all_errors_prefixes(self) -> Collection[Path]:
        return (
            self.global_configuration.get_ignore_path_prefixes()
            | self.local_configuration.get_ignore_path_prefixes()
        )

    @property
    def exclude_patterns(self) -> Collection[re.Pattern[str]]:
        return (
            self.global_configuration.get_exclude_as_patterns()
            | self.local_configuration.get_exclude_as_patterns()
        )

    @property
    def default_global_mode(self) -> filesystem.LocalMode:
        global_is_strict = (
            self.global_configuration.strict
            if self.global_configuration.strict is not None
            else True  # set default configuration strictness to STRICT
        )
        return (
            filesystem.LocalMode.STRICT
            if global_is_strict
            else filesystem.LocalMode.UNSAFE
        )

    @property
    def default_local_mode(self) -> filesystem.LocalMode:
        default_project_strictness_setting = self.local_configuration.strict

        if default_project_strictness_setting is None:
            return self.default_global_mode
        elif default_project_strictness_setting:
            return filesystem.LocalMode.STRICT
        else:
            return filesystem.LocalMode.UNSAFE


class Configurationless(Command):
    def __init__(
        self, *, repository: Repository, path: Path, includes: List[str], commit: bool
    ) -> None:
        super().__init__(repository)
        self._path: Path = path
        self._includes: List[str] = includes
        self._commit: bool = commit

    @staticmethod
    def from_arguments(
        arguments: argparse.Namespace, repository: Repository
    ) -> "Configurationless":
        return Configurationless(
            repository=repository,
            path=arguments.path,
            includes=arguments.include_file_suffixes,
            commit=(not arguments.no_commit),
        )

    @classmethod
    def add_arguments(cls, parser: argparse.ArgumentParser) -> None:
        super(Configurationless, cls).add_arguments(parser)
        parser.set_defaults(command=cls.from_arguments)
        parser.add_argument(
            "path",
            help="Path to project root with local configuration.",
            type=Path,
        )
        parser.add_argument(
            "--no-commit",
            help="Do not commit changes after completing codemod.",
            action="store_true",
        )
        parser.add_argument(
            "--include-file-suffixes",
            action="extend",
            nargs="+",
            type=str,
            default=["**.py"],
            help="The suffixes to search for and include in the codemod. Default is '**.py'.",
        )

    def get_file_mode_to_apply(
        self, file: Path, options: ConfigurationlessOptions
    ) -> Optional[filesystem.LocalMode]:
        file = (self._path / file).absolute()
        default_local_mode = options.default_local_mode
        if any(
            exclude_pattern.search(str(file)) is not None
            for exclude_pattern in options.exclude_patterns
        ):
            # TODO(T174803521): implement `EXCLUDE` LocalMode and return here
            return None
        elif any(
            file.is_relative_to(ignore_prefix)
            for ignore_prefix in options.ignore_all_errors_prefixes
        ):
            return filesystem.LocalMode.IGNORE
        elif default_local_mode == options.default_global_mode:
            return None
        else:
            return default_local_mode

    def _get_buck_root(self) -> Path:
        try:
            root = Path(
                subprocess.check_output(
                    ["buck2", "root"],
                    text=True,
                    cwd=self._path,
                ).strip()
            ).parent
        except FileNotFoundError as e:
            raise ValueError(
                "Could not find `buck2` executable when `targets` were specified in local configuration."
            ) from e
        return root

    def _get_applicable_targets_from_buck(
        self, targets: Collection[str]
    ) -> Collection[str]:
        targets = [
            target_expression
            for target in targets
            for target_expression in ["--target", target]
        ]
        buck_command = [
            "buck2",
            "bxl",
            "prelude//python/sourcedb/query.bxl:query",
            "--",
            *targets,
        ]

        LOG.info(f"Finding included targets with buck2 command: `{buck_command}`")

        result = subprocess.check_output(
            buck_command,
            text=True,
            cwd=self._path,
            shell=True,
        )

        return set(result.split("\n"))

    def _get_files_to_process_from_applicable_targets(
        self, applicable_targets: Collection[str], buck_root: Path
    ) -> Collection[Path]:
        formatted_targets = " ".join([f"{target!r}" for target in applicable_targets])
        buck_command = ["buck2", "uquery", f'"inputs( set( {formatted_targets} ) )"']

        LOG.info(f"Finding included files with buck2 command: `{buck_command}`")

        result = subprocess.check_output(
            buck_command,
            text=True,
            cwd=self._path,
            shell=True,
        )

        return {(buck_root / file.strip()).absolute() for file in result.split("\n")}

    def _get_files_to_migrate_from_targets(
        self, configuration_targets: List[str]
    ) -> Set[Path]:
        buck_root = self._get_buck_root()

        applicable_targets = self._get_applicable_targets_from_buck(
            configuration_targets
        )
        files = self._get_files_to_process_from_applicable_targets(
            applicable_targets, buck_root
        )

        return {
            file
            for file in files
            if file.is_relative_to(self._path)
            and any(file.match(pattern) for pattern in self._includes)
        }

    def _get_files_to_migrate_from_source_directories(
        self, source_directories: List[str]
    ) -> Collection[Path]:
        LOG.info("Finding files with filesystem")
        file_system = filesystem.get_filesystem()

        return {
            Path(file)
            for source_directory in source_directories
            for file in file_system.list(source_directory, patterns=self._includes)
        }

    def get_files_to_migrate(
        self, local_configuration: Configuration
    ) -> Collection[Path]:
        if local_configuration.targets is not None:
            files = self._get_files_to_migrate_from_targets(local_configuration.targets)
        elif local_configuration.source_directories is not None:
            files = self._get_files_to_migrate_from_source_directories(
                local_configuration.source_directories
            )
        else:
            raise ValueError(
                "Could not find `targets` or `source_directories` keys in local configuration"
            )
        return files

    def get_options(
        self,
    ) -> ConfigurationlessOptions:
        global_configuration = Configuration(Configuration.find_project_configuration())
        configuration_path = self._path / ".pyre_configuration.local"
        local_configuration = Configuration(configuration_path)

        if not global_configuration.get_path().exists():
            raise ValueError(
                f"Global configuration found at {str(global_configuration.get_path())}, but path doesn't exist"
            )
        if not local_configuration.get_path().exists():
            raise ValueError(
                f"Local configuration found at {str(local_configuration.get_path())}, but path doesn't exist"
            )

        options = ConfigurationlessOptions(
            global_configuration=global_configuration,
            local_configuration=local_configuration,
        )

        LOG.info(f"Configurationless options:\n{str(options)}")

        return options
