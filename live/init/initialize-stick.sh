#!/bin/bash
THIS_DIR=$(cd $(dirname $0); pwd)
source $THIS_DIR/tools.sh

OLD_ROOT="$1"
SQUASHFS_CONTENTS_DIR="$2"

# find device currently being booted
source /dbstck.conf     # get LVM_VG value
set -- $(pvs | grep $LVM_VG)
device=$(echo $1 | sed -e "s/.$//")

# occupy available space
echo "Extending disk space..."
sgdisk -e -d 3 -n 3:0:0 -t 3:8e00 ${device}
partx -u ${device}
pvresize ${device}3
lvextend -l+100%FREE /dev/$LVM_VG/ROOT
resize2fs /dev/$LVM_VG/ROOT

# extract the squashfs image contents
echo "Uncompressing..."
cp_big_dir_contents $SQUASHFS_CONTENTS_DIR $OLD_ROOT

