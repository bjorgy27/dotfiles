#!/usr/bin/env python3
"""Read one status report from a Bambu Lab printer in LAN mode.

Bambu printers speak MQTT over TLS on 8883 with a self-signed cert, username
`bblp` and the LAN access code as the password. Subscribing to
`device/<serial>/report` only yields incremental deltas, so we publish a
`pushall` request and wait for the first message that carries the print state.

Implemented against the standard library on purpose: this is the only MQTT
consumer on the machine, so it isn't worth a system package. If python-paho-mqtt
ever lands here for another reason, this can be swapped for ~20 lines using it.

Prints one JSON object (the `print` sub-object of the report) on stdout, or
exits non-zero with a short message on stderr.
"""

import json
import os
import socket
import ssl
import struct
import sys
import time

CONNECT, CONNACK, PUBLISH, SUBSCRIBE, SUBACK, PINGREQ = 1, 2, 3, 8, 9, 12


def _remaining_length(n):
    out = bytearray()
    while True:
        byte = n % 128
        n //= 128
        if n:
            byte |= 0x80
        out.append(byte)
        if not n:
            return bytes(out)


def _packet(kind, flags, payload):
    return bytes([(kind << 4) | flags]) + _remaining_length(len(payload)) + payload


def _string(value):
    raw = value.encode()
    return struct.pack("!H", len(raw)) + raw


def _connect(user, password, client_id):
    payload = _string("MQTT") + bytes([4, 0xC0]) + struct.pack("!H", 60)
    payload += _string(client_id) + _string(user) + _string(password)
    return _packet(CONNECT, 0, payload)


def _subscribe(topic):
    return _packet(SUBSCRIBE, 2, struct.pack("!H", 1) + _string(topic) + b"\x00")


def _publish(topic, body):
    return _packet(PUBLISH, 0, _string(topic) + body.encode())


class Reader:
    """Buffered reader for MQTT control packets."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def _fill(self, want):
        while len(self.buf) < want:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("printer closed the connection")
            self.buf += chunk

    def packet(self):
        self._fill(1)
        header = self.buf[0]
        length, shift, offset = 0, 0, 1
        while True:
            self._fill(offset + 1)
            byte = self.buf[offset]
            length += (byte & 0x7F) << shift
            offset += 1
            if not byte & 0x80:
                break
            shift += 7
        self._fill(offset + length)
        body = self.buf[offset:offset + length]
        self.buf = self.buf[offset + length:]
        return header >> 4, body


def fetch(host, serial, code, timeout=8.0):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    deadline = time.monotonic() + timeout
    raw = socket.create_connection((host, 8883), timeout=timeout)
    sock = context.wrap_socket(raw)
    try:
        sock.sendall(_connect("bblp", code, "quickshell-%d" % os.getpid()))
        reader = Reader(sock)

        kind, body = reader.packet()
        if kind != CONNACK:
            raise ConnectionError("expected a connection acknowledgement")
        if len(body) < 2 or body[1] != 0:
            raise PermissionError("printer rejected the access code")

        sock.sendall(_subscribe("device/%s/report" % serial))
        kind, _ = reader.packet()
        if kind != SUBACK:
            raise ConnectionError("printer refused the status subscription")

        sock.sendall(_publish(
            "device/%s/request" % serial,
            json.dumps({"pushing": {"sequence_id": "1", "command": "pushall"}}),
        ))

        while time.monotonic() < deadline:
            sock.settimeout(max(0.5, deadline - time.monotonic()))
            kind, body = reader.packet()
            if kind != PUBLISH:
                continue
            topic_len = struct.unpack("!H", body[:2])[0]
            payload = body[2 + topic_len:]
            try:
                report = json.loads(payload).get("print", {})
            except ValueError:
                continue
            # Deltas omit mc_percent; the pushall snapshot carries it.
            if "mc_percent" in report or "gcode_state" in report:
                return report
        raise TimeoutError("printer sent no status in time")
    finally:
        sock.close()


def main():
    host, serial, code = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        print(json.dumps(fetch(host, serial, code)))
    except Exception as exc:  # one line, consumed by bambupoll.sh
        sys.stderr.write(str(exc) or exc.__class__.__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
