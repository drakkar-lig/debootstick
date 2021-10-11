#!/bin/bash
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh

booted_device=$(get_booted_device)
disk_size_mb="$(device_size_mb "$booted_device")"

if [ "$((100*disk_size_mb))" -lt $((105*IMAGE_SIZE_MB)) ]
then
    echo "Note: debootstick will not try to span partitions over this disk because it is not significantly larger than original image."
    exit
fi

echo "** Spanning over disk space..."

{
    process_volumes "none" "$booted_device" "expand"

    set_final_vg_name

    echo RETURN 0
} | filter_quiet

echo "** Done."

