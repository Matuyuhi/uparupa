# The upaa command against a stand-in for the app's socket (#65): it prints the answer only when all of it came, and
# exits with the answer's code. Run by scripts/test.sh with the path to the built executable.
import os
import socket
import subprocess
import sys
import tempfile
import threading

binary = sys.argv[1]


def run(answer):
    """Runs `upaa read --pane 1` against a socket that answers with these bytes. Returns the request and the result."""
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "s")
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(1)
        requests = []

        def serve():
            connection, _ = server.accept()
            data = b""
            while len(data) < 4 or len(data) < 4 + int.from_bytes(data[:4], "little"):
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
            requests.append(data[4:])
            connection.sendall(answer)
            connection.close()

        thread = threading.Thread(target=serve)
        thread.start()
        result = subprocess.run([binary, "read", "--pane", "1"], env={**os.environ, "UPAA_SOCKET": path},
                                capture_output=True, timeout=10)
        thread.join(5)
        server.close()
        return requests[0] if requests else None, result


def answer(code, text):
    return bytes([code]) + len(text).to_bytes(4, "little") + text


request, whole = run(answer(0, b"hello\n"))
assert request == b"read\0--pane\0" + b"1\0", request
assert (whole.returncode, whole.stdout, whole.stderr) == (0, b"hello\n", b""), whole

_, refused = run(answer(1, b"upaa: no\n"))
assert (refused.returncode, refused.stdout, refused.stderr) == (1, b"", b"upaa: no\n"), refused

# The app gave up partway (the command was stopped for too long): an error, and none of the text.
_, cut = run(answer(0, b"hello\n")[:-2])
assert cut.returncode != 0 and cut.stdout == b"" and cut.stderr != b"", cut

print("upaa command: all passed")
