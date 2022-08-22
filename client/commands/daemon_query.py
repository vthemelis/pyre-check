# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import dataclasses

import json
import logging
from pathlib import Path

from . import daemon_connection


LOG: logging.Logger = logging.getLogger(__name__)


class InvalidQueryResponse(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class Response:
    payload: object

    @staticmethod
    def from_json(
        response_json: object,
    ) -> Response:
        if (
            isinstance(response_json, list)
            and len(response_json) > 1
            and response_json[0] == "Query"
        ):
            return Response(response_json[1])
        else:
            raise InvalidQueryResponse(
                f"Unexpected JSON response from server: {response_json}"
            )

    @staticmethod
    def parse(
        response_text: str,
    ) -> Response:
        try:
            response_json = json.loads(response_text)
            return Response.from_json(response_json)
        except json.JSONDecodeError as decode_error:
            message = f"Cannot parse response as JSON: {decode_error}"
            raise InvalidQueryResponse(message) from decode_error


def execute_query(socket_path: Path, query_text: str) -> Response:
    raw_request = json.dumps(["Query", query_text])
    raw_response = daemon_connection.send_raw_request(socket_path, raw_request)
    return Response.parse(raw_response)
