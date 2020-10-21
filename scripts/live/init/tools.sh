# vim: filetype=sh
. /dbstck.conf      # get conf
PROGRESS_BAR_SIZE=40
NICE_FACTOR_SCALE=100
VG="DBSTCK_$STICK_OS_ID"

dd_min_verbose()
{
    # status=none did not exist on old versions
    dd status=none "$@" 2>/dev/null || \
    dd status=noxfer "$@"
}

show_progress_bar()
{
    achieved=$1
    total=$2
    # ensure achieved <= total
    if [ $achieved -gt $total ]
    then
        achieved=$total
    fi
    progress_cnt=$((achieved*PROGRESS_BAR_SIZE/total))
    progress_pts=$(printf "%${progress_cnt}s" "" | tr ' ' '*')
    progress_bar=$(printf "|%-${PROGRESS_BAR_SIZE}s|" "$progress_pts")
    printf "$progress_bar %d%%\r" $((achieved*100/total))
}

disk_partitions()
{
    lsblk -lno NAME,TYPE | grep -w disk | while read disk_name type
    do
        disk="/dev/$disk_name"
        lsblk -lno NAME,TYPE $disk | grep -w part | while read part_name type
        do
            part="/dev/$part_name"
            echo $disk $part
        done
    done
}

# check if root filesystem (i.e. "/") is on an LVM volume
root_on_lvm()
{
    rootfs_device=$(findmnt -no SOURCE /)
    echo "$rootfs_device" | sed 's/--/-/g' | grep "$VG" >/dev/null
}

get_booted_device()
{
    if root_on_lvm
    then
        # rootfs is on LVM
        get_booted_device_from_vg $VG
    else
        # rootfs is on a partition
        rootfs_device=$(findmnt -no SOURCE /)
        part_to_disk $rootfs_device
    fi
}

part_to_disk()
{
    set -- $(disk_partitions | grep -w "$1")
    echo $1
}

get_part_device()
{
    disk=$1
    part_num=$2
    set -- $(disk_partitions | grep -w "$disk" | grep "$part_num$")
    echo $2
}

get_part_num()
{
    echo -n $1 | tail -c 1
}

get_booted_device_from_vg()
{
    set -- $(pvs | grep $VG)
    part_to_disk $1
}

get_higher_capacity_devices()
{
    threshold=$1
    cat /proc/partitions | while read major minor size name
    do
        if [ "$major" = "8" ]
        then
            if [ "$((minor % 16))" -eq 0 -a $((size*1024)) -gt $threshold ]
            then
                echo /dev/$name
            fi
        fi
    done
}

get_device_capacity()
{
    device_name=$(echo $1 | sed -e 's/\/dev\///')
    cat /proc/partitions | while read major minor size name
    do
        if [ "$name" = "$device_name" ]
        then
            echo $((size*1024))
            return
        fi
    done
}

M=$((1000000))
G=$((1000*M))
T=$((1000*G))
P=$((1000*T))

human_readable_disk_size()
{
    bytes=$1
    if [ $bytes -ge $P ]; then echo $((bytes/P))P; return; fi
    if [ $bytes -ge $T ]; then echo $((bytes/T))T; return; fi
    if [ $bytes -ge $G ]; then echo $((bytes/G))G; return; fi
    echo $((bytes/M))M
}

get_device_label()
{
    size=$(get_device_capacity $1)
    shortname=$(echo $1 | sed -e 's/\/dev\///')
    echo $(cat /sys/class/block/$shortname/device/model) \
         $(human_readable_disk_size $size)
}

select_menu()
{
    input="$1"
    num_entries=$(echo "$input" | wc -l)
    height=$((num_entries+1))
    move_key="n"
    select_key="s"
    {
        # prepare a blank screen of $height lines
        for i in $(seq $height)
        do
            echo
        done
        selected=1
        while [ 1 ]
        do
            # return to the top of the screen
            echo -en "\033[${height}A\r"
            # print the screen
            echo "$input" | {
                i=1
                while read dev dev_label
                do
                    if [ $i = $selected ]
                    then
                        echo "> $dev_label                     "
                    else
                        echo "  $dev_label                     "
                    fi
                    i=$((i+1))
                done
            }
            echo "Press <$move_key> to move selection or <$select_key> to select."
            # read user input
            stty -echo; read -n 1 key; stty echo
            # react to user input
            if [ "$key" = "$move_key" ]
            then
                selected=$((selected % num_entries))
                selected=$((selected + 1))
            fi
            if [ "$key" = "$select_key" ]
            then
                break
            fi
        done
    } >&2    # UI goes to stderr, result to stdout
    echo "$input" | head -n $selected | tail -n 1 | {
        read dev dev_label
        echo -n $dev
    }
}

fallback_sh()
{
    echo 'An error occured. Starting a shell.'
    echo '(the system will be rebooted on exit.)'
    sh
    reboot -f
}

filter_quiet()
{
    while read action line
    do
        case $action in
            "MSG")
                echo $line
                ;;
            "REFRESHING_MSG")
                case "$line" in
                    *%) # this is a percentage
                        percent_float=$(echo $line | sed 's/.$//')
                        percent_int=$(LC_ALL=C printf "%.0f" $percent_float)
                        show_progress_bar $percent_int 100
                        ;;
                    *)
                        echo -en "$line\r"
                        ;;
                esac
                ;;
            "REFRESHING_DONE")
                echo
                ;;
            "RETURN")
                return $line
                ;;
            *)
                ;;
        esac
    done
    # a read failed and we did not get any RETURN,
    # return an error status
    return 1
}

# we deliberately let the echo enabled will typing
# the password in order to let the user verify what
# he is typing (i.e. the keymap may not be what he is
# used to). Once validated, we replace chars with stars.
ask_and_set_pass()
{
    echo "Enter a root password for this system."
    # prompt for the password
    read -p 'password: ' password
    # return 1 line up
    echo -en "\033[1A\r"
    # overwrite with stars
    echo "password: $(echo "$password" | sed -e 's/./*/g')"
    # set the password
    echo "root:$password" | chpasswd
}

restore_lvm_conf()
{
    if [ -f /etc/lvm/lvm.conf.saved ]
    then
        mv /etc/lvm/lvm.conf.saved /etc/lvm/lvm.conf
    fi
}

dump_partition_info()
{
    disk_device="$1"
    echo "$PARTITIONS" | tr ';' ' ' | while read part_id subtype mountpoint size
    do
        device="$(get_part_device $disk_device $part_id)"
        echo "part $device $subtype $mountpoint $size"
    done
}

dump_lvm_info()
{
    if [ "$LVM_VOLUMES" != "" ]
    then
        echo "$LVM_VOLUMES" | tr ';' ' ' | while read label subtype mountpoint size
        do
            echo "lvm /dev/$VG/$label $subtype $mountpoint $size"
        done
    fi
}

dump_volumes_info()
{
    dump_partition_info "$1"
    dump_lvm_info
}

lvm_partition_size_mb()
{
    dump_partition_info "$1" | while read vol_type device subtype mountpoint size
    do
        if [ "$subtype" = "lvm" ]
        then
            device_size_mb "$device"
            break   # done
        fi
    done
}

lvm_sum_size_mb()
{
    dump_lvm_info | while read vol_type device subtype mountpoint size
    do
        device_size_mb "$device"
    done | sum_lines
}

size_as_mb()
{
    echo $(($(echo $1 | sed -e "s/M//" -e "s/G/*1024/")))
}

sum_lines() {
    exp="$(paste -sd+ -)"
    [ "$exp" = "" ] && echo 0 || echo "$(($exp))"
}

device_size_mb() {
    size_b=$(blockdev --getsize64 $1)
    echo $((size_b/1024/1024))
}

analysis_step1() {
    nice_factor="$1"
    disk_size_mb="$2"

    while read voltype device subtype mountpoint size
    do
        current_size_mb=$(device_size_mb $device)
        case "$size" in
            *%)
                # percentage
                percent_requested=$(echo $size | tr -d '%')
                size_mb=$((percent_requested*nice_factor*disk_size_mb/NICE_FACTOR_SCALE/100))
                if [ $current_size_mb -ge $size_mb ]
                then    # percentage too low regarding current size, convert to 'auto'
                    echo $voltype auto $device $subtype $mountpoint $current_size_mb
                else    # convert to fixed size, to ease later processing
                    echo $voltype fixed $device $subtype $mountpoint $size_mb
                fi
                ;;
            *[MG])
                # fixed size
                size_requested_mb=$(size_as_mb $size)
                size_mb=$((size_requested_mb*nice_factor/NICE_FACTOR_SCALE))
                if [ $size_mb -le $current_size_mb ]
                then    # fixed size too low regarding current size (because of nice factor), convert to 'auto'
                    echo $voltype auto $device $subtype $mountpoint $current_size_mb
                else
                    echo $voltype fixed $device $subtype $mountpoint $size_mb
                fi
                ;;
            max)
                echo $voltype max $device $subtype $mountpoint $current_size_mb
                ;;
            auto)
                echo $voltype auto $device $subtype $mountpoint $current_size_mb
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
    volumes_type="$1"
    volumes_info="$2"
    disk_size_mb="$3"
    total_size_mb="$4"

    # compute applied size of volumes
    nice_factor=$NICE_FACTOR_SCALE  # init nice_factor at ratio 1.0

    while true
    do
        volume_analysis_step1="$(echo "$volumes_info" | analysis_step1 $nice_factor $disk_size_mb)"

        static_size_mb=$(echo "$volume_analysis_step1" | grep -v " fixed " | awk '{print $NF}' | sum_lines)
        space_size_mb=$((total_size_mb-static_size_mb))
        sum_fixed_mb=$(echo "$volume_analysis_step1" | grep " fixed " | awk '{print $NF}' | sum_lines)

        if [ $sum_fixed_mb -gt $space_size_mb ]
        then
            prev_nice_factor="$nice_factor"
            # there is not enough free space for the sum of percents or fixed sizes requested.
            # we have to share free space in a proportional way.
            # instead of giving each volume the fixed size requested (or fixed size corresponding to the percentage requested),
            # we give (fixed_mb/sum_fixed_mb*space_size_mb) megabytes,
            # thus, we apply each size requested a 'nice-factor' of (space_size_mb/sum_fixed_mb).
            nice_factor=$((space_size_mb*NICE_FACTOR_SCALE/sum_fixed_mb))
            # ensure approximation will not be a problem
            if [ $nice_factor -ge $prev_nice_factor ]
            then
                nice_factor=$((prev_nice_factor-1))
            fi
            if [ "$volumes_type" = "partition" ]
            then
                echo "Note: requested partition sizes and percentages are too high regarding the size of this disk." >&2
            else
                echo "Note: requested lvm volume sizes and percentages are too high regarding the size of the lvm partition." >&2
            fi
            echo "Note: debootstick will adapt them." >&2
        else
            break   # Ok
        fi
    done

    echo "$volume_analysis_step1" | while read voltype sizetype args
    do
        set -- $args
        case $sizetype in
            "fixed")
                echo $voltype $1 $2 $3 $4
                ;;
            "auto")
                echo $voltype $1 $2 $3 keep
                ;;
            "max")
                echo $voltype $1 $2 $3 max
                ;;
        esac
    done
}

resize_last_partition()
{
    disk="$1"
    applied_size_mb="$2"

    if [ "$(blkid -o value -s PTTYPE $disk)" = "gpt" ]
    then
        # move backup GPT data structures to the end of the disk, otherwise
        # sfdisk might not allow the partition to span
        sgdisk -e $disk
    fi

    eval $(partx -o NR,START,TYPE -P $disk | tail -n 1)

    if [ "$applied_size_mb" = "max" ]
    then
        # do not specify the size => it will extend to the end of the disk
        part_def=" $NR : start=$START, type=$TYPE"
    else
        # sector size is 512 bytes
        sector_size=$((applied_size_mb*2*1024))
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

enforce_disk_cmd() {
    udevadm settle; sync; sync
    i=0
    while [ $i -lt 10 ]; do
        # handle rare failures
        "$@" 2>/dev/null && break || sleep 1
        i=$((i+1))
    done
    if  [ $i -eq 10 ]
    then    # Still failing after 10 times!
        echo "MSG ERROR: command '$@' fails!"
        return 1
    fi
}

resize_lvm_volume()
{
    device="$1"
    applied_size_mb="$2"

    if [ "$applied_size_mb" = "max" ]
    then
        free_extents=$(vgs --select "vg_name = $VG" --no-headings -o vg_free_count)
        if [ $free_extents -eq 0 ]
        then
            echo "MSG Not resized (no more free space)."
        else
            enforce_disk_cmd lvextend -l+100%FREE "$device"
        fi
    else
        enforce_disk_cmd lvextend -L${applied_size_mb}M "$device"
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

# fatresize prints a warning when it has to convert FAT16 to FAT32
# to handle a larger size. Hide it unless the command really fails.
quiet_fatresize()
{
    device="$1"
    return_code=0
    dev_size=$(blockdev --getsize64 "$device")
    output="$(
        fatresize -s $dev_size "$device" 2>&1
    )" || return_code=$?
    if [ $return_code -ne 0 ]
    then
        echo "$output" >&2
        return $return_code
    fi
}

get_origin_voldevice()
{
    voldevice="$1"
    voltype="$2"
    origin_device="$3"
    if [ "$voltype" = "lvm" -o "$origin_device" = "none" ]
    then
        echo "none"
    else
        part_num=$(get_part_num "$voldevice")
        echo $(get_part_device "$origin_device" $part_num)
    fi
}

unmount_tree()
{
    for mp in $(findmnt --list --submounts --mountpoint "$1" -o TARGET --noheadings | tac)
    do
        echo "MSG temporarily un-mounting $mp..."
        umount $mp || umount -lf $mp || {
            echo "MSG this failed, but everything should be fine on next reboot."
            break
        }
    done
}

get_steps() {
    case "$1" in
        expand-keep-*)
            # nothing to do
            ;;
        expand-*-part-*)
            # we know it is the last partition
            echo "resize_last_partition resize_content"
            ;;
        expand-*-lvm-*)
            echo "resize_lvm_volume resize_content"
            ;;
        migrate-keep-part-lvm)
            echo "init_lvm_pv migrate_lvm"
            ;;
        migrate-keep-part-*)
            echo "unmount copy_partition wipe_orig_part fsck"
            ;;
        migrate-*-part-lvm)
            # we know it is the last partition
            echo "resize_last_partition init_lvm_pv migrate_lvm"
            ;;
        migrate-*-part-*)
            # we know it is the last partition
            echo "unmount copy_partition resize_last_partition resize_content wipe_orig_part fsck"
            ;;
        migrate-keep-lvm-*)
            # nothing to do
            ;;
        migrate-*-lvm-*)
            echo "resize_lvm_volume resize_content"
            ;;
        *)
            echo "BUG: volume descriptor $1 unexpected!" >&2
            return 1    # error
    esac
}

process_volumes() {
    origin_device="$1"
    target_device="$2"
    operation="$3"

    if [ "$LVM_VOLUMES" != "" ]
    then
        orig_lvm_part_size_mb="$(lvm_partition_size_mb "$origin_device")"
        orig_lvm_sum_size_mb="$(lvm_sum_size_mb)"
        lvm_overhead_mb="$((lvm_partition_size_mb - lvm_sum_size_mb))"  # should be 4mb
    fi

    echo MSG gathering partition resize data...
    disk_size_mb="$(device_size_mb "$target_device")"
    volumes_info="$(dump_partition_info "$target_device")"
    partitions_format_info="$(compute_applied_sizes partition "$volumes_info" "$disk_size_mb" "$disk_size_mb")"
    process_part_of_volumes "$origin_device" "$target_device" "$operation" "$partitions_format_info"

    if [ "$LVM_VOLUMES" != "" ]
    then
        echo MSG gathering lvm volume resize data...
        lvm_part_size_mb="$(lvm_partition_size_mb "$target_device")"
        if [ "$((100*lvm_part_size_mb))" -lt $((105*orig_lvm_part_size_mb)) ]
        then
            echo "MSG Note: debootstick will not try to resize lvm volumes since lvm partition was not resized (or not significantly resized)."
        else
            volumes_info="$(dump_lvm_info)"
            lvm_available_size_mb="$((lvm_part_size_mb - lvm_overhead_mb))"
            lvm_format_info="$(compute_applied_sizes lvm_volume "$volumes_info" "$disk_size_mb" "$lvm_available_size_mb")"
            process_part_of_volumes "$origin_device" "$target_device" "$operation" "$lvm_format_info"
        fi
    fi

    if [ "$operation" = "migrate" ]
    then
        echo MSG making sure ${origin_device} is not used anymore...
        enforce_disk_cmd partx -d ${origin_device} || true

        echo "MSG ensuring all filesystems are (re-)mounted..."
        enforce_disk_cmd partx -u ${target_device} && \
        enforce_disk_cmd mount -a || echo "MSG this failed, but everything should be fine on next reboot."
    fi
}

process_part_of_volumes() {
    origin_device="$1"
    target_device="$2"
    operation="$3"
    format_info="$4"

    # we process lines with "applied_size=max" last (sort key)
    echo "$format_info" | sort -k 5,5 | \
    while read voltype voldevice subtype mountpoint applied_size
    do
        dev_name=$(device_name $voltype $voldevice)
        origin_voldevice=$(get_origin_voldevice $voldevice $voltype $origin_device)

        steps="$(get_steps "$operation-$applied_size-$voltype-$subtype")"

        for step in $steps
        do
            case "$step" in
                resize_last_partition)
                    echo MSG resizing last partition...
                    resize_last_partition "$target_device" "$applied_size"
                    ;;
                resize_content)
                    case "$subtype" in
                        "ext4")
                            echo MSG resizing ext4 filesystem on $dev_name...
                            quiet_resize2fs "$voldevice"
                            ;;
                        "fat"|"efi")
                            echo MSG resizing FAT filesystem on $dev_name...
                            umount "$voldevice"
                            quiet_fatresize "$voldevice"
                            mount "$voldevice"
                            ;;
                        "lvm")  # physical volume on a partition
                            echo MSG extending lvm physical volume on $dev_name...
                            enforce_disk_cmd pvresize "$voldevice"
                            ;;
                    esac
                    ;;
                resize_lvm_volume)
                    echo MSG resizing $dev_name...
                    resize_lvm_volume "$voldevice" "$applied_size"
                    ;;
                init_lvm_pv)
                    echo MSG initializing LVM physical volume on $dev_name...
                    enforce_disk_cmd pvcreate -ff -y "$voldevice"
                    ;;
                migrate_lvm)
                    echo MSG moving the lvm volume content on $target_device...
                    enforce_disk_cmd vgextend $VG "$voldevice"
                    enforce_disk_cmd pvchange -x n "$origin_voldevice"
                    enforce_disk_cmd pvmove -i 1 "$origin_voldevice" | while read pv action percent
                    do
                        echo REFRESHING_MSG "$percent"
                    done
                    enforce_disk_cmd vgreduce $VG "$origin_voldevice"
                    enforce_disk_cmd pvremove -ff -y "$origin_voldevice"
                    echo REFRESHING_DONE
                    ;;
                copy_partition)
                    echo "MSG copying partition $origin_voldevice -> $voldevice..."
                    dd_min_verbose if=$origin_voldevice of=$voldevice bs=10M
                    ;;
                unmount)
                    if [ "$mountpoint" != "none" ]
                    then
                        unmount_tree "$mountpoint"
                    fi
                    ;;
                wipe_orig_part)
                    echo "MSG wiping $origin_voldevice..."
                    wipefs -a "$origin_voldevice"
                    ;;
                fsck)
                    if [ "$mountpoint" != "none" ]
                    then
                        echo "MSG checking filesystem on $voldevice..."
                        enforce_disk_cmd fsck "$voldevice"
                    fi
                    ;;
                *)
                    echo "MSG BUG: unexpected step '$step'!"
                    return 1    # error
            esac
        done
    done
}

grub_vg_rename() {
    sed -i -e "s/$VG/$FINAL_VG_NAME/g" /boot/grub/grub.cfg
    echo "MSG Note: File /boot/grub/grub.cfg was modified with new volume group name."
    echo "MSG Note: If you need to reconfigure or update the bootloader, please reboot first."
    vgrename "$VG" "$FINAL_VG_NAME"
}

set_final_vg_name()
{
    if [ -z "$FINAL_VG_NAME" ]
    then
        # nothing to do
        return
    fi

    echo "MSG renaming the LVM volume group $VG -> $FINAL_VG_NAME..."
    # check that final vg name does not already exist on one of the disks
    exists=$(vgs -o vg_name --noheadings | grep -w "$FINAL_VG_NAME" | wc -l)
    if [ "$exists" -eq 0 ]
    then    # ok, let's do it
        $VG_RENAME
        echo "MSG Note: LVM volume group was successfully renamed to '$FINAL_VG_NAME'."
        echo "MSG Note: (however some commands may still print the previous name until next reboot.)"
    else
        echo "WARNING: Could not rename LVM volume group because '$FINAL_VG_NAME' already exists!" >&2
    fi
}
