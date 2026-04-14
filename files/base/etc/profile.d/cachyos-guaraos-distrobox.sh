# GuaraOS - Distrobox/Container Environment
if [ -n "${CONTAINER_ID}" ] || [ -n "${DISTROBOX_ENTER_PATH}" ]; then
    export BROWSER="/usr/bin/distrobox-host-exec"
fi
