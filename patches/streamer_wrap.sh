#!/bin/sh
# Pushed to the doorbell by camera-rotation-watchdog.sh and bind-mounted over
# /bin/ubnt_streamer. It LD_PRELOADs rot90.so (forces the encoder's hallwayMode
# getter to the value in hallway_val -> 0 = disabled = landscape) and execs the
# real streamer binary kept at realbin/ubnt_streamer.
#
# Kept inode-stable on purpose: the watchdog changes the rotation by writing
# hallway_val (NOT by editing this file), because the bind-mount pins this file's
# inode and a rewrite would not be picked up.
export LD_PRELOAD=/etc/persistent/rot90.so
export HALLWAY=$(cat /etc/persistent/hallway_val 2>/dev/null || echo 0)
exec /etc/persistent/realbin/ubnt_streamer "$@"
