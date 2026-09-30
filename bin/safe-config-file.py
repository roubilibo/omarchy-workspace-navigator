#!/usr/bin/env python3
"""Safely read or atomically replace a small per-user config file."""

import os
import secrets
import stat
import sys


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
            sys.stdout.buffer.write(data)
        finally:
            os.close(fd)
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


def main():
    if len(sys.argv) < 4:
        fail("usage: safe-config-file.py read|write PATH LIMIT [CONTENT]")
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
    else:
        fail("invalid operation")


if __name__ == "__main__":
    try:
        main()
    except FileNotFoundError:
        raise SystemExit(3)
    except OSError as error:
        fail(str(error))
