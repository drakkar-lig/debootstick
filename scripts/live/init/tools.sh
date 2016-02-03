#!/bin/sh
PROGRESS_BAR_SIZE=40

process_exists()
{
    kill -0 $1 2>/dev/null
}

dir_size()
{
    du -smx "$1" | awk '{print $1}'
}

drop_to_shell_and_halt()
{
    echo "Dropping to a shell. (Exiting will stop the system.)"
    bash
    echo "Stopping the system..."
    halt -fp
}

partx_update_exists()
{
    partx -h | grep "\-\-update" >/dev/null || return 1
}

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

# find device currently being booted
get_booted_device()
{
    lvm_vg="$1"
    set -- $(pvs | grep $lvm_vg)
    echo $(echo $1 | sed -e "s/.$//")
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
                echo -en "$line\r"
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
    mv /etc/lvm/lvm.conf.saved /etc/lvm/lvm.conf
}

