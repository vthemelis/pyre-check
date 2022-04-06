# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-unsafe

from types import TracebackType
from typing import (
    Any,
    BinaryIO,
    Dict,
    Iterable,
    Iterator,
    List,
    Optional,
    overload,
    Tuple,
    Type,
    TypeVar,
    Union,
)

from django.contrib.sessions.backends.base import SessionBase

class HttpRequest(BinaryIO):
    def __init__(self) -> None: ...
    COOKIES: Any = ...
    DEVICE_LANGUAGE_CODE: Any = ...
    FILES: Any = ...
    GET: QueryDict = ...
    LANGUAGE_CODE: Any = ...
    META: Dict[str, str] = ...
    POST: QueryDict = ...
    REQUEST: Any = ...
    _body: Any = ...

    _cached_carrier_id: Any = ...
    _cached_carrier_name: Any = ...
    _cached_cdn_prefix: Any = ...
    _cached_wallet_defs: Any = ...

    _read_started: Any = ...
    _slipstream_user_id: Any = ...
    _slipstream_view_name: Any = ...
    _wide_color_enabled: Any = ...
    accepted_lang_header: Any = ...
    akamai_migration: Any = ...
    allow_all_request_sources: Any = ...
    app_id: Any = ...
    app_platform: Any = ...
    app_version: Any = ...
    asns: Any = ...
    body: Any = ...
    bypass_cookie_refresh: Any = ...
    cached_carrier_name: Any = ...
    carrier_id: Any = ...
    client_ip: Any = ...
    connection_quality: Any = ...
    context: Any = ...
    count_followed_by: Any = ...
    count_follows: Any = ...
    country_code: Any = ...
    display: Any = ...
    edge_vip: Any = ...
    request_timeout: float = ...
    is_direct_app: Any = ...
    is_image_low_data_mode: Any = ...
    is_prelease_eligible: Any = ...
    is_video_low_data_mode: Any = ...
    locale_lower_case: Any = ...
    locale: Any = ...
    login_os: Any = ...
    login_required_middleware_csrf: Any = ...
    machineid_cookie: Any = ...
    maybe_log_rest_sample: Any = ...
    method: Any = ...
    network_info: Any = ...
    os_version: Any = ...
    overwrite_app_platform: Any = ...
    path_info: Any = ...
    path: Any = ...
    platform_details: Any = ...
    remote_ip: Any = ...
    request_origin: Any = ...
    request_uuid: Any = ...
    resolver_match: Any = ...
    scheme: str = ...
    session: SessionBase = ...
    slipstream: Any = ...
    source: Any = ...
    ua_string_md5: Any = ...
    started_at: Any = ...
    user_agent_string: Any = ...
    user_agent: Any = ...
    user: Any = ...
    via_headers: Any = ...
    view_module: Any = ...
    view_name: Any = ...
    def build_absolute_uri(self, location: Optional[str] = ...) -> str: ...
    def get_full_path(self) -> str: ...
    def get_host(self) -> str: ...
    def get_signed_cookie(
        self, key: str, default: Any = ..., salt: str = ..., max_age: Any = ...
    ) -> str: ...
    def is_ajax(self) -> bool: ...
    # Instantiations of abstract methods in typeshed.
    @overload
    def write(self, s: bytearray) -> int: ...
    @overload
    def write(self, s: bytes) -> int: ...
    def __enter__(self) -> "HttpRequest": ...
    def __exit__(
        self,
        t: Optional[Type[BaseException]],
        value: Optional[BaseException],
        traceback: Optional[TracebackType],
    ) -> Optional[bool]: ...
    def __repr__(self) -> str: ...
    def __iter__(self) -> Iterator[bytes]: ...
    def __next__(self) -> bytes: ...
    def close(self) -> None: ...
    def fileno(self) -> int: ...
    def flush(self) -> None: ...
    def isatty(self) -> bool: ...
    def read(self, n: int = ...) -> bytes: ...
    def readable(self) -> bool: ...
    def readline(self, limit: int = ...) -> bytes: ...
    def readlines(self, hint: int = ...) -> List[bytes]: ...
    def seek(self, offset: int, whence: int = ...) -> int: ...
    def seekable(self) -> bool: ...
    def tell(self) -> int: ...
    def truncate(self, size: Optional[int] = ...) -> int: ...
    def writable(self) -> bool: ...
    def writelines(self, lines: Iterable[bytes]) -> None: ...

_T = TypeVar("_T")

class QueryDict(Dict[str, str]):
    def __init__(
        self,
        query_string: Optional[str] = ...,
        mutable: bool = ...,
        encoding: Any = ...,
    ) -> None: ...
    def lists(self) -> List[Tuple[str, Tuple[str, ...]]]: ...
    def copy(self) -> QueryDict: ...
    def urlencode(self, safe: Optional[str] = None) -> str: ...
    def getlist(self, key: str, default: _T = None) -> Union[List, _T]: ...
    def dict(self) -> Dict: ...

def build_request_repr(
    request: HttpRequest,
    path_override: Any = ...,
    GET_override: Any = ...,
    POST_override: Any = ...,
    COOKIES_override: Any = ...,
    META_override: Any = ...,
) -> str: ...

class RawPostDataException(Exception): ...
