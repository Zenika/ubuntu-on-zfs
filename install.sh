#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

unset INSTALL_DISK

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Script must be executed with root privileges"
        exit 1
    fi
}

dependencies() {
    apt-add-repository universe
    apt install -y debootstrap gdisk zfs-initramfs
}

select_disk() {
    shopt -s nullglob
    disks=(/dev/disk/by-id/*)
    shopt -u nullglob
    options=()
    
    for i in "${!disks[@]}"; do
        options+=("${disks[i]}")
        options+=("")
    done

    echo "${options[@]}"

    set +e
    INSTALL_DISK=$(whiptail --title "Disk to install to" --menu \
    "Choose the device to install to (full disk)" 20 78 ${#disks[@]} \
    "${options[@]}" \
    3>&1 1>&2 2>&3)
    exitstatus=$?
    set -e

    echo "The chosen disk is: ${INSTALL_DISK}"

}

#check_root

#dependencies

select_disk