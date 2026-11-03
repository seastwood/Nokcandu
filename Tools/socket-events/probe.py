#!/usr/bin/env python3
"""Integration regression: synthetic loopback only, disposable prefix, no game/account data."""
import argparse
import os
import json
import shutil
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wine', type=Path, required=True)
parser.add_argument('--frameworks', type=Path, required=True)
parser.add_argument('--probe', type=Path, required=True)
parser.add_argument('--library', type=Path)
parser.add_argument('--mode', choices=['graceful', 'refused', 'urgent', 'reset'], default='graceful')
args = parser.parse_args()
for path in [args.wine, args.probe] + ([args.library] if args.library else []):
    if not path.is_absolute() or not path.is_file():
        parser.error('Use existing absolute paths for binaries and the optional helper.')

with tempfile.TemporaryDirectory(prefix='nok-socket-regression-') as temporary:
    env = os.environ.copy()
    env.update(WINEPREFIX=temporary, DYLD_FALLBACK_LIBRARY_PATH=str(args.frameworks)+':/usr/lib',
               CX_ROOT=str(args.wine.parent.parent), WINEDEBUG='-all', SikarugirAppWine11='1',
               ROSETTA_ADVERTISE_AVX='1', NOKCANDU_NO_GAME_APP='1')
    env.pop('DYLD_INSERT_LIBRARIES', None)
    loaded_directory = None
    if args.library:
        # Exercise the same loaded-version record path as an installed game.
        helper_folder = Path(temporary)/'Harness.app/Contents/SharedSupport/nokcandu'
        helper_folder.mkdir(parents=True)
        staged = helper_folder/'nokcandu-rawmouse.dylib'
        shutil.copyfile(args.library, staged)
        env['DYLD_INSERT_LIBRARIES'] = str(staged)
        loaded_directory = helper_folder/'loaded-helpers'
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    port = server.getsockname()[1]
    errors = []
    def serve():
        server.settimeout(90)
        try:
            connection, _ = server.accept()
            with connection:
                connection.recv(32)
                if args.mode == 'reset':
                    connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                elif args.mode == 'urgent':
                    connection.sendall(b'a')
                    connection.send(b'!', socket.MSG_OOB)
                    connection.shutdown(socket.SHUT_WR)
                else:
                    connection.sendall(b'HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK')
                    connection.shutdown(socket.SHUT_WR)
        except Exception as error:
            errors.append(type(error).__name__)
        finally:
            server.close()
    thread = None
    if args.mode == 'refused':
        server.close()
    else:
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
    try:
        windows_path = 'Z:' + str(args.probe).replace('/', '\\')
        # Observe while the client is alive. A short-lived wineserver may have
        # exited by the time subprocess stdout has finished draining.
        expected_file = args.library.parent/'helper-build.txt' if args.library else None
        expected = expected_file.read_text().strip() if expected_file and expected_file.exists() else None
        observed_server = False
        process = subprocess.Popen([str(args.wine), windows_path, str(port), args.mode], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        deadline = time.monotonic()+90
        try:
            while True:
                if loaded_directory:
                    for file in loaded_directory.glob('*.json'):
                        try:
                            record = json.loads(file.read_text())
                            if record['role'] == 'server' and record['pid'] > 1:
                                os.kill(record['pid'], 0)
                                if expected and record['build'] != expected:
                                    raise SystemExit('Loaded server helper does not match this build.')
                                observed_server = True
                        except (FileNotFoundError, ProcessLookupError):
                            pass
                try:
                    stdout, _ = process.communicate(timeout=0.05)
                    result = subprocess.CompletedProcess(process.args, process.returncode, stdout)
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        raise SystemExit('Probe execution timed out.')
        finally:
            if process.poll() is None:
                process.kill(); process.communicate(timeout=15)
        print(result.stdout, end='')
        if result.returncode:
            raise SystemExit('Probe did not execute successfully.')
        if thread:
            thread.join(timeout=2)
        if errors:
            raise SystemExit('Local responder failed: '+', '.join(errors))
        output = result.stdout
        if args.mode == 'refused' and not ('exceptional=1' in output and 'socket_error=10061' in output):
            raise SystemExit('A real refused connection was lost.')
        if args.mode == 'urgent' and 'exceptional=1' not in output:
            raise SystemExit('Real urgent data was lost.')
        if args.mode == 'reset' and 'error=10054' not in output:
            raise SystemExit('A real reset was lost.')
        if args.library and args.mode == 'graceful':
            if output.count('exceptional=0') != 2 or output.count('readable=1') != 2:
                raise SystemExit('Normal EOF is still incorrectly exceptional or unreadable.')
            if 'drain bytes=40 result=0 error=0' not in output:
                raise SystemExit('Response bytes or clean EOF were lost.')
        if loaded_directory:
            if not observed_server:
                raise SystemExit('No live wineserver reported its loaded helper version during execution.')
            print('activation server_records=observed_live build=current')
    finally:
        # This unique prefix was created here; never stop a user-supplied prefix.
        server.close()
        wineserver = args.wine.parent/'wineserver'
        for flag in ['-k', '-w']:
            subprocess.run([str(wineserver), flag], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=15)
