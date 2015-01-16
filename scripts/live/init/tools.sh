PROGRESS_BAR_SIZE=40

process_exists()
{
    kill -0 $1 2>/dev/null
}

dir_size()
{
    du -smx "$1" | awk '{print $1}'
}

generate_mtab()
{
    findmnt -rnu -o SOURCE,TARGET,FSTYPE,OPTIONS > /etc/mtab
}

fs_available_size()
{
    df -m --output=avail "$1" | tail -n 1
}

drop_to_shell_and_halt()
{
    echo "Dropping to a shell. (Exiting will stop the system.)"
    bash
    echo "Stopping the system..."
    halt -fp
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

cp_big_dir_contents()
{
    src="$1"
    dst="$2"
    
    # start the copy in the background
    # we want to avoid job control messages 
    # about this background process
    old_shell_flags=$-
    set +m
    new_shell_flags=$-
    { cp -rp $src/* $dst/ & } 2>/dev/null
    pid=$!

    # in the meanwhile periodically compare 
    # the size of src and dst
    src_size=$(dir_size "$src")
    dst_size_init=$(dir_size "$dst")

    while $(process_exists $pid)
    do
        dst_size=$(dir_size "$dst")
        dst_size_copied=$((dst_size-dst_size_init))
        show_progress_bar $dst_size_copied $src_size
        sleep 1
    done
    wait    # just in case
    sync
    show_progress_bar $src_size $src_size     # 100% 
    echo
    
    # only re-enable job monitoring if it was really enabled at first
    # (i.e. the shell flags have changed...)
    if [ "$new_shell_flags" != "$old_shell_flags" ] 
    then
        set -m
    fi
}
