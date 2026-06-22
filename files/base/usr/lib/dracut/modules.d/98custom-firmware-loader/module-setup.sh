#!/bin/bash

check() {
    # Always include this module in the initramfs at build time
    return 0
}

depends() {
    # No extra module dependencies
    return 0
}

install() {
    # Install the hook script to run during the pre-trigger stage of boot
    inst_hook pre-trigger 90 "$moddir/load-firmware.sh"
}
