# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import tempfile
import textwrap
from pathlib import Path

import testslide

from ...tests import setup
from ..statistics import (
    aggregate_statistics,
    AggregatedStatisticsData,
    collect_statistics,
    find_module_paths,
    get_paths_to_collect,
)


class StatisticsTest(testslide.TestCase):
    def test_get_paths_to_collect__duplicate_directories(self) -> None:
        self.assertCountEqual(
            get_paths_to_collect(
                [Path("/root/foo.py"), Path("/root/bar.py"), Path("/root/foo.py")],
                local_root=None,
                global_root=Path("/root"),
            ),
            [Path("/root/foo.py"), Path("/root/bar.py")],
        )

        self.assertCountEqual(
            get_paths_to_collect(
                [Path("/root/foo"), Path("/root/bar"), Path("/root/foo")],
                local_root=None,
                global_root=Path("/root"),
            ),
            [Path("/root/foo"), Path("/root/bar")],
        )

    def test_get_paths_to_collect__expand_directories(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root).resolve()  # resolve is necessary on OSX 11.6
            with setup.switch_working_directory(root_path):
                self.assertCountEqual(
                    get_paths_to_collect(
                        [Path("foo.py"), Path("bar.py")],
                        local_root=None,
                        global_root=root_path,
                    ),
                    [root_path / "foo.py", root_path / "bar.py"],
                )

    def test_get_paths_to_collect__invalid_given_subdirectory(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root).resolve()  # resolve is necessary on OSX 11.6
            with setup.switch_working_directory(root_path):
                # this is how a valid call behaves: subdirectory lives under project_root
                self.assertCountEqual(
                    get_paths_to_collect(
                        [Path("project_root/subdirectory")],
                        local_root=None,
                        global_root=root_path / "project_root",
                    ),
                    [root_path / "project_root/subdirectory"],
                )
                # ./subdirectory isn't part of ./project_root
                self.assertRaisesRegex(
                    ValueError,
                    ".* is not nested under the project .*",
                    get_paths_to_collect,
                    [Path("subdirectory")],
                    local_root=None,
                    global_root=root_path / "project_root",
                )
                # ./subdirectory isn't part of ./local_root
                self.assertRaisesRegex(
                    ValueError,
                    ".* is not nested under the project .*",
                    get_paths_to_collect,
                    [Path("subdirectory")],
                    local_root=root_path / "local_root",
                    global_root=root_path,
                )

    def test_get_paths_to_collect__local_root(self) -> None:
        self.assertCountEqual(
            get_paths_to_collect(
                None,
                local_root=Path("/root/local"),
                global_root=Path("/root"),
            ),
            [Path("/root/local")],
        )

    def test_get_paths_to_collect__global_root(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root).resolve()  # resolve is necessary on OSX 11.6
            with setup.switch_working_directory(root_path):
                self.assertCountEqual(
                    get_paths_to_collect(
                        None,
                        local_root=None,
                        global_root=Path("/root"),
                    ),
                    [Path("/root")],
                )

    def test_find_module_paths__basic(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            setup.ensure_files_exist(
                root_path,
                ["s0.py", "a/s1.py", "b/s2.py", "b/c/s3.py", "b/s4.txt", "b/__s5.py"],
            )
            setup.ensure_directories_exists(root_path, ["b/d"])
            self.assertCountEqual(
                find_module_paths(
                    [
                        root_path / "a/s1.py",
                        root_path / "b/s2.py",
                        root_path / "b/s4.txt",
                    ],
                    excludes=[],
                ),
                [
                    root_path / "a/s1.py",
                    root_path / "b/s2.py",
                ],
            )
            self.assertCountEqual(
                find_module_paths([root_path], excludes=[]),
                [
                    root_path / "s0.py",
                    root_path / "a/s1.py",
                    root_path / "b/s2.py",
                    root_path / "b/c/s3.py",
                ],
            )

    def test_find_module_paths__with_exclude(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            setup.ensure_files_exist(
                root_path,
                ["s0.py", "a/s1.py", "b/s2.py", "b/c/s3.py", "b/s4.txt", "b/__s5.py"],
            )
            setup.ensure_directories_exists(root_path, ["b/d"])
            self.assertCountEqual(
                find_module_paths(
                    [
                        root_path / "a/s1.py",
                        root_path / "b/s2.py",
                        root_path / "b/s4.txt",
                    ],
                    excludes=[r".*2\.py"],
                ),
                [
                    root_path / "a/s1.py",
                ],
            )
            self.assertCountEqual(
                find_module_paths(
                    [root_path],
                    excludes=[r".*2\.py"],
                ),
                [
                    root_path / "s0.py",
                    root_path / "a/s1.py",
                    root_path / "b/c/s3.py",
                ],
            )

    def test_collect_statistics(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            setup.ensure_files_exist(root_path, ["foo.py", "bar.py"])
            foo_path = root_path / "foo.py"
            bar_path = root_path / "bar.py"

            data = collect_statistics([foo_path, bar_path], strict_default=False)
            self.assertIn(str(foo_path), data)
            self.assertIn(str(bar_path), data)

    def test_aggregate_statistics__single_file(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            a_path = root_path / "a.py"
            a_path.write_text(
                textwrap.dedent(
                    """
                    # pyre-unsafe

                    def foo():
                        return 1
                    """.rstrip()
                )
            )

            self.assertEqual(
                aggregate_statistics(
                    collect_statistics([a_path], strict_default=False)
                ),
                AggregatedStatisticsData(
                    annotations={
                        "return_count": 1,
                        "annotated_return_count": 0,
                        "globals_count": 0,
                        "annotated_globals_count": 0,
                        "parameter_count": 0,
                        "annotated_parameter_count": 0,
                        "attribute_count": 0,
                        "annotated_attribute_count": 0,
                        "function_count": 1,
                        "partially_annotated_function_count": 0,
                        "fully_annotated_function_count": 0,
                        "line_count": 5,
                    },
                    fixmes=0,
                    ignores=0,
                    strict=0,
                    unsafe=1,
                ),
            )

    def test_aggregate_statistics__multiple_files(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            a_path = root_path / "a.py"
            b_path = root_path / "b.py"
            a_path.write_text(
                textwrap.dedent(
                    """
                    # pyre-unsafe

                    def foo():
                        return 1
                    """.rstrip()
                )
            )
            b_path.write_text(
                textwrap.dedent(
                    """
                    # pyre-strict

                    def foo(x: int) -> int:
                        return 1
                    """.rstrip()
                )
            )

            self.assertEqual(
                aggregate_statistics(
                    collect_statistics([a_path, b_path], strict_default=False)
                ),
                AggregatedStatisticsData(
                    annotations={
                        "return_count": 2,
                        "annotated_return_count": 1,
                        "globals_count": 0,
                        "annotated_globals_count": 0,
                        "parameter_count": 1,
                        "annotated_parameter_count": 1,
                        "attribute_count": 0,
                        "annotated_attribute_count": 0,
                        "function_count": 2,
                        "partially_annotated_function_count": 0,
                        "fully_annotated_function_count": 1,
                        "line_count": 10,
                    },
                    fixmes=0,
                    ignores=0,
                    strict=1,
                    unsafe=1,
                ),
            )
