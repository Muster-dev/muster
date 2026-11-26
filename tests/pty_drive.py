#!/usr/bin/env python3
"""Drive an interactive command in a pseudo-terminal (tests only).

Usage: pty_drive.py CWD TIMEOUT STEP... -- CMD ARGS...

Each STEP is "expect=>send": wait until EXPECT appears in the output (after
the previous match), then type SEND. "\\n" in SEND is Enter, "\\e" is Esc,
"\\x03" is Ctrl+C. A STEP of "kill=>EXPECT" waits for EXPECT and then stops
the process (for flows that end in "press any key" screens).
Prints everything the program wrote; exits with the program's exit code
(or 124 on timeout, 137 when killed by a kill step).
"""
import os
import pty
import select
import signal
import subprocess
import sys
import time


def decode(s):
    return (s.replace("\\n", "\r").replace("\\e", "\x1b")
             .replace("\\x03", "\x03").replace("\\down", "\x1b[B")
             .replace("\\up", "\x1b[A"))


def main():
    argv = sys.argv[1:]
    cwd, timeout = argv[0], float(argv[1])
    sep = argv.index("--")
    steps = [s.split("=>", 1) for s in argv[2:sep]]
    cmd = argv[sep + 1:]

    master, slave = pty.openpty()
    env = dict(os.environ)
    env.setdefault("TERM", "xterm-256color")
    p = subprocess.Popen(cmd, cwd=cwd, stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True, env=env, start_new_session=True)
    os.close(slave)
    out = b""
    pos = 0
    step = 0
    deadline = time.time() + timeout
    killed = False
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        while step < len(steps):
            a, b = steps[step]
            if a == "kill":
                idx = out.find(b.encode(), pos)
                if idx < 0:
                    break
                os.killpg(p.pid, signal.SIGKILL)
                killed = True
                step = len(steps)
                break
            idx = out.find(a.encode(), pos)
            if idx < 0:
                break
            pos = idx + len(a)
            time.sleep(0.15)
            os.write(master, decode(b).encode())
            step += 1
        if killed or p.poll() is not None:
            # drain
            try:
                while True:
                    r, _, _ = select.select([master], [], [], 0.2)
                    if not r:
                        break
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    out += chunk
            except OSError:
                pass
            break
    rc = None
    if p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        rc = 137 if killed else 124
    else:
        rc = p.returncode
    try:
        os.close(master)
    except OSError:
        pass
    sys.stdout.write(out.decode("utf-8", "replace"))
    sys.exit(rc if rc >= 0 else 128 - rc)


if __name__ == "__main__":
    main()
