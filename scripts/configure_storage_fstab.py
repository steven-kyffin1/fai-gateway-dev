#!/usr/bin/env python3
"""Validate and atomically maintain the NVMe fstab entry; never format a disk."""

import argparse
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import uuid


def configure_fstab(fstab, filesystem_uuid, mount_point):
    fstab = Path(fstab).resolve(strict=True)
    original_stat = fstab.stat()
    if not stat.S_ISREG(original_stat.st_mode):
        raise ValueError(f"Not a regular fstab file: {fstab}")

    filesystem_uuid = str(uuid.UUID(filesystem_uuid))
    if not mount_point.startswith("/") or any(
        character.isspace() or character in "\\\x00" for character in mount_point
    ):
        raise ValueError("The storage mount point must be an absolute path without whitespace or backslashes")

    original = fstab.read_bytes()
    cleaned = original.replace(b"\x00", b"")
    target = mount_point.encode("utf-8")
    expected_source = f"UUID={filesystem_uuid}".encode("ascii")
    entries = []
    for line in cleaned.splitlines():
        fields = line.split()
        if fields and not fields[0].startswith(b"#") and len(fields) >= 2:
            if fields[1] == target:
                entries.append(fields)
            elif fields[0] == expected_source:
                raise ValueError("The NVMe UUID is already assigned to another fstab mount point; review it manually")

    if len(entries) > 1:
        raise ValueError(f"Multiple fstab entries exist for {mount_point}; review them manually")
    if entries:
        entry = entries[0]
        if len(entry) < 4 or entry[0] != expected_source or entry[2] != b"ext4":
            raise ValueError(f"Existing fstab entry for {mount_point} requires review")
    else:
        if cleaned and not cleaned.endswith(b"\n"):
            cleaned += b"\n"
        cleaned += expected_source + b" " + target + b" ext4 defaults,nofail 0 2\n"

    descriptor, temporary_path = tempfile.mkstemp(prefix=".fstab.fai-check.", dir=fstab.parent)
    temporary = Path(temporary_path)
    try:
        with os.fdopen(descriptor, "wb") as candidate:
            candidate.write(cleaned)
            candidate.flush()
            os.fsync(candidate.fileno())

        # Validate the entire table before replacing the live file.
        subprocess.run(
            ["findmnt", "--verify", "--verbose", "--tab-file", str(temporary)],
            check=True,
        )

        if cleaned == original:
            print(f"Existing fstab entry verified for {mount_point}.")
            return None
        if fstab.read_bytes() != original:
            raise ValueError("fstab changed during validation; refusing to replace it")

        descriptor, backup_path = tempfile.mkstemp(prefix="fstab.fai-backup.", dir=fstab.parent)
        os.close(descriptor)
        backup = Path(backup_path)
        shutil.copy2(fstab, backup)
        os.chown(backup, original_stat.st_uid, original_stat.st_gid)

        shutil.copystat(fstab, temporary)
        os.chown(temporary, original_stat.st_uid, original_stat.st_gid)
        os.replace(temporary, fstab)
        directory_fd = os.open(fstab.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

        print(f"fstab backup saved: {backup}")
        removed = original.count(b"\x00")
        if removed:
            print(f"Removed {removed} NUL bytes from fstab; validated the repaired entries.")
        print(f"Storage mount entry ready: {mount_point} (UUID={filesystem_uuid}).")
        return backup
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fstab", default="/etc/fstab")
    parser.add_argument("--uuid", required=True)
    parser.add_argument("--mount-point", default="/opt/fai-storage")
    args = parser.parse_args()
    try:
        configure_fstab(args.fstab, args.uuid, args.mount_point)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"ERROR: Storage fstab configuration failed: {error}\n")


if __name__ == "__main__":
    main()
