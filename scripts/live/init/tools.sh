# vim: filetype=sh
. /dbstck.conf      # get conf
PROGRESS_BAR_SIZE=40
NICE_FACTOR_SCALE=100
VG="DBSTCK_$STICK_OS_ID"

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
    lsblk -lno NAME,TYPE | while read disk_name type
    do
        test "$type" = disk || continue
        disk="/dev/$disk_name"
        lsblk -lno NAME,TYPE "$disk" | while read part_name type
        do
            test "$type" = part || continue
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
    lsblk -lno PATH,TYPE | while read device type
    do
        test "$type" = disk || continue
        device_size=$(get_device_capacity "$device")
        if [ $device_size -gt $threshold ]
        then
            echo $device
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
    if [ -f "/sys/class/block/$shortname/device/model" ]
    then
        model=$(cat /sys/class/block/$shortname/device/model)
    else
        model="DISK"
    fi
    echo $model $(human_readable_disk_size $size)
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

dump_partition_info()
{
    disk_device="$1"
    echo "$PARTITIONS" | while IFS=";" read part_id subtype mountpoint size
    do
        device="$(get_part_device $disk_device $part_id)"
        echo "part;$device;$subtype;$mountpoint;$size"
    done
}

dump_lvm_info()
{
    if [ "$LVM_VOLUMES" != "" ]
    then
        echo "$LVM_VOLUMES" | while IFS=";" read label subtype mountpoint size
        do
            echo "lvm;/dev/$VG/$label;$subtype;$mountpoint;$size"
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
    dump_partition_info "$1" | while IFS=";" read vol_type device subtype mountpoint size
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
    dump_lvm_info | while IFS=";" read vol_type device subtype mountpoint size
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

    while IFS=";" read voltype device subtype mountpoint size
    do
        current_size_mb=$(device_size_mb $device)
        case "$size" in
            *%)
                # percentage
                percent_requested=$(echo $size | tr -d '%')
                size_mb=$((percent_requested*nice_factor*disk_size_mb/NICE_FACTOR_SCALE/100))
                if [ $current_size_mb -ge $size_mb ]
                then    # percentage too low regarding current size, convert to 'auto'
                    echo "$voltype;auto;$device;$subtype;$mountpoint;$current_size_mb"
                else    # convert to fixed size, to ease later processing
                    echo "$voltype;fixed;$device;$subtype;$mountpoint;$size_mb"
                fi
                ;;
            *[MG])
                # fixed size
                size_requested_mb=$(size_as_mb $size)
                size_mb=$((size_requested_mb*nice_factor/NICE_FACTOR_SCALE))
                if [ $size_mb -le $current_size_mb ]
                then    # fixed size too low regarding current size (because of nice factor), convert to 'auto'
                    echo "$voltype;auto;$device;$subtype;$mountpoint;$current_size_mb"
                else
                    echo "$voltype;fixed;$device;$subtype;$mountpoint;$size_mb"
                fi
                ;;
            max)
                echo "$voltype;max;$device;$subtype;$mountpoint;$current_size_mb"
                ;;
            auto)
                echo "$voltype;auto;$device;$subtype;$mountpoint;$current_size_mb"
                ;;
            *)
                echo "unknown size! '$size'" >&2
                return 1
                ;;
        esac
    done
}

last_field()
{
    awk 'BEGIN {FS = ";"}; {print $NF}'
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

        static_size_mb=$(echo "$volume_analysis_step1" | grep -v ";fixed;" | last_field | sum_lines)
        space_size_mb=$((total_size_mb-static_size_mb))
        sum_fixed_mb=$(echo "$volume_analysis_step1" | grep ";fixed;" | last_field | sum_lines)

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

    echo "$volume_analysis_step1" | \
            while IFS=";" read voltype sizetype device subtype mountpoint current_size_mb
    do
        case $sizetype in
            "fixed")
                echo "$voltype;$device;$subtype;$mountpoint;$current_size_mb"
                ;;
            "auto")
                echo "$voltype;$device;$subtype;$mountpoint;keep"
                ;;
            "max")
                echo "$voltype;$device;$subtype;$mountpoint;max"
                ;;
        esac
    done
}

get_sector_size()
{
    blockdev --getss "$1"
}

get_part_table_type()
{
    do_quiet_err_only sfdisk --dump "$1" | grep "^label:" | awk '{print $2}'
}

# this function is a little more complex than expected
# because it has to deal with possibly different sector sizes.
copy_partition_table()
{
    source_disk="$1"
    target_disk="$2"

    source_disk_ss=$(get_sector_size $source_disk)
    target_disk_ss=$(get_sector_size $target_disk)

    multiplier=1
    divider=1
    if [ $source_disk_ss -gt $target_disk_ss ]
    then
        multiplier=$((source_disk_ss / target_disk_ss))
    elif [ $target_disk_ss -gt $source_disk_ss ]
    then
        divider=$((target_disk_ss / source_disk_ss))
    fi

    {
        echo "label: $(get_part_table_type $source_disk)"
        echo
        partx -o NR,START,SECTORS,TYPE -P $source_disk | while read line
        do
            eval $line
            START=$((START*multiplier/divider))
            SECTORS=$((SECTORS*multiplier/divider))
            echo " $NR : start=$START, type=$TYPE, size=$SECTORS"
        done
    } | sfdisk --no-reread $target_disk >/dev/null
    partx -u ${target_disk}  # notify the kernel
}

resize_last_partition()
{
    disk="$1"
    applied_size_mb="$2"
    disk_sector_size=$(get_sector_size $disk)
    partx_sector_size=512   # partx unit is always 512-bytes sectors

    # note: we need to pass partition offsets and size to sfdisk
    # using the disk sector size as unit.
    # conversions should be carefully written to avoid integer overflows
    # (partition offset and size may be large if converted to bytes...)

    if [ "$(blkid -o value -s PTTYPE $disk)" = "gpt" ]
    then
        # move backup GPT data structures to the end of the disk, otherwise
        # sfdisk might not allow the partition to span
        sgdisk -e $disk
    fi

    eval $(partx -o NR,START,TYPE -P $disk | tail -n 1)
    # convert partition start offset unit from 'partx sector size' to 'disk sector size'
    START=$((START/(disk_sector_size/partx_sector_size)))

    if [ "$applied_size_mb" = "max" ]
    then
        # do not specify the size => it will extend to the end of the disk
        part_def=" $NR : start=$START, type=$TYPE"
    else
        part_size_in_sectors=$((applied_size_mb*(1024*1024/disk_sector_size)))
        part_def=" $NR : start=$START, type=$TYPE, size=$part_size_in_sectors"
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

# some commands print informational messages or minor warnings on stderr,
# silence them together with stdout unless the command really fails.
do_quiet()
{
    return_code=0
    output="$(
        "$@" 2>&1
    )" || return_code=$?
    if [ $return_code -ne 0 ]
    then
        echo "$output" >&2
        return $return_code
    fi
}

# same thing, but just filter out stderr, keep stdout
# (if the command fails, restore stderr output).
do_quiet_err_only()
{
    {
        return_code=0
        output="$(
            "$@" 3>&1 1>&2 2>&3 # swap stdout <-> stderr
        )" || return_code=$?
        if [ $return_code -ne 0 ]
        then
            echo "$output" >&1
            return $return_code
        fi
    } 3>&1 1>&2 2>&3 # restore stdout <-> stderr
}

# fatresize prints a warning when it has to convert FAT16 to FAT32
# to handle a larger size. Hide it unless the command really fails.
quiet_fatresize()
{
    device="$1"
    dev_size=$(blockdev --getsize64 "$device")
    do_quiet fatresize -s $dev_size "$device"
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
        umount $mp || umount -lf $mp || {
            echo "MSG unmounting failed, but everything should be fine on next reboot."
            break
        }
    done
}

make_filesystem() {
    voldevice="$1"
    subtype="$2"
    label="$3"
    uuid="$4"

    options=""
    case "$subtype" in
        efi|fat)
            fstype="vfat"
            if [ ! -z "$label" ]
            then
                options="-n $label"
            fi
            if [ ! -z "$uuid" ]
            then
                uuid=$(echo "$uuid" | tr -d "-")
                options="$options -i $uuid"
            fi
            ;;
        ext4)
            fstype="ext4"
            if [ ! -z "$label" ]
            then
                options="-L $label"
            fi
            if [ ! -z "$uuid" ]
            then
                options="$options -U $uuid"
            fi
            ;;
    esac

    mkfs -t $fstype $options "$voldevice"
}

copy_files() {
    src_dir="$1"
    dst_dir="$2"
    cp -a "$src_dir/." "$dst_dir"
}

copy_partition() {
    origin_voldevice="$1"
    voldevice="$2"
    subtype="$3"
    mountpoint="$4"
    temp_dir="$5"

    # retrieve uuid & label
    uuid="$(blkid -o value -s UUID "$origin_voldevice")"
    label="$(blkid -o value -s LABEL "$origin_voldevice")"

    # make filesystem on target
    make_filesystem $voldevice "$subtype" "$label" "$uuid"

    # (re)mount origin and target on fixed temp mountpoints
    old_mountpoint="$temp_dir/old"
    new_mountpoint="$temp_dir/new"
    mkdir -p "$old_mountpoint" "$new_mountpoint"
    if [ "$mountpoint" != "none" ]
    then
        unmount_tree "$mountpoint"
    fi
    mount "$origin_voldevice" "$old_mountpoint"
    mount "$voldevice" "$new_mountpoint"

    # copy partition files
    copy_files "$old_mountpoint" "$new_mountpoint"

    # umount temp mountpoints
    umount "$old_mountpoint"
    umount "$new_mountpoint"
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
        migrate-keep-part-bios)
            # bootloader installation will initialize the target partition
            echo "wipe_orig_part"
            ;;
        migrate-keep-part-*)
            echo "copy_partition wipe_orig_part"
            ;;
        migrate-*-part-lvm)
            # we know it is the last partition
            echo "resize_last_partition init_lvm_pv migrate_lvm"
            ;;
        migrate-*-part-bios)    # this should be unusual!!
            # we know it is the last partition
            echo "resize_last_partition wipe_orig_part"
            ;;
        migrate-*-part-*)
            # we know it is the last partition
            echo "resize_last_partition copy_partition wipe_orig_part"
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
        # note: target_device variable is always available (when called from
        # 'occupy-space.sh' and from 'migrate-to-disk.sh'); and in the later
        # case, partition table has already been copied from origin_device.
        orig_lvm_part_size_mb="$(lvm_partition_size_mb "$target_device")"
        orig_lvm_sum_size_mb="$(lvm_sum_size_mb)"
        lvm_overhead_mb="$((orig_lvm_part_size_mb - orig_lvm_sum_size_mb))"  # should be 4mb
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
    temp_dir="$(mktemp -d)"

    # we process lines with "applied_size=max" last (sort key)
    echo "$format_info" | sort -t ";" -k 5,5 | \
    while IFS=";" read voltype voldevice subtype mountpoint applied_size
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
                            do_quiet resize2fs "$voldevice"
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
                    copy_partition "$origin_voldevice" "$voldevice" "$subtype" \
                                   "$mountpoint" "$temp_dir"
                    ;;
                wipe_orig_part)
                    echo "MSG wiping $origin_voldevice..."
                    wipefs -a "$origin_voldevice"
                    ;;
                *)
                    echo "MSG BUG: unexpected step '$step'!"
                    return 1    # error
            esac
        done
    done
    rm -rf "$temp_dir"
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

grub-install()
{
    # grub-install prints messages to standard
    # error stream although most of these are just
    # informational (or minor issues). This function masks
    # the grub-install program to discard those spurious
    # messages.
    # caution with shebangs: bash is needed to allow a
    # function name containing '-' char.
    do_quiet env grub-install "$@"
}
