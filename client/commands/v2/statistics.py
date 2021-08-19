# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import dataclasses
import itertools
import logging
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Iterable, Optional, Sequence, Union

import libcst as cst

from ... import (
    commands,
    command_arguments,
    configuration as configuration_module,
    statistics_collectors as collectors,
)
from . import remote_logging


LOG: logging.Logger = logging.getLogger(__name__)


def find_roots(
    configuration: configuration_module.Configuration,
    statistics_arguments: command_arguments.StatisticsArguments,
) -> Iterable[Path]:
    filter_paths = statistics_arguments.filter_paths
    if len(filter_paths) > 0:

        def to_absolute_path(given: str) -> Path:
            path = Path(given)
            return path if path.is_absolute() else Path.cwd() / path

        return {to_absolute_path(path) for path in filter_paths}

    local_root = configuration.local_root
    if local_root is not None:
        return [Path(local_root)]

    return [Path.cwd()]


def find_paths_to_parse(paths: Iterable[Path]) -> Iterable[Path]:
    def _should_ignore(path: Path) -> bool:
        return path.name.startswith("__") or path.name.startswith(".")

    def _get_paths_for_file(target_file: Path) -> Iterable[Path]:
        return (
            [target_file]
            if target_file.suffix == ".py" and not _should_ignore(target_file)
            else []
        )

    def _get_paths_in_directory(target_directory: Path) -> Iterable[Path]:
        return (
            path
            for path in target_directory.glob("**/*.py")
            if not _should_ignore(path)
        )

    return itertools.chain.from_iterable(
        _get_paths_for_file(path)
        if not path.is_dir()
        else _get_paths_in_directory(path)
        for path in paths
    )


def parse_text_to_module(text: str) -> Optional[cst.Module]:
    try:
        return cst.parse_module(text)
    except cst.ParserSyntaxError:
        return None


def parse_path_to_module(path: Path) -> Optional[cst.Module]:
    try:
        return parse_text_to_module(path.read_text())
    except FileNotFoundError:
        return None


def _collect_statistics_for_modules(
    modules: Mapping[Path, Union[cst.Module, cst.MetadataWrapper]],
    collector_factory: Callable[[], collectors.StatisticsCollector],
) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for path, module in modules.items():
        collector = collector_factory()
        try:
            module.visit(collector)
            result[str(path)] = collector.build_json()
        except RecursionError:
            LOG.warning(f"LibCST encountered recursion error in `{path}`")
    return result


def _collect_annotation_statistics(
    modules: Mapping[Path, cst.Module]
) -> Dict[str, Any]:
    return _collect_statistics_for_modules(
        {path: cst.MetadataWrapper(module) for path, module in modules.items()},
        collectors.AnnotationCountCollector,
    )


def _collect_fixme_statistics(modules: Mapping[Path, cst.Module]) -> Dict[str, Any]:
    return _collect_statistics_for_modules(modules, collectors.FixmeCountCollector)


def _collect_ignore_statistics(modules: Mapping[Path, cst.Module]) -> Dict[str, Any]:
    return _collect_statistics_for_modules(modules, collectors.IgnoreCountCollector)


def _collect_strict_file_statistics(
    modules: Mapping[Path, cst.Module], strict_default: bool
) -> Dict[str, Any]:
    def collector_factory() -> collectors.StrictCountCollector:
        return collectors.StrictCountCollector(strict_default)

    return _collect_statistics_for_modules(modules, collector_factory)


@dataclasses.dataclass(frozen=True)
class StatisticsData:
    annotations: Dict[str, Any] = dataclasses.field(default_factory=dict)
    fixmes: Dict[str, Any] = dataclasses.field(default_factory=dict)
    ignores: Dict[str, Any] = dataclasses.field(default_factory=dict)
    strict: Dict[str, Any] = dataclasses.field(default_factory=dict)


def collect_statistics(sources: Sequence[Path], strict_default: bool) -> StatisticsData:
    modules: Dict[Path, cst.Module] = {}
    for path in sources:
        module = parse_path_to_module(path)
        if module is not None:
            modules[path] = module

    annotation_statistics = _collect_annotation_statistics(modules)
    fixme_statistics = _collect_fixme_statistics(modules)
    ignore_statistics = _collect_ignore_statistics(modules)
    strict_file_statistics = _collect_strict_file_statistics(modules, strict_default)
    return StatisticsData(
        annotations=annotation_statistics,
        fixmes=fixme_statistics,
        ignores=ignore_statistics,
        strict=strict_file_statistics,
    )


def run_statistics(
    configuration: configuration_module.Configuration,
    statistics_arguments: command_arguments.StatisticsArguments,
) -> commands.ExitCode:
    LOG.warning("Coming soon...")
    return commands.ExitCode.SUCCESS


@remote_logging.log_usage(command_name="statistics")
def run(
    configuration: configuration_module.Configuration,
    statistics_arguments: command_arguments.StatisticsArguments,
) -> commands.ExitCode:
    try:
        return run_statistics(configuration, statistics_arguments)
    except Exception as error:
        raise commands.ClientException(
            f"Exception occured during statistics collection: {error}"
        ) from error
