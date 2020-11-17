# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import abc
import asyncio
import contextlib
import sys
from pathlib import Path
from typing import AsyncIterator, Tuple, Optional


class BytesReader(abc.ABC):
    """
    This class defines the basic interface for async I/O input channel.
    """

    @abc.abstractmethod
    async def read_until(self, separator: bytes = b"\n") -> bytes:
        """
        Read data from the stream until `separator` is found.
        If EOF is reached before the complete separator is found, raise
        `asyncio.IncompleteReadError`.
        """
        raise NotImplementedError

    @abc.abstractmethod
    async def read_exactly(self, count: int) -> bytes:
        """
        Read exactly `count` bytes.
        If EOF is reached before the complete separator is found, raise
        `asyncio.IncompleteReadError`.
        """
        raise NotImplementedError

    async def readline(self) -> bytes:
        """
        Read one line, where "line" is a sequence of bytes ending with '\n'.
        If EOF is received and '\n' was not found, the method returns partially
        read data.
        """
        try:
            return await self.read_until(b"\n")
        except asyncio.IncompleteReadError as error:
            return error.partial


class BytesWriter(abc.ABC):
    """
    This class defines the basic interface for async I/O output channel.
    """

    @abc.abstractmethod
    async def write(self, data: bytes) -> None:
        """
        The method attempts to write the data to the underlying channel and
        flushes immediately.
        """
        raise NotImplementedError

    @abc.abstractmethod
    async def close(self) -> None:
        """
        The method closes the underlying channel and wait until the channel is
        fully closed.
        """
        raise NotImplementedError


class TextReader:
    """
    An adapter for `BytesReader` that decodes everything it reads immediately
    from bytes to string. In other words, it tries to expose the same interfaces
    as `BytesReader` except it operates on strings rather than bytestrings.
    """

    bytes_reader: BytesReader
    encoding: str

    def __init__(self, bytes_reader: BytesReader, encoding: str = "utf-8") -> None:
        self.bytes_reader = bytes_reader
        self.encoding = encoding

    async def read_until(self, separator: str = "\n") -> str:
        separator_bytes = separator.encode(self.encoding)
        result_bytes = await self.bytes_reader.read_until(separator_bytes)
        return result_bytes.decode(self.encoding)

    async def read_exactly(self, count: int) -> str:
        result_bytes = await self.bytes_reader.read_exactly(count)
        return result_bytes.decode(self.encoding)

    async def readline(self) -> str:
        result_bytes = await self.bytes_reader.readline()
        return result_bytes.decode(self.encoding)


class TextWriter:
    """
    An adapter for `BytesWriter` that encodes everything it writes immediately
    from string to bytes. In other words, it tries to expose the same interfaces
    as `BytesWriter` except it operates on strings rather than bytestrings.
    """

    bytes_writer: BytesWriter
    encoding: str

    def __init__(self, bytes_writer: BytesWriter, encoding: str = "utf-8") -> None:
        self.bytes_writer = bytes_writer
        self.encoding = encoding

    async def write(self, data: str) -> None:
        data_bytes = data.encode(self.encoding)
        await self.bytes_writer.write(data_bytes)


class _StreamBytesReader(BytesReader):
    """
    An implementation of `BytesReader` based on `asyncio.StreamReader`.
    """

    stream_reader: asyncio.StreamReader

    def __init__(self, stream_reader: asyncio.StreamReader) -> None:
        self.stream_reader = stream_reader

    async def read_until(self, separator: bytes = b"\n") -> bytes:
        return await self.stream_reader.readuntil(separator)

    async def read_exactly(self, count: int) -> bytes:
        return await self.stream_reader.readexactly(count)


class _StreamBytesWriter(BytesWriter):
    """
    An implementation of `BytesWriter` based on `asyncio.StreamWriter`.
    """

    stream_writer: asyncio.StreamWriter

    def __init__(self, stream_writer: asyncio.StreamWriter) -> None:
        self.stream_writer = stream_writer

    async def write(self, data: bytes) -> None:
        self.stream_writer.write(data)
        await self.stream_writer.drain()

    async def close(self) -> None:
        self.stream_writer.close()
        await self.stream_writer.wait_closed()


@contextlib.asynccontextmanager
async def connect(socket_path: Path) -> AsyncIterator[Tuple[BytesReader, BytesWriter]]:
    """
    Connect to the socket at given path. Once connected, create an input and
    an output stream from the socket. Both the input stream and the output
    stream are in raw binary mode. The API is intended to be used like this:

    ```
    async with connect(socket_path) as (input_stream, output_stream):
        # Read from input_stream and write into output_stream here
        ...
    ```

    Socket creation, connection, and closure will be automatically handled
    inside this context manager. If any of the socket operations fail, raise
    `OSError` just like what the underlying socket API would do.
    """
    writer: Optional[BytesWriter] = None
    try:
        stream_reader, stream_writer = await asyncio.open_unix_connection(
            str(socket_path)
        )
        reader = _StreamBytesReader(stream_reader)
        writer = _StreamBytesWriter(stream_writer)
        yield reader, writer
    finally:
        if writer is not None:
            await writer.close()


@contextlib.asynccontextmanager
async def connect_in_text_mode(
    socket_path: Path,
) -> AsyncIterator[Tuple[TextReader, TextWriter]]:
    """
    This is a line-oriented higher-level API than `connect`. It can be used
    when the caller does not want to deal with the complexity of binary I/O.

    The behavior is the same as `connect`, except the streams that are created
    operates in text mode. Read/write APIs of the streams uses UTF-8 encoded
    `str` instead of `bytes`.
    """
    async with connect(socket_path) as (bytes_reader, bytes_writer):
        yield (
            TextReader(bytes_reader, encoding="utf-8"),
            TextWriter(bytes_writer, encoding="utf-8"),
        )


async def create_async_stdin_stdout() -> Tuple[TextReader, TextWriter]:
    """
    By default, `sys.stdin` and `sys.stdout` are synchronous channels: reading
    from `sys.stdin` or writing to `sys.stdout` will block until the read/write
    succeed, which is very different from the async socket channels created via
    `connect` or `connect_in_text_mode`.

    This function creates wrappers around `sys.stdin` and `sys.stdout` and makes
    them behave in the same way as other async socket channels. This makes it
    easier to write low-level-I/O-agonstic code, where the high-level logic does
    not need to worry about whether the underlying async I/O channel comes from
    sockets or from stdin/stdout.
    """
    loop = asyncio.get_event_loop()
    stream_reader = asyncio.StreamReader(loop=loop)
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(stream_reader), sys.stdin
    )
    w_transport, w_protocol = await loop.connect_write_pipe(
        asyncio.streams.FlowControlMixin, sys.stdout
    )
    stream_writer = asyncio.StreamWriter(w_transport, w_protocol, stream_reader, loop)
    return (
        TextReader(_StreamBytesReader(stream_reader)),
        TextWriter(_StreamBytesWriter(stream_writer)),
    )
