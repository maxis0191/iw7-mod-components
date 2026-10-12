"""Paired, read-only prediction/authoritative trace for an owned one-client test.

Explicit PID/image/creation/hash identities and the engine signatures are checked
by Trace-LateJoin. No memory writes, names, endpoints or packet bodies are read.
Sequential process reads are not an atomic client/server snapshot.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import hashlib
import json
import math
from pathlib import Path
import struct
import time

spec = importlib.util.spec_from_file_location('late_join', Path(__file__).with_name('Trace-LateJoin.py'))
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)
CG_POINTER = 0x141FDBEF0
CG_GETTER = 0x140242BF0
CG_GETTER_SHA256 = '2a65e5626ca24a8ec24bd418bb25dc17dcdb81b955e97bd37e5e1f15ada87625'


def validate_prediction_layout(read):
    if hashlib.sha256(read(CG_GETTER, 18)).hexdigest() != CG_GETTER_SHA256:
        raise ValueError('Client globals getter layout changed')


def prediction(read):
    cg = struct.unpack('<Q', read(CG_POINTER, 8))[0]
    if not 0x10000 <= cg < 0x0000800000000000:
        raise ValueError('Invalid client globals pointer')
    ps = cg + 8
    before = struct.unpack('<i', read(ps, 4))[0]
    origin_velocity = struct.unpack('<6f', read(ps + 40, 24))
    if not all(math.isfinite(x) for x in origin_velocity):
        raise ValueError('Non-finite client prediction')
    gravity_speed = list(struct.unpack('<ii', read(ps + 120, 8)))
    after = struct.unpack('<i', read(ps, 4))[0]
    same_binding = cg == struct.unpack('<Q', read(CG_POINTER, 8))[0]
    return {'command_time': before, 'origin': list(origin_velocity[:3]),
            'velocity': list(origin_velocity[3:]), 'stable_command_time': before == after and same_binding,
            'gravity_speed': gravity_speed}


def reader(path):
    identity = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    return trace.ProcessReader(identity['PID'], identity['Image'], identity['CreatedUtc'], identity['SHA256'])


def sample_pair(server, client, allow_transitions=False):
    try:
        authoritative = trace.Fields(server.read).sample()
        predicted = prediction(client.read)
        for row in authoritative['slots']:
            ptr = trace.Fields(server.read).ptr(trace.CLIENT_TABLE + 8 * row['slot'])
            row['reliable_sent'] = trace.Fields(server.read).i32(ptr + 0x4127C)
            row['last_packet_time'] = trace.Fields(server.read).i32(ptr + 0x9EFB8)
            row['delta_message'] = trace.Fields(server.read).i32(ptr + 0x410C8)
        return {'type': 'sample', 'server': authoritative, 'prediction': predicted}
    except (OSError, ValueError) as error:
        if not allow_transitions:
            raise
        # A disconnected/loading client can release globals during a read.
        # Preserve the gap explicitly; never turn it into a stable sample or
        # infer that every unavailable interval is a harmless transition.
        return {'type': 'unavailable', 'error': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-identity', required=True)
    parser.add_argument('--client-identity', required=True)
    parser.add_argument('--seconds', type=int, choices=range(1, 121), default=40)
    parser.add_argument('--output', required=True)
    parser.add_argument('--transitions', action='store_true')
    args = parser.parse_args()
    destination = trace.output_path(args.output)
    server = reader(args.server_identity)
    client = None
    try:
        client = reader(args.client_identity)
        validate_prediction_layout(client.read)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination = trace.output_path(str(destination))
        with destination.open('x', encoding='utf-8') as output:
            def emit(row):
                output.write(json.dumps(row, allow_nan=False) + '\n')
                output.flush()
            emit({'type': 'header', 'schema': 'iw7.paired-rejoin/1', 'server': server.identity,
                  'client': client.identity, 'utc': datetime.now(timezone.utc).isoformat(),
                  'limits': 'Asynchronous reads; reduced test is not normal-quality FPS acceptance.'})
            start = time.monotonic()
            samples = 0
            unavailable = 0
            try:
                while time.monotonic() - start < args.seconds and not destination.with_suffix('.stop').exists():
                    begin = time.monotonic()
                    row = sample_pair(server, client, args.transitions)
                    emit({**row, 'elapsed_ms': round((begin - start) * 1000),
                          'utc': datetime.now(timezone.utc).isoformat(),
                          'read_duration_ms': round((time.monotonic() - begin) * 1000, 3)})
                    samples += row['type'] == 'sample'
                    unavailable += row['type'] == 'unavailable'
                    time.sleep(0.05)
                emit({'type': 'complete', 'samples': samples, 'unavailable': unavailable, 'gameplay_pass': None})
            except Exception as error:
                emit({'type': 'aborted', 'error': str(error), 'samples': samples})
                raise
    finally:
        if client:
            client.close()
        server.close()


if __name__ == '__main__':
    main()
