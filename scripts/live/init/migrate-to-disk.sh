#!/bin/bash
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf

clear
echo "** ---- INSTALLER MODE -------------------"
ORIGIN=$(get_booted_device $LVM_VG)
origin_capacity=$(get_device_capacity $ORIGIN)
larger_devices="$(get_higher_capacity_devices $origin_capacity)"

if [ "$larger_devices" = "" ]
then
    echo "Error: no device larger than the one currently booted was detected." >&2
    exit 1
fi

if [ $(echo "$larger_devices" | wc -l) -eq 1 ]
then
    TARGET=$larger_devices
else
    menu_input="$(
        for device in $larger_devices
        do       # item  # item description
            echo $device "$device: $(get_device_label $device)"
        done)"
    echo Several target disks are available.
    TARGET=$(select_menu "$menu_input")
    echo "$TARGET selected."
fi

origin_label=$(get_device_label $ORIGIN)
target_label=$(get_device_label $TARGET)

echo "** About to start migration!"
echo "** $origin_label --> $target_label"
echo
echo "** WARNING: Any existing data on target disk will be lost."
echo "** WARNING: Press any key NOW to cancel this process."
read -t 10 -n 1 && { echo "Aborted!"; exit 1; }
echo "** Going on."

{
    echo MSG copying the partition scheme...
    sgdisk -Z ${TARGET}
    sgdisk -R ${TARGET} $ORIGIN
    sgdisk -G ${TARGET}

    echo MSG extending the last partition...
    sgdisk -d 3 -n 3:0:0 -t 3:8e00 ${TARGET}

    echo MSG letting the kernel update partition info...
    partx -d ${TARGET}
    partx -a ${TARGET}

    echo MSG copying partition contents...
    dd_min_verbose if=${ORIGIN}1 of=${TARGET}1 bs=10M
    dd_min_verbose if=${ORIGIN}2 of=${TARGET}2 bs=10M

    echo MSG moving the lvm volume content on ${TARGET}...
    yes | pvcreate -ff ${TARGET}3
    vgextend $LVM_VG ${TARGET}3
    pvchange -x n ${ORIGIN}3
    pvmove -i 1 ${ORIGIN}3 | while read pv action percent
    do
        echo REFRESHING_MSG "$percent"
    done
    vgreduce $LVM_VG ${ORIGIN}3
    echo REFRESHING_DONE

    echo MSG filling the space available...
    lvextend -l+100%FREE /dev/$LVM_VG/ROOT
    resize2fs /dev/$LVM_VG/ROOT

    echo MSG installing the bootloader...
    grub-install ${TARGET}

    echo MSG making sure ${ORIGIN} is not used anymore...
    pvremove ${ORIGIN}3
    sync; sync
    partx -d ${ORIGIN}

    echo RETURN 0
} | filter_quiet

echo "** Migration completed."
echo "** Source media ($origin_label) can be unplugged, it is not used anymore."

