#!/usr/bin/env python3
"""
Patch action_server.py to add a Windows named-mutex single-instance guard.

Why this script runs locally (not from the sandbox bash):
    The sandbox bind-mount has a stale view of action_server.py and cannot see
    the trailing `if __name__ == "__main__":` block. The fix has to run from
    Daniel's native Python so it sees the live file.

What it does:
    1. Reads scripts/action_server.py from the live OneDrive path
    2. Inserts a Windows named-mutex single-instance helper inside the main block
    3. Inserts a guard at the top of the main block; loser exits with code 0
    4. Writes back atomically with OneDrive null-byte padding stripped
    5. Verifies the patch landed; refuses to leave a corrupted file behind

Run it once:
    python "C:\\Scripts\\GitHub\\token-dashboard\\patch_action_server.py"

It is idempotent: re-runs do nothing if the file is already patched.
"""

import os
import sys
from pathlib import Path


JOBSEARCH_ROOT = (
    Path(os.environ["USERPROFILE"])
    / "OneDrive - IT Conceptions"
    / "Documents"
    / "JobSearch"
)
TARGET = JOBSEARCH_ROOT / "scripts" / "action_server.py"


SINGLETON_HELPER_BLOCK = '''    # Single-instance guard - exit cleanly if another instance is already running.
    # Windows allows two processes to both bind the same port via SO_REUSEADDR
    # (the werkzeug default). This named-mutex check makes the second one exit
    # cleanly with code 0 so the watchdog does not see an "error".
    def _acquire_singleton(name):
        import sys
        if sys.platform != "win32":
            return True
        try:
            import ctypes
            from ctypes import wintypes
        except ImportError:
            return True
        kernel32 = ctypes.windll.kernel32
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.GetLastError.restype = wintypes.DWORD
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        ERROR_ALREADY_EXISTS = 183
        handle = kernel32.CreateMutexW(None, False, name)
        if not handle:
            return True
        if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
            kernel32.CloseHandle(handle)
            return False
        return True

'''


def atomic_write_text(path: Path, text: str, max_iterations: int = 5) -> None:
    """Atomic write with OneDrive null-byte padding defense.

    Per the JobSearch CLAUDE.md write rule: read file as bytes, rstrip null bytes,
    write to tempfile in same dir, os.replace, verify null count == 0, repeat
    up to N times.
    """
    parent = path.parent
    bytes_to_write = text.encode("utf-8")
    for attempt in range(1, max_iterations + 1):
        bytes_to_write = bytes_to_write.rstrip(b"\x00")
        tmp = parent / (path.name + ".tmp")
        with open(tmp, "wb") as f:
            f.write(bytes_to_write)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        with open(path, "rb") as f:
            actual = f.read()
        null_count = actual.count(b"\x00")
        if null_count == 0:
            return
        print(f"  attempt {attempt}: {null_count} null bytes detected, restripping")
        bytes_to_write = actual
    raise RuntimeError(
        f"OneDrive null-byte padding could not be cleared after {max_iterations} attempts on {path}"
    )


def patch_main_block(content: str) -> str:
    """Insert helper + guard immediately after the `if __name__ == "__main__":` line."""
    if "_acquire_singleton" in content:
        return content  # idempotent

    needle = 'if __name__ == "__main__":'
    idx = content.find(needle)
    if idx == -1:
        raise RuntimeError("could not find `if __name__ == \"__main__\":` in action_server.py")

    head = content[: idx + len(needle)]
    tail = content[idx + len(needle):]

    guard_block = (
        "\n"
        + SINGLETON_HELPER_BLOCK
        + '    if not _acquire_singleton(r"Local\\JobSearchActionServer"):\n'
        + '        print("[ActionServer] Another instance is already running on :5050. Exiting cleanly.")\n'
        + "        sys.exit(0)\n"
    )

    return head + guard_block + tail


def main() -> int:
    if not TARGET.exists():
        print(f"ERROR: {TARGET} does not exist", file=sys.stderr)
        return 1

    original_size = TARGET.stat().st_size
    text = TARGET.read_text(encoding="utf-8")
    new_text = patch_main_block(text)

    if new_text == text:
        print(f"ALREADY PATCHED: {TARGET}")
        return 0

    atomic_write_text(TARGET, new_text)
    new_size = TARGET.stat().st_size

    # Verify
    verify = TARGET.read_text(encoding="utf-8")
    if "_acquire_singleton" not in verify:
        print(f"FAIL: patch did not stick", file=sys.stderr)
        return 2
    if 'if __name__ == "__main__":' not in verify:
        print(f"FAIL: main block disappeared after patch", file=sys.stderr)
        return 2
    if "app.run(host=" not in verify:
        print(f"FAIL: app.run missing after patch", file=sys.stderr)
        return 2

    print(f"PATCHED: {TARGET}")
    print(f"  size: {original_size} -> {new_size} bytes (+{new_size - original_size})")
    print(f"  _acquire_singleton: present")
    print(f"  guard active for mutex name: Local\\JobSearchActionServer")
    print()
    print("Verify by running action_server twice in two PowerShell windows.")
    print("The second one should print:")
    print("  [ActionServer] Another instance is already running on :5050. Exiting cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
