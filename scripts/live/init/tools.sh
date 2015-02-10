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

