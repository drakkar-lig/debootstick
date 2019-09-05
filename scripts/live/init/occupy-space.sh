#!/bin/sh
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf      # get LVM_VG

COMPUTE_PRECISION=1000
VG="$(get_vg_name "$STICK_OS_ID")"

dump_partition_info()
{
    booted_device="$1"
    echo "$PARTITIONS" | tr ';' ' ' | while read part_id subtype size
    do
        device="$(get_part_device $booted_device $part_id)"
        echo "part $device $subtype $size"
    done
}

dump_lvm_info()
{
    echo "$LVM_VOLUMES" | tr ';' ' ' | while read label subtype size
    do
        echo "lvm /dev/$VG/$label $subtype $size"
    done
}

dump_volumes_info()
{
    dump_partition_info "$1"
    dump_lvm_info
}

size_as_kb()
{
    echo $(($(echo $1 | sed -e "s/M/*1024/" -e "s/G/*1024*1024/")))
}

sum_lines() {
    echo $(($(paste -sd+ -)))
}

device_size_kb() {
    size_b=$(blockdev --getsize64 $1)
    echo $((size_b/1024))
}

analysis_step1() {
    nice_factor="$1"

    while read voltype device subtype size
    do
        current_size_kb=$(device_size_kb $device)
        case "$size" in
            *%)
                # percentage
                percent_requested=$(echo $size | tr -d '%')
                percent=$((percent_requested*nice_factor/COMPUTE_PRECISION))
                if [ $((current_size_kb*100)) -ge $((percent*disk_size_kb)) ]
                then    # percentage too low regarding current size, convert to 'auto'
                    echo $voltype auto $device $subtype $current_size_kb
                else
                    echo $voltype percent $percent $device $subtype $current_size_kb
                fi
                ;;
            *[MG])
                # fixed size
                size_requested_kb=$(size_as_kb $size)
                size_kb=$((size_requested_kb*nice_factor/COMPUTE_PRECISION))
                if [ $size_kb -le $current_size_kb ]
                then    # fixed size too low regarding current size, convert to 'auto'
                    echo $voltype auto $device $subtype $current_size_kb
                else
                    # convert to percentage of disk size, to ease later processing
                    percent=$((size_kb*100/disk_size_kb))
                    echo $voltype percent $percent $device $subtype $current_size_kb
                fi
                ;;
            max)
                echo $voltype max $device $subtype $current_size_kb
                ;;
            auto)
                echo $voltype auto $device $subtype $current_size_kb
                ;;
            *)
                echo "unknown size! '$size'" >&2
                return 1
                ;;
        esac
    done
}

compute_applied_sizes()
{
    booted_device="$1"
    disk_size_kb="$(device_size_kb "$booted_device")"

    nice_factor=$COMPUTE_PRECISION  # init nice_factor at ratio 1.0

    while true
    do
        volume_analysis_step1="$(dump_volumes_info "$booted_device" | analysis_step1 $nice_factor)"

        static_size_kb=$(echo "$volume_analysis_step1" | grep -v " percent " | grep -v "^part.*lvm" | awk '{print $NF}' | sum_lines)
        space_size_kb=$((disk_size_kb-static_size_kb))
        sum_percents=$(echo "$volume_analysis_step1" | grep " percent " | awk '{print $3}' | sum_lines)

        if [ $((sum_percents*disk_size_kb)) -gt $((space_size_kb*100)) ]
        then
            # there is not enough free space for the sum of percents requested.
            # we have to share free space in a proportional way.
            # instead of giving each volume the percent requested, we give (percent/sum_percents*space_size_kb) kilobytes,
            # thus the following percentage of disk size: (percent/sum_percents*space_size_kb/disk_size_kb).
            # thus, we apply each percent requested a 'nice-factor' of (space_size_kb/(sum_percents*disk_size_kb)).
            nice_factor=$((space_size_kb*100*COMPUTE_PRECISION/(sum_percents*disk_size_kb)))
        else
            break   # Ok
        fi
    done

    echo "$volume_analysis_step1" | while read voltype sizetype args
    do
        set -- $args
        case $sizetype in
            "percent")
                applied_size_kb=$(($1*disk_size_kb/100))
                echo $voltype $2 $3 $applied_size_kb
                ;;
            "auto")
                echo $voltype $1 $2 keep
                ;;
            "max")
                echo $voltype $1 $2 max
                ;;
        esac
    done
}

get_booted_device()
{
    rootfs_device=$(findmnt -no SOURCE /)
    if echo "$rootfs_device" | sed 's/--/-/g' | grep "$VG" >/dev/null
    then
        # rootfs is on LVM
        get_booted_device_from_vg $VG
    else
        # rootfs is on a partition
        part_to_disk $rootfs_device
    fi
}

resize_last_partition()
{
    disk="$1"
    applied_size_kb="$2"

    eval $(partx -o NR,START,TYPE -P $disk | tail -n 1)

    if [ "$applied_size_kb" = "max" ]
    then
        # do not specify the size => it will extend to the end of the disk
        part_def=" $NR : start=$START, type=$TYPE"
    else
        # sector size is 512 bytes
        sector_size=$((applied_size_kb*2))
        part_def=" $NR : start=$START, type=$TYPE, size=$sector_size"
    fi

    # we delete, then re-create the partition with same information
    # except the size
    sfdisk --no-reread $disk >/dev/null 2>&1 << EOF || true
$(sfdisk -d $disk | head -n -1)
$part_def
EOF
    partx -u ${disk}  # notify the kernel

}

resize_lvm_volume()
{
    device="$1"
    applied_size_kb="$2"

    if [ "$applied_size_kb" = "max" ]
    then
        lvextend -l+100%FREE "$device"
    else
        lvextend -L${applied_size_kb}K "$device"
    fi
}

device_name()
{
    if [ "$1" = "part" ]
    then
        echo "partition $2"
    else
        echo "lvm logical volume $(basename $2)"
    fi
}

# resize2fs prints its version information on stderr, even if it succeeds.
# make it silent unless it fails.
quiet_resize2fs()
{
    device="$1"
    return_code=0
    output="$(
        resize2fs "$device" 2>&1
    )" || return_code=$?
    if [ $return_code -ne 0 ]
    then
        echo "$output" >&2
        return $return_code
    fi
}

resize_volume()
{
    booted_device="$1"
    voltype="$2"
    device="$3"
    subtype="$4"
    applied_size="$5"
    dev_name=$(device_name $voltype $device)

    if [ "$applied_size" = "keep" ]
    then
        return
    fi

    case "$voltype" in
        "part")
            # we know it is the last partition
            echo MSG resizing last partition...
            resize_last_partition "$booted_device" "$applied_size"
            ;;
        "lvm")
            echo MSG resizing $dev_name...
            resize_lvm_volume "$device" "$applied_size"
            ;;
    esac

    case "$subtype" in
        "ext4")
            echo MSG resizing ext4 filesystem on $dev_name...
            quiet_resize2fs "$device"
            ;;
        "lvm")  # physical volume on a partition
            echo MSG extending lvm physical volume on $dev_name...
            pvresize "$device"
            ;;
    esac
}

echo "** Extending disk space..."

{
    echo MSG gathering resize data...
    booted_device=$(get_booted_device)
    format_info="$(compute_applied_sizes "$booted_device")"

    # resize partitions before lvm volumes (primary sort key),
    # and lines with "applied_size=max" last (secondary sort key)
    echo "$format_info" | sort -k 1,1r -k 4,4 | while read voltype device subtype applied_size
    do
        resize_volume "$booted_device" $voltype "$device" $subtype $applied_size
    done

    echo RETURN 0
} | filter_quiet

echo "** Done."

