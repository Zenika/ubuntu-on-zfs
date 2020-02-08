#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

readonly PROGNAME=$(basename "$0")
readonly PROGDIR=$(readlink -m "$(dirname "$0")")
readonly ARGS=("$@")

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
    local disks
    local options
    if [ -z "$TARGET_DISK" ]; then
        shopt -s nullglob
        disks=(/dev/disk/by-id/*)
        shopt -u nullglob
        options=()
        
        for i in "${!disks[@]}"; do
            options+=("${disks[i]}")
            options+=("")
        done

        TARGET_DISK=$(whiptail --title "Disk to install to" --menu \
            "Choose the device to install to (full disk)" 20 78 ${#disks[@]} \
            "${options[@]}" \
            3>&1 1>&2 2>&3)
    fi
    echo "The chosen disk is: ${TARGET_DISK}"
}

format_disk() {
    sgdisk --zap-all "${TARGET_DISK}"
}

create_partitions() {
    sgdisk -n2:1M:+512M \
    -t2:EF00 \
    "${TARGET_DISK}"

    sgdisk -n3:0:+512M \
    -t3:BF01 \
    "${TARGET_DISK}"

    sgdisk -n4:0:0 \
    -t4:BF01 \
    "${TARGET_DISK}"
}

# In /dev/disk/by-id, symbolic links to new block devices are created asynchronously by udev.
# Let's wait for them to be ready.
wait_for_partitions() {
    local retry=10

    until [ -b "$TARGET_DISK-part3" ] \
        && [ -b "$TARGET_DISK-part4" ]; do
        if [ "$(((retry--)))" -eq 0 ]; then
            echo "Timeout waiting for partitions"
            exit 1
        fi
        echo "Waiting for partitions to be ready…"
        sleep 1
    done
}

create_zfs_pools() {

    zpool create -f -o ashift=12 \
      -d \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@large_blocks=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -o feature@userobj_accounting=enabled \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O devices=off \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      bpool \
      "${TARGET_DISK}-part3"

      zpool create -f -o ashift=12 \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O dnodesize=auto \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      rpool \
      "${TARGET_DISK}-part4"
}

create_zfs_datasets() {
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
    zfs mount rpool/ROOT/ubuntu

    zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu
    zfs mount bpool/BOOT/ubuntu
}

install_minimum_system() {
    debootstrap bionic /mnt
    zfs set devices=off rpool
}

configure_hostname() {
    if [ -z "$TARGET_HOSTNAME" ]; then
        TARGET_HOSTNAME=$(whiptail --inputbox \
            "Enter a host name for this machine" 8 78 "" \
            --title "Host name" 3>&1 1>&2 2>&3)
    fi

    echo "${TARGET_HOSTNAME}" > /mnt/etc/hostname
    echo "127.0.1.1       ${TARGET_HOSTNAME}" >> /mnt/etc/hosts
}

configure_apt_sources() {
    cat <<EOT > /mnt/etc/apt/sources.list
deb http://fr.archive.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://fr.archive.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
deb http://fr.archive.ubuntu.com/ubuntu/ bionic-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu bionic-security main restricted universe multiverse
EOT
}

set_user_password() {
    local firstTry
    local secondTry
    until [ ! -z "$USER_PASSWORD" ]; do
        firstTry=$(whiptail --passwordbox \
            "Enter password for default user" 8 78 "" \
            --title "Choose user password" 3>&1 1>&2 2>&3)
        secondTry=$(whiptail --passwordbox \
            "Confirm password for default user" 8 78 "" \
            --title "Choose user password" 3>&1 1>&2 2>&3)
        if [ "$firstTry" == "$secondTry" ]; then
            USER_PASSWORD=$firstTry
        fi
    done
}

prepare_for_chroot() {
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys
    cp chroot-install.sh /mnt
    chmod u+x /mnt/chroot-install.sh
    cp zfs-scripts/* /mnt/usr/local/bin/
    chmod u+x /mnt/usr/local/bin/*
}

chroot_install() {
    chroot /mnt /usr/bin/env \
        TARGET_DISK="$TARGET_DISK" \
        USER_PASSWORD="$USER_PASSWORD" \
        /chroot-install.sh
}

clean_chroot() {
    rm /mnt/chroot-install.sh
}

unmount_all_filesystems() {
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
    zpool export -a
}

usage() {
    # Do NOT replace TAB characters with spaces in the following block
    cat <<- EOF
	USAGE
        $PROGNAME [-d <block device path>]
                  [-n <host name>]
                  [-p <password>]
                  [-h]

	DESCRIPTION
        Program performs a basic install of Ubuntu on a ZFS file system.
        Install is automatic if all options are specified, else it is interactive.

	OPTIONS:
        --disk, -d                  path of the block device on which Ubuntu is to be installed.
        or TARGET DISK env var      CAUTION: the block device specified must be a full disk

        --hostname, -n              host name of the machine to be installed.
        or TARGET_HOSTNAME env var

        --password, -p              user password
        or USER_PASSWORD env var

        --help, -h                  display this help

        IMPORTANT: command line argument takes precedence over the corresponding env var

	EXAMPLES:
        All options specified:
        $PROGNAME --disk /dev/disk/by-id/nvme-KXG50ZNV512G_NVMe_TOSHIBA_512GB_Z74B602VKQJS \\
                  --hostname laptop-1 \\
                  --password somepassword
	EOF
}


cmdline() {
    # Adapted from http://kfirlavi.herokuapp.com/blog/2012/11/14/defensive-bash-programming/
    local arg
    local args
    local option
    local OPTIND
    local OPTARG

    # `for arg; do ... done` means exactly the same as `for arg in "$@"; do ...; done`
    for arg 
    do
        local delim=""
        case "$arg" in
            # Translate --some-long-option to -s (short options)
            --disk)
                args="${args}-d "
                ;;
            --hostname)
                args="${args}-n "
                ;;
            --password)
                args="${args}-p "
                ;;
            --help)
                args="${args}-h "
                ;;
            # Pass through anything else
            *)
                [[ "${arg:0:1}" == "-" ]] || delim="\""
                args="${args}${delim}${arg}${delim} "
                ;;
        esac
    done

    # Reset the positional parameters to the short options
    eval set -- "$args"

    # Great getopts examples here: https://www.quennec.fr/book/export/html/341
    while getopts ":hd:n:p:" option; do
        case $option in
        h)
            usage
            exit 0
            ;;
        d)
            readonly TARGET_DISK="$OPTARG"
            ;;
        n)
            readonly TARGET_HOSTNAME="$OPTARG"
            ;;
        p)
            readonly USER_PASSWORD="$OPTARG"
            ;;
        :)
            echo "-$OPTARG: missing argument"
            exit 1
            ;;
        \?)
            echo "-$OPTARG: invalid option"
            exit 1
            ;;
        esac
    done
}


main() {

    check_root

    cmdline "${ARGS[@]}"

    dependencies

    select_disk

    format_disk

    create_partitions

    wait_for_partitions

    create_zfs_pools

    create_zfs_datasets

    install_minimum_system

    configure_hostname

    configure_apt_sources

    set_user_password

    prepare_for_chroot

    chroot_install

    clean_chroot

    unmount_all_filesystems
}

main