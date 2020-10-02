# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import argparse
import logging
import sys
import traceback
from logging import Logger

from ...client.commands import ExitCode
from . import UserError
from .ast import UnstableAST
from .commands.codemods import (
    EnableSourceDatabaseBuckBuilder,
    MissingGlobalAnnotations,
    MissingOverrideReturnAnnotations,
)
from .commands.consolidate_nested_configurations import ConsolidateNestedConfigurations
from .commands.expand_target_coverage import ExpandTargetCoverage
from .commands.fixme import Fixme
from .commands.fixme_all import FixmeAll
from .commands.fixme_single import FixmeSingle
from .commands.fixme_targets import FixmeTargets
from .commands.global_version_update import GlobalVersionUpdate
from .commands.strict_default import StrictDefault
from .commands.support_sqlalchemy import SupportSqlalchemy
from .commands.targets_to_configuration import TargetsToConfiguration
from .repository import Repository


LOG: Logger = logging.getLogger(__name__)


def run(repository: Repository) -> None:
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging")

    commands = parser.add_subparsers()

    # Subcommands: Codemods
    missing_overridden_return_annotations = commands.add_parser(
        "missing-overridden-return-annotations",
        help="Add annotations according to errors inputted through stdin.",
    )
    MissingOverrideReturnAnnotations.add_arguments(
        missing_overridden_return_annotations
    )

    missing_global_annotations = commands.add_parser(
        "missing-global-annotations",
        help="Add annotations according to errors inputted through stdin.",
    )
    MissingGlobalAnnotations.add_arguments(missing_global_annotations)

    # Subcommand: Change default pyre mode to strict and adjust module headers.
    strict_default = commands.add_parser("strict-default")
    StrictDefault.add_arguments(strict_default)

    # Subcommand: Set global configuration to given hash, and add version override
    # to all local configurations to run previous version.
    update_global_version = commands.add_parser("update-global-version")
    GlobalVersionUpdate.add_arguments(update_global_version)

    # Subcommand: Fixme all errors inputted through stdin.
    fixme = commands.add_parser("fixme")
    Fixme.add_arguments(fixme)

    # Subcommand: Fixme all errors for a single project.
    fixme_single = commands.add_parser("fixme-single")
    FixmeSingle.add_arguments(fixme_single)

    # Subcommand: Fixme all errors in all projects with local configurations.
    fixme_all = commands.add_parser("fixme-all")
    FixmeAll.add_arguments(fixme_all)

    # Subcommand: Fixme all errors in targets running type checking
    fixme_targets = commands.add_parser("fixme-targets")
    FixmeTargets.add_arguments(fixme_targets)

    # Subcommand: Remove targets integration and replace with configuration
    targets_to_configuration = commands.add_parser("targets-to-configuration")
    TargetsToConfiguration.add_arguments(targets_to_configuration)

    # Subcommand: Expand target coverage in configuration up to given error limit
    expand_target_coverage = commands.add_parser("expand-target-coverage")
    ExpandTargetCoverage.add_arguments(expand_target_coverage)

    # Subcommand: Consolidate nested local configurations
    consolidate_nested_configurations = commands.add_parser("consolidate-nested")
    ConsolidateNestedConfigurations.add_arguments(consolidate_nested_configurations)

    enable_source_database_buck_builder = commands.add_parser(
        "enable-source-database-buck-builder"
    )
    EnableSourceDatabaseBuckBuilder.add_arguments(enable_source_database_buck_builder)

    support_sqlalchemy = commands.add_parser("support-sqlalchemy")
    SupportSqlalchemy.add_arguments(support_sqlalchemy)

    # Initialize default values.
    arguments = parser.parse_args()
    if not hasattr(arguments, "command"):
        # Reparsing with `fixme` as default subcommand.
        arguments = parser.parse_args(sys.argv[1:] + ["fixme"])

    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        level=logging.DEBUG if arguments.verbose else logging.INFO,
    )

    try:
        exit_code = ExitCode.SUCCESS
        arguments.command(arguments, repository).run()
    except UnstableAST as error:
        LOG.error(str(error))
        exit_code = ExitCode.FOUND_ERRORS
    except UserError as error:
        LOG.error(str(error))
        exit_code = ExitCode.FAILURE
    except Exception as error:
        LOG.error(str(error))
        LOG.debug(traceback.format_exc())
        exit_code = ExitCode.FAILURE

    sys.exit(exit_code)


def main() -> None:
    run(Repository())


if __name__ == "__main__":
    main()
