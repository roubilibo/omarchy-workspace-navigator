#!/usr/bin/env python3
"""Safely read or atomically replace a small per-user config file."""

import os
import re
import secrets
import stat
import sys
import time


PLUGIN_ID = "roubilibo.workspace-navigator"
LOADER_BEGIN = "-- BEGIN " + PLUGIN_ID + " managed keybindings"
LOADER_END = "-- END " + PLUGIN_ID + " managed keybindings"
LOADER_BLOCK = "\n".join((
    LOADER_BEGIN,
    "do",
    '  local navigator = os.getenv("HOME") .. "/.config/omarchy/plugins/'
    + PLUGIN_ID + '/hypr/workspace-navigator.lua"',
    '  local file = io.open(navigator, "r")',
    "  if file then",
    "    file:close()",
    "    pcall(dofile, navigator)",
    "  end",
    "end",
    LOADER_END,
))


def fail(message):
    print("workspace navigator: " + message, file=sys.stderr)
    raise SystemExit(1)


def open_directory(path, create=False):
    path = os.path.abspath(path)
    if not os.path.isabs(path):
        fail("configuration path must be absolute")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.split("/"):
            if not component:
                continue
            if component in (".", ".."):
                fail("invalid directory component")
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            try:
                child = os.open(component, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(component, 0o700, dir_fd=fd)
                child = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def split_target(path, create_parent=False):
    path = os.path.abspath(path)
    parent, name = os.path.split(path)
    if not name or name in (".", ".."):
        fail("invalid configuration filename")
    return open_directory(parent, create_parent), name


def read_file(path, limit):
    dir_fd, _name, data, _info = read_bytes(path, limit)
    try:
        sys.stdout.buffer.write(data)
    finally:
        os.close(dir_fd)


def atomic_write(path, limit, content):
    data = content.encode("utf-8")
    if len(data) > limit:
        fail("configuration data exceeds size limit")
    dir_fd, name = split_target(path, create_parent=True)
    temporary = ".workspace-navigator-" + secrets.token_hex(12) + ".tmp"
    fd = None
    try:
        try:
            current = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None:
            if not stat.S_ISREG(current.st_mode):
                fail("refusing to replace a non-regular configuration path")
            if current.st_size > limit:
                fail("existing configuration file exceeds size limit")
        mode = stat.S_IMODE(current.st_mode) if current is not None else 0o600
        fd = os.open(temporary,
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     mode, dir_fd=dir_fd)
        os.fchmod(fd, mode)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                fail("could not finish writing configuration file")
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        # Recheck immediately before replacement so a swapped symlink or
        # special file is never silently replaced.
        try:
            latest = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            latest = None
        if latest is not None and not stat.S_ISREG(latest.st_mode):
            fail("refusing to replace a non-regular configuration path")
        if (current is None) != (latest is None):
            fail("configuration path changed during write")
        if current is not None and (current.st_dev, current.st_ino) != (latest.st_dev, latest.st_ino):
            fail("configuration path changed during write")
        os.replace(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        os.fsync(dir_fd)
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        os.close(dir_fd)


def read_bytes(path, limit):
    dir_fd, name = split_target(path)
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        fd = os.open(name, flags, dir_fd=dir_fd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                fail("configuration path is not a regular file")
            if info.st_size > limit:
                fail("configuration file exceeds size limit")
            chunks = []
            remaining = limit + 1
            while remaining:
                chunk = os.read(fd, min(remaining, 8192))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > limit:
                fail("configuration file exceeds size limit")
            os.close(fd)
            return dir_fd, name, data, info
        except BaseException:
            os.close(fd)
            raise
    except BaseException:
        os.close(dir_fd)
        raise


def make_loader_backup(dir_fd, name):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = name + ".workspace-navigator-" + stamp + ".bak"
    for suffix in range(100):
        backup = base if suffix == 0 else base[:-4] + "-" + str(suffix) + ".bak"
        try:
            os.link(name, backup, src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
                    follow_symlinks=False)
            return
        except FileExistsError:
            continue
    fail("could not create a unique bindings backup")


def sync_loader(path, limit):
    try:
        dir_fd, name, data, info = read_bytes(path, limit)
        existed = True
    except FileNotFoundError:
        dir_fd, name = split_target(path, create_parent=True)
        data = b""
        info = None
        existed = False

    try:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            fail("bindings file is not valid UTF-8")

        # Accept the accidentally double-commented markers used by the first
        # manual-install instructions, while writing one canonical block.
        marker = re.compile(r"^\s*(?:--\s*)*(-- (?:BEGIN|END) "
                            + re.escape(PLUGIN_ID)
                            + r" managed keybindings)\s*$", re.MULTILINE)
        found = list(marker.finditer(text))
        if len(found) not in (0, 2):
            fail("incomplete or duplicate managed keybinding markers")
        if len(found) == 2:
            if not found[0].group(1).startswith(LOADER_BEGIN) or not found[1].group(1).startswith(LOADER_END):
                fail("managed keybinding markers are out of order")
            start = text.rfind("\n", 0, found[0].start()) + 1
            end = text.find("\n", found[1].end())
            if end < 0:
                end = len(text)
            else:
                end += 1
            updated = text[:start] + LOADER_BLOCK + "\n" + text[end:]
        else:
            separator = "" if not text or text.endswith("\n") else "\n"
            updated = text + separator + LOADER_BLOCK + "\n"

        if updated == text:
            print("unchanged")
            return

        # Refuse to overwrite a file that changed while the block was built.
        if existed:
            latest_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                dir_fd=dir_fd)
            try:
                latest = os.fstat(latest_fd)
                latest_data = os.read(latest_fd, limit + 1)
            finally:
                os.close(latest_fd)
            if ((latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns)
                    != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                    or latest_data != data):
                fail("bindings file changed during update; retry after saving edits")

        # Preserve an exact, recoverable copy before replacing an existing
        # config. The hard link cannot follow a symlink and keeps its mode/data.
        if existed:
            make_loader_backup(dir_fd, name)

        atomic_write(path, limit, updated)
        print("changed")
    finally:
        os.close(dir_fd)


def main():
    if len(sys.argv) < 4:
        fail("usage: safe-config-file.py read|write|sync-loader PATH LIMIT [CONTENT]")
    operation, path, limit_text = sys.argv[1:4]
    try:
        limit = int(limit_text)
    except ValueError:
        fail("invalid size limit")
    if limit <= 0 or limit > 65536:
        fail("size limit is out of range")
    if operation == "read" and len(sys.argv) == 4:
        read_file(path, limit)
    elif operation == "write" and len(sys.argv) == 5:
        atomic_write(path, limit, sys.argv[4])
    elif operation == "sync-loader" and len(sys.argv) == 4:
        sync_loader(path, limit)
    else:
        fail("invalid operation")


if __name__ == "__main__":
    try:
        main()
    except FileNotFoundError:
        raise SystemExit(3)
    except OSError as error:
        fail(str(error))
