"""Minimal Python client for the COSMOS 4 JSON-RPC 2.0 HTTP API.

A self-contained (stdlib-only) clone of the core of the `ballcosmos`
package: it speaks the same protocol the COSMOS tools use internally
(JSON-RPC 2.0 POSTed to the CmdTlmServer's json_drb port, 7777 by
default), so anything the Ruby Script API can ask for, Python can too.

Usage:

    from cosmos_api import CosmosApi
    api = CosmosApi()                      # localhost API on 127.0.0.1:7777
    api.call('get_target_list')
    api.call('get_tlm_details', [['INST', 'HEALTH_STATUS', 'TEMP1']])
    api.call('get_cmd_details', 'INST', 'COLLECT')
    api.close()                            # or use it as a context manager

The connection is persistent (HTTP keep-alive): one TCP connection is
reused across calls and transparently re-established if the server
drops it. This matters at volume -- a connection-per-request client
leaves one TIME_WAIT ephemeral port behind per call.

Raw (non-UTF8) strings come back the way the Ruby side encodes them:
``{"json_class": "String", "raw": [bytes...]}``; decode_raw() turns those
into Python bytes recursively.
"""

import http.client
import itertools
import json
import os


class CosmosError(Exception):
    """A JSON-RPC error response from the COSMOS server."""

    def __init__(self, code, message, data=None):
        super().__init__(f"COSMOS API error {code}: {message}")
        self.code = code
        self.message = message
        self.data = data


class CosmosApi:
    # The server checks two things (lib/cosmos/io/json_drb_rack.rb): the
    # Host header must be in System.allowed_hosts (default: 127.0.0.1:7777)
    # and X-Csrf-Token must match the system config's X_CSRF_TOKEN (the demo
    # ships "SuperSecret").
    def __init__(self, host="127.0.0.1", port=7777, timeout=10.0,
                 x_csrf_token=None):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.x_csrf_token = (x_csrf_token
                             or os.environ.get("COSMOS_X_CSRF_TOKEN")
                             or "SuperSecret")
        self._ids = itertools.count()
        self._connection = None

    def call(self, method, *params):
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "id": next(self._ids),
        }
        if params:
            request["params"] = list(params)
        body = json.dumps(request)
        headers = {"Content-Type": "application/json-rpc"}
        if self.x_csrf_token:
            headers["X-Csrf-Token"] = self.x_csrf_token

        # One retry: the persistent connection may have been closed by the
        # server (keep-alive idle timeout) between calls.
        for attempt in (1, 2):
            if self._connection is None:
                self._connection = http.client.HTTPConnection(
                    self.host, self.port, timeout=self.timeout)
            try:
                self._connection.request("POST", "/", body=body,
                                         headers=headers)
                response = self._connection.getresponse()
                data = response.read()
                status = response.status
                break
            except (http.client.HTTPException, OSError):
                self.close()
                if attempt == 2:
                    raise

        if status != 200 and not data:
            raise CosmosError(status, f"HTTP {status}")
        payload = json.loads(data.decode("utf-8"))
        if "error" in payload:
            error = payload["error"]
            raise CosmosError(error.get("code"), error.get("message"),
                              error.get("data"))
        return payload.get("result")

    def close(self):
        """Closes the persistent connection (reopened on the next call)."""
        if self._connection is not None:
            try:
                self._connection.close()
            finally:
                self._connection = None

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()


def decode_raw(value):
    """Recursively convert COSMOS raw-string hashes to Python bytes."""
    if isinstance(value, dict):
        if value.get("json_class") == "String" and "raw" in value:
            return bytes(value["raw"])
        return {k: decode_raw(v) for k, v in value.items()}
    if isinstance(value, list):
        return [decode_raw(v) for v in value]
    return value
