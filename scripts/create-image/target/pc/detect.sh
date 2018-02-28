#!/bin/sh
fs_tree=$1

# the files we check here are part of the libc package,
# so one of them should be here, depending on CPU architecture.

if ls "$fs_tree/etc/ld.so.conf.d/i686-linux-gnu.conf" >/dev/null 2>&1
then
    exit 0  # OK
fi

if ls "$fs_tree/etc/ld.so.conf.d/x86_64-linux-gnu.conf" >/dev/null 2>&1
then
    exit 0  # OK
fi

exit 1  # not such a system
