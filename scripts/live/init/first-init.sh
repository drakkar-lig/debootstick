#!/bin/sh

# remount / read-write
mount -o remount,rw /

# run initialization script
/opt/debootstick/live/init/initialize-stick.sh

# restore and start the usual init
rm /sbin/init
mv /sbin/init.orig /sbin/init
exec /sbin/init $*

