#!/bin/sh
fs_tree=$1

. "$fs_tree/etc/os-release"
if [ "$ID" = "raspbian" ]
then
    exit 0  # OK
fi

exit 1  # not such a system
