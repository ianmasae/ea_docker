"""Async TCP bridge server for communicating with the BridgeEA inside MT5."""

import asyncio
import json
import struct
import time
import uuid
import logging

logger = logging.getLogger("mt5-bridge")

# 4-byte big-endian length prefix
HEADER_SIZE = 4
DEFAULT_TIMEOUT = 10.0


class MT5Bridge:
    """Manages the TCP connection between FastAPI and the BridgeEA."""

    def __init__(self, host: str = "0.0.0.0", port: int = 15555):
        self.host = host
        self.port = port
        self._server: asyncio.Server | None = None
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._pending: dict[str, asyncio.Future] = {}
        self._connected = False
        self._last_seen: float | None = None
        self._read_task: asyncio.Task | None = None
        self._lock = asyncio.Lock()

    @property
    def connected(self) -> bool:
        return self._connected

    @property
    def last_seen(self) -> float | None:
        return self._last_seen

    async def start(self):
        """Start the TCP server."""
        self._server = await asyncio.start_server(
            self._handle_connection, self.host, self.port
        )
        logger.info(f"TCP bridge listening on {self.host}:{self.port}")

    async def stop(self):
        """Stop the TCP server and close connections."""
        if self._read_task and not self._read_task.done():
            self._read_task.cancel()
        if self._writer:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except Exception:
                pass
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        self._connected = False
        # Cancel all pending futures
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(ConnectionError("Bridge shutting down"))
        self._pending.clear()

    async def _handle_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ):
        """Handle a new EA connection. Only one EA at a time."""
        addr = writer.get_extra_info("peername")
        logger.info(f"EA connected from {addr}")

        # Close previous connection if any
        if self._writer:
            logger.info("Closing previous EA connection")
            if self._read_task and not self._read_task.done():
                self._read_task.cancel()
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except Exception:
                pass

        self._reader = reader
        self._writer = writer
        self._connected = True
        self._last_seen = time.time()

        # Start reading responses in background
        self._read_task = asyncio.create_task(self._read_loop())

    async def _read_loop(self):
        """Continuously read length-prefixed JSON messages from EA."""
        try:
            while True:
                # Read 4-byte length header
                header = await self._reader.readexactly(HEADER_SIZE)
                msg_len = struct.unpack(">I", header)[0]

                if msg_len > 1_000_000:  # 1MB sanity limit
                    logger.error(f"Message too large: {msg_len} bytes")
                    break

                # Read message body
                data = await self._reader.readexactly(msg_len)
                msg = json.loads(data.decode("utf-8"))

                self._last_seen = time.time()

                # Route response to pending future by request ID
                req_id = msg.get("id")
                if req_id and req_id in self._pending:
                    fut = self._pending.pop(req_id)
                    if not fut.done():
                        fut.set_result(msg)
                else:
                    logger.debug(f"Unmatched message: {msg}")

        except asyncio.IncompleteReadError:
            logger.info("EA disconnected (incomplete read)")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Read loop error: {e}")
        finally:
            self._connected = False
            # Fail all pending futures
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("EA disconnected"))
            self._pending.clear()

    async def send_command(
        self, command: str, params: dict | None = None, timeout: float = DEFAULT_TIMEOUT
    ) -> dict:
        """Send a command to the EA and wait for the response."""
        if not self._connected or not self._writer:
            raise ConnectionError("EA not connected")

        req_id = str(uuid.uuid4())
        message = {"id": req_id, "command": command}
        if params:
            message["params"] = params

        # Create future for response
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self._pending[req_id] = fut

        try:
            # Serialize and send with length prefix
            payload = json.dumps(message).encode("utf-8")
            header = struct.pack(">I", len(payload))

            async with self._lock:
                self._writer.write(header + payload)
                await self._writer.drain()

            # Wait for response
            return await asyncio.wait_for(fut, timeout=timeout)

        except asyncio.TimeoutError:
            self._pending.pop(req_id, None)
            raise TimeoutError(f"Command '{command}' timed out after {timeout}s")
        except Exception:
            self._pending.pop(req_id, None)
            raise
