"""Minimal local WebSocket fixture; no credentials or third-party dependencies."""
import base64
import hashlib
import json
import socketserver
import struct
import sys


class Handler(socketserver.StreamRequestHandler):
    def send_event(self, event):
        data = json.dumps(event).encode()
        header = bytes([0x81, len(data)]) if len(data) < 126 else b'\x81\x7e' + struct.pack('!H', len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    def receive_event(self):
        header = self.rfile.read(2)
        if len(header) != 2 or header[0] & 15 == 8:
            return None
        size = header[1] & 127
        if size == 126:
            size = struct.unpack('!H', self.rfile.read(2))[0]
        elif size == 127:
            size = struct.unpack('!Q', self.rfile.read(8))[0]
        mask = self.rfile.read(4)
        payload = self.rfile.read(size)
        return json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def handle(self):
        self.connection.settimeout(10)
        path = self.rfile.readline().decode().split()[1]
        headers = {}
        while (line := self.rfile.readline().decode().strip()):
            name, value = line.split(':', 1)
            headers[name.lower()] = value.strip()
        key = headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
        self.wfile.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
        self.wfile.flush()
        config = self.receive_event()
        assert config == {'type': 'session.configure', 'session': {'model': 'qwen3-asr-fast:free', 'turn_detection': None}}, config
        if path == '/credits':
            self.send_event({'type': 'error', 'error': {'code': 'INSUFFICIENT_CREDITS'}})
            return
        if path == '/cancel':
            assert self.receive_event() is None
            return
        self.send_event({'type': 'session.configured', 'session': {}})
        audio = bytearray()
        while (event := self.receive_event())['type'] == 'input_audio_buffer.append':
            chunk = base64.b64decode(event['audio'], validate=True)
            assert len(chunk) == 3200
            audio.extend(chunk)
        assert len(audio) == 6400 and audio[:6] == b'\0\0\1\0\2\0'
        assert event == {'type': 'input_audio_buffer.commit', 'event_id': 'dictabar_end_of_input'}
        if path == '/credits-final':
            self.send_event({'type': 'error', 'error': {'code': 'INSUFFICIENT_CREDITS'}})
            return
        if path == '/cancel-final':
            assert self.receive_event() is None
            return
        # A duration boundary, out-of-order finals, and an empty end acknowledgement.
        self.send_event({'type': 'input_audio_buffer.committed', 'item_id': 'one'})
        self.send_event({'type': 'transcript.partial', 'item_id': 'one', 'transcript': 'wrong'})
        self.send_event({'type': 'input_audio_buffer.committed', 'item_id': 'two'})
        self.send_event({'type': 'transcript.completed', 'item_id': 'two', 'transcript': 'мир'})
        self.send_event({'type': 'input_audio_buffer.commit_empty', 'client_event_id': 'dictabar_end_of_input'})
        self.send_event({'type': 'transcript.completed', 'item_id': 'one', 'transcript': 'Привет'})


with socketserver.TCPServer(('127.0.0.1', 0), Handler) as server:
    with open(sys.argv[1], 'w') as port_file:
        port_file.write(str(server.server_address[1]))
    server.serve_forever()
