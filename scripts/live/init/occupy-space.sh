#!/bin/sh
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh

booted_device=$(get_booted_device)
disk_size_kb="$(device_size_kb "$booted_device")"

if [ "$((100*disk_size_kb))" -lt $((105*IMAGE_SIZE_KB)) ]
then
    echo "Note: debootstick will not try to span partitions over this disk because it is not significantly larger than original image."
    return
fi

echo "** Spanning over disk space..."

{
    process_volumes "none" "$booted_device" "expand"

    echo RETURN 0
} | filter_quiet

echo "** Done."

