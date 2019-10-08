#!/bin/bash
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh

clear
echo "** ---- INSTALLER MODE -------------------"
if ! root_on_lvm
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

ORIGIN=$(get_booted_device)

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
    echo MSG making sure ${target_label} is not used...
    pvs --no-headings -o pv_name | while read pv_name
    do
        [ "$(part_to_disk $pv_name)" == "$TARGET" ] || continue
        vg=$(vgs --select "pv_name = $pv_name" --noheadings | awk '{print $1}')
        if [ -n "$vg" ]; then
            enforce_disk_cmd vgchange -an "$vg"
            enforce_disk_cmd vgremove -ff -y "$vg"
        fi
        enforce_disk_cmd pvremove -ff -y $pv_name
    done

    echo MSG copying the partition scheme...
    sgdisk -Z ${TARGET}
    sgdisk -R ${TARGET} ${ORIGIN}
    sgdisk -G ${TARGET}

    # migrate partitions and LVM volumes
    process_volumes "${ORIGIN}" "${TARGET}" "migrate"

    echo MSG installing the bootloader...
    $BOOTLOADER_INSTALL ${TARGET}

    echo RETURN 0
} | filter_quiet

echo "** Migration completed."
echo "** Source media ($origin_label) can be unplugged, it is not used anymore."

