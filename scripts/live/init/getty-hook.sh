#!/bin/bash
. /dbstck.conf  # get GETTY_COMMAND

first_init()
{
    # - we will talk to the console
    # - since we were called as a subprocess,
    #   we can avoid leaking the lock fd
    exec 0</dev/console 1>/dev/console 2>&1 200>&-
    # run debootstick init procedure
    /opt/debootstick/live/init/first-init.sh
}

# several getty processes will be spawned concurrently,
# we have to use a lock
{
    flock 200
    if [ -f "${GETTY_COMMAND}.orig" ]
    then
        # original getty not restored yet
        # => this means we are first, we will do the job.
        (first_init)    # execute in a sub-shell
        # restore original getty
        mv "${GETTY_COMMAND}.orig" "$GETTY_COMMAND"
    fi
} 200>/var/lib/debootstick-init.lock

exec "$GETTY_COMMAND" "$@"
