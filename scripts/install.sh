#!/bin/bash

set -e

PROGNAME=$(basename "$0")
readonly PROGNAME
readonly ARGS=("$@")

# shellcheck source=./common.sh
source "./common.sh"

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Script must be executed with root privileges"
        exit 1
    fi
}

install_requirements() {
    log_info "Installing required packages…"

    apt-add-repository -y universe
    apt install -y debootstrap gdisk zfs-initramfs
    systemctl stop zed

    log_success "Pacakges installed!"
}

select_disk() {
    local disks
    local options

    log_info "Selecting disk to install on…"

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

    log_success "The chosen disk is: ${TARGET_DISK}"
}

destroy_existing_pools() {
    log_info "Destroying existing ZFS pool…"

    zpool import -a
    for pool_name in $(zpool list -H | awk '{print $1}'); do
        zpool destroy "$pool_name"

        log_success "Pool \"$pool_name\" destroyed!"
    done
}

clear_partition_table() {
    log_info "Destroying existing partition table on disk…"

    sgdisk --zap-all "${TARGET_DISK}"

    log_success "Partition table destroyed!"
}

create_partitions() {
    log_info "Creating new partitions…"
    # Bootloader partition
    sgdisk -n1:1M:+512M \
        -t1:EF00 \
        "${TARGET_DISK}"

    # Boot pool partition
    sgdisk -n2:0:+2G \
        -t2:BE00 \
        "${TARGET_DISK}"

    # Root pool partition
    sgdisk -n3:0:0 \
        -t3:BF00 \
        "${TARGET_DISK}"

    log_success "New partitions created!"
}

create_zfs_pools() {
    log_info "Creating new ZFS pools…"

    # In /dev/disk/by-id, symbolic links to new block devices are created asynchronously by udev, so zpool create may fail
    retry 5 zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -o cachefile=/etc/zfs/zpool.cache \
        -o compatibility=grub2 \
        -o feature@livelist=enabled \
        -o feature@zpool_checkpoint=enabled \
        -O devices=off \
        -O acltype=posixacl -O xattr=sa \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/boot -R /mnt \
        bpool "${TARGET_DISK}-part2"

    retry 5 zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off -O mountpoint=/ -R /mnt \
        rpool "${TARGET_DISK}-part3"

    log_success "New ZFS pools created!"
}

create_zfs_datasets() {
    log_info "Creating new ZFS datasets…"

    # "Container" fylesystem datasets
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    # Filesystem datasets for the root and boot filesystems
    zfs create -o mountpoint=/ rpool/ROOT/ubuntu
    zfs create -o mountpoint=/boot bpool/BOOT/ubuntu

    zfs create -o canmount=off rpool/ROOT/ubuntu/usr
    zfs create rpool/ROOT/ubuntu/usr/local
    zfs create -o canmount=off rpool/ROOT/ubuntu/var
    zfs create rpool/ROOT/ubuntu/var/lib
    zfs create rpool/ROOT/ubuntu/var/lib/apt
    zfs create rpool/ROOT/ubuntu/var/lib/docker
    zfs create rpool/ROOT/ubuntu/var/lib/dpkg
    zfs create rpool/ROOT/ubuntu/var/lib/AccountsService
    zfs create rpool/ROOT/ubuntu/var/lib/NetworkManager
    zfs create rpool/ROOT/ubuntu/var/log
    zfs create rpool/ROOT/ubuntu/var/snap
    zfs create rpool/ROOT/ubuntu/var/spool

    log_success "New ZFS datasets created!"
}

mount_run_tmpfs() {
    log_info "Mouting a tmpfs at /mnt/run…"

    mkdir -p /mnt/run
    mount -t tmpfs tmpfs /mnt/run
    mkdir -p /mnt/run/lock

    log_success "tmpfs mounted at /mnt/run!"
}

install_minimal_system() {
    log_info "Installing minimal system in /mnt…"

    debootstrap jammy /mnt

    log_success "Minimal system installed in /mnt!"
}

copy_zpool_cache() {
    log_info "Copying zpool.cache to /mnt/etc/zfs…"

    mkdir -p /mnt/etc/zfs
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/

    log_success "zpool.cache copied to /mnt/etc/zfs!"
}

configure_hostname() {
    log_info "Configuring device hostname…"

    if [ -z "$TARGET_HOSTNAME" ]; then
        TARGET_HOSTNAME=$(whiptail --inputbox \
            "Enter a host name for this device" 8 78 "" \
            --title "Host name" 3>&1 1>&2 2>&3)
    fi

    echo "${TARGET_HOSTNAME}" >/mnt/etc/hostname
    echo "127.0.1.1       ${TARGET_HOSTNAME}" >>/mnt/etc/hosts

    log_success "Device hostname is: $TARGET_HOSTNAME"
}

configure_apt_sources() {

    log_info "Configuring APT sources…"

    cat <<EOT >/mnt/etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOT

    log_success "APT sources configured!"
}

set_user_password() {
    local firstTry
    local secondTry

    log_info "Configuring user password…"

    until [ -n "$USER_PASSWORD" ]; do
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

    log_success "user password configured!"
}

prepare_for_chroot() {
    log_info "Preparing for chroot…"

    mount --make-private --rbind /dev /mnt/dev
    mount --make-private --rbind /proc /mnt/proc
    mount --make-private --rbind /sys /mnt/sys

    cp chroot-install.sh /mnt
    cp common.sh /mnt
    chmod u+x /mnt/chroot-install.sh /mnt/common.sh

    cp zfs-scripts/* /mnt/usr/local/bin/
    cp common.sh /mnt/usr/local/bin/
    chmod u+x /mnt/usr/local/bin/*

    log_success "Ready for chroot!"
}

chroot_install() {
    log_info "Running installation in chroot…"

    chroot /mnt /usr/bin/env \
        TARGET_DISK="$TARGET_DISK" \
        USER_PASSWORD="$USER_PASSWORD" \
        /chroot-install.sh

    log_success "Installation in chroot is done!"
}

clean_chroot() {
    log_info "Cleaning chroot environment…"

    rm /mnt/chroot-install.sh
    rm /mnt/common.sh

    log_success "chroot environment cleaned!"
}

unmount_all_filesystems() {
    log_info "Unmounting /mnt filesystems…"

    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -I{} umount -lf {}

    # zpool cannot export rpool (see https://github.com/openzfs/openzfs-docs/issues/270)
    set +e
    zpool export -a || log_warning "zpool export failed. Be sure to add zfsforce=yes on the GRUB/Kernel command line to be able to boot!"
    set -e

    log_success "/mnt filesystems unmounted!"
}

usage() {
    # Do NOT replace TAB characters with spaces in the following block
    cat <<-EOF
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
    for arg; do
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

    install_requirements

    select_disk

    destroy_existing_pools

    clear_partition_table

    create_partitions

    create_zfs_pools

    create_zfs_datasets

    mount_run_tmpfs

    install_minimal_system

    copy_zpool_cache

    configure_hostname

    configure_apt_sources

    set_user_password

    prepare_for_chroot

    chroot_install

    clean_chroot

    unmount_all_filesystems
}

main
