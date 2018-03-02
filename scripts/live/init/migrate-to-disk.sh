#!/bin/bash
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf

clear
echo "** ---- INSTALLER MODE -------------------"
if ! $USE_LVM
then
    echo "** ERROR: Root filesystem is not built on LVM!"
    echo "** ERROR: Installer mode seems broken on this target."
    echo "Aborted!"
    exit 1
fi

if [ -z "$BOOTLOADER_INSTALL" ]
then
    echo "** ERROR: Unknown bootloader installation procedure!"
    echo "** ERROR: Installer mode seems broken on this target."
    echo "Aborted!"
    exit 1
fi

LVM_VG=$(get_vg_name $STICK_OS_ID)
ORIGIN=$(get_booted_device_from_vg $LVM_VG)
pv_part_num=$(get_pv_part_num $ORIGIN)
next_part_num=$(get_next_part_num $ORIGIN)

if [ "$next_part_num" -ne "$(($pv_part_num+1))" ]
then
    echo "** ERROR: LVM physical volume is not the last partition!"
    echo "** ERROR: Installer mode seems broken on this target."
    echo "Aborted!"
    exit 1
fi

origin_capacity=$(get_device_capacity $ORIGIN)
larger_devices="$(get_higher_capacity_devices $origin_capacity)"

if [ "$larger_devices" = "" ]
then
    echo "Error: no device larger than the one currently booted was detected." >&2
    echo "Aborted!"
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
    sgdisk -d $pv_part_num -n $pv_part_num:0:0 \
                -t $pv_part_num:8e00 ${TARGET}

    echo MSG letting the kernel update partition info...
    partx -d ${TARGET}
    partx -a ${TARGET}

    echo MSG copy partitions that are not LVM PVs...
    for n in $(get_part_nums_not_pv $ORIGIN)
    do
        part_origin=$(get_part_device ${ORIGIN} $n)
        part_target=$(get_part_device ${TARGET} $n)
        dd_min_verbose if=$part_origin of=$part_target bs=10M
    done

    echo MSG moving the lvm volume content on ${TARGET}...
    part_origin=$(get_part_device ${ORIGIN} $pv_part_num)
    part_target=$(get_part_device ${TARGET} $pv_part_num)
    yes | pvcreate -ff $part_target
    vgextend $LVM_VG $part_target
    pvchange -x n $part_origin
    pvmove -i 1 $part_origin | while read pv action percent
    do
        echo REFRESHING_MSG "$percent"
    done
    vgreduce $LVM_VG $part_origin
    echo REFRESHING_DONE

    echo MSG filling the space available...
    lvextend -l+100%FREE /dev/$LVM_VG/ROOT
    resize2fs /dev/$LVM_VG/ROOT

    echo MSG installing the bootloader...
    $BOOTLOADER_INSTALL ${TARGET}

    echo MSG making sure ${ORIGIN} is not used anymore...
    pvremove $part_origin
    sync; sync
    partx -d ${ORIGIN}

    echo RETURN 0
} | filter_quiet

echo "** Migration completed."
echo "** Source media ($origin_label) can be unplugged, it is not used anymore."

