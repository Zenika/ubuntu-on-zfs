#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

PROGDIR=$(readlink -m "$(dirname "$0")")
readonly PROGDIR

# shellcheck disable=SC1091
. "$PROGDIR/common.sh"

update_apt_sources() {
    log_info "Updating APT sources…"

    apt update

    log_success "APT sources updated!"
}

configure_locales() {
    log_info "Reconfiguring locales package…"

    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i -e 's/# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
    echo 'LANG="fr_FR.UTF-8"' >/etc/default/locale
    dpkg-reconfigure --frontend=noninteractive locales

    log_success "locales package reconfigured!"
}

# Inspired by https://bugs.launchpad.net/ubuntu/+source/tzdata/+bug/1554806/comments/9
configure_tzdata() {
    log_info "Reconfiguring tzdata package…"

    rm /etc/localtime /etc/timezone
    ln -fs /usr/share/zoneinfo/Europe/Paris /etc/localtime
    dpkg-reconfigure --frontend=noninteractive tzdata

    log_success "tzdata package reconfigured!"
}

configure_keyboard() {
    log_info "Reconfiguring keyboard-configuration package…"

    # Do NOT format code below. Tabs are IMPORTANT. Do not remove any! Do NOT add any!
    cat <<EOT >>/tmp/deb-keyboard.conf
keyboard-configuration	console-setup/ask_detect	boolean	false
keyboard-configuration	keyboard-configuration/model	select	PC générique 105 touches (internat.)
keyboard-configuration	keyboard-configuration/layoutcode	string	fr
keyboard-configuration	keyboard-configuration/variant	select	Français
keyboard-configuration	keyboard-configuration/unsupported_layout	boolean	true
keyboard-configuration	keyboard-configuration/xkb-keymap	select
keyboard-configuration	keyboard-configuration/ctrl_alt_bksp	boolean	false
keyboard-configuration	keyboard-configuration/unsupported_options	boolean	true
keyboard-configuration	keyboard-configuration/optionscode	string
keyboard-configuration	keyboard-configuration/unsupported_config_layout	boolean	true
keyboard-configuration	keyboard-configuration/modelcode	string	pc105
keyboard-configuration	keyboard-configuration/store_defaults_in_debconf_db	boolean	true
keyboard-configuration	keyboard-configuration/variantcode	string
keyboard-configuration	console-setup/detected	note
keyboard-configuration	keyboard-configuration/compose	select	No compose key
keyboard-configuration	keyboard-configuration/switch	select	No temporary switch
keyboard-configuration	keyboard-configuration/unsupported_config_options	boolean	true
keyboard-configuration	keyboard-configuration/layout	select	Français
keyboard-configuration	keyboard-configuration/altgr	select	The default for the keyboard layout
keyboard-configuration	keyboard-configuration/toggle	select	No toggling
EOT
    debconf-set-selections </tmp/deb-keyboard.conf
    dpkg-reconfigure --frontend=noninteractive keyboard-configuration
    rm /tmp/deb-keyboard.conf

    sed -i -e 's/XKBLAYOUT="\w*"/XKBLAYOUT="fr"/' /etc/default/keyboard

    log_success "keyboard-configuration package reconfigured!"
}

create_efi_filesystem() {
    log_info "Creating EFI filesystem…"

    apt install -y dosfstools
    mkdosfs -F 32 -s 1 -n EFI "$TARGET_DISK-part1"
    mkdir -p /boot/efi
    echo "/dev/disk/by-uuid/$(blkid -s UUID -o value "$TARGET_DISK-part1")   /boot/efi   vfat    defaults   0   0" >>/etc/fstab
    retry 5 mount /boot/efi

    mkdir /boot/efi/grub /boot/grub
    echo "/boot/efi/grub   /boot/grub   none    defaults,bind   0   0" >>/etc/fstab
    mount /boot/grub

    log_success "EFI filesystem created!"
}

install_base_packages() {
    log_info "Installing basse packages (GRUB, Linux, ZFS)…"

    apt install -y grub-efi-amd64 grub-efi-amd64-signed linux-image-generic shim-signed zfs-initramfs
    # Not needed as this is not a dual-boot configuration
    apt purge -y os-prober

    log_success "Base packages installed!"
}

configure_tmpfs_for_tmp() {
    log_info "Configures a tmpfs filesystem for /tmp…"

    cp /usr/share/systemd/tmp.mount /etc/systemd/system/
    systemctl enable tmp.mount

    log_success "tmpfs filesystem configured for /tmp!"
}

setup_system_groups() {
    log_info "Adding system groups…"

    addgroup --system lpadmin
    addgroup --system lxd
    addgroup --system sambashare

    log_success "System groups added!"
}

refresh_initrd_files() {
    log_info "Refreshing initrd files…"

    update-initramfs -u -k all

    log_success "initrd files refreshed"
}

update_grub_config() {
    log_info "Updating GRUB configuration…"

    sed -i -e 's/GRUB_TIMEOUT_STYLE=hidden/#GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
    sed -i -e 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
    # zfsforce=yes because of failing zpool export at the end of the install (see https://github.com/openzfs/openzfs-docs/issues/270)
    sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="init_on_alloc=0 zfsforce=yes"/' /etc/default/grub
    sed -i -e 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/' /etc/default/grub

    update-grub

    log_success "GRUB configuration updated!"
}

install_boot_loader() {
    log_info "Installing boot loader…"

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy

    log_success "Boot loader installed!"
}

fix_filesystem_mount_ordering() {
    log_info "Fixing filesystem mount ordering…"

    mkdir /etc/zfs/zfs-list.cache
    touch /etc/zfs/zfs-list.cache/bpool
    touch /etc/zfs/zfs-list.cache/rpool
    zed -f

    retry 5 test -s /etc/zfs/zfs-list.cache/bpool
    retry 5 test -s /etc/zfs/zfs-list.cache/rpool

    pkill zed

    sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

    log_success "Filesystem mount ordering fixed!"
}

create_user() {
    log_info "Creating default user account…"

    local username=user
    local password
    apt install -y whois
    password=$(mkpasswd -m sha-512 "$USER_PASSWORD")
    useradd -m -p "$password" -s /bin/bash "$username"
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$username"

    log_success "Default user account created!"
}

full_install() {
    log_info "Starting full install…"

    apt update
    apt full-upgrade -y
    apt install -y ubuntu-desktop-minimal vim bash-completion

    log_success "Full install is over!"
}

firefox_install() {
    add-apt-repository -y ppa:mozillateam/ppa
    cat <<EOT >>/etc/apt/preferences.d/mozillateam
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOT

    cat <<EOT >>/etc/apt/apt.conf.d/51unattended-upgrades-mozillateam
Unattended-Upgrade::Allowed-Origins {
	"LP-PPA-mozillateam:\${distro_codename}";
};
EOT

    apt install -y firefox firefox-locale-fr
}

chromium_install() {
    add-apt-repository -y ppa:phd/chromium-browser
    cat <<EOT >>/etc/apt/preferences.d/chromium
Package: *
Pin: release o=LP-PPA-phd-chromium-browser
Pin-Priority: 1001
EOT

    cat <<EOT >>/etc/apt/apt.conf.d/52unattended-upgrades-chromium
Unattended-Upgrade::Allowed-Origins {
	"LP-PPA-phd-chromium-browser:\${distro_codename}";
};
EOT

    apt install -y chromium-browser
}

configure_network() {
    log_info "Configuring network to use NetworkManager…"

    cat <<EOT >/etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: NetworkManager
EOT

    log_success "Network configured to use NetworkManager!"
}

tune_zfs_config() {
    log_info "Tuning ZFS configuration…"

    # Memory used by ZFS should be limited
    # see https://www.solaris-cookbook.eu/linux/linux-ubuntu/debian-ubuntu-centos-zfs-on-linux-zfs-limit-arc-cache/

    cat <<EOF >/etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=4294967296
EOF
    # see https://serverfault.com/questions/581669/why-isnt-the-arc-max-setting-honoured-on-zfs-on-linux#comment1108614_602457
    refresh_initrd_files

    log_success "ZFS configuration tuned!"
}

add_rollback_script_to_initrd() {
    log_info "Customizing initrd with rollback script…"

    local datasets
    mapfile -t datasets < <(zfs list -o name -H | grep "/ubuntu" | tac)

    cat <<EOF >/etc/initramfs-tools/scripts/local-bottom/zfs-rollback
#!/bin/sh

set -e

PREREQ="zfs"
prereqs() {
    echo "\$PREREQ"
}

case \$1 in
prereqs)
    prereqs
    exit 0
    ;;
esac

# shellcheck disable=SC1091
. /scripts/functions

rollback() {

    log_begin_msg "Import ZFS pools"
    zpool import -a
    log_end_msg

    log_begin_msg "List ZFS datasets"
    zfs list
    log_end_msg

    log_begin_msg "Rollback to initial state"
    for snapshot in $(printf "\"%s\" " "${datasets[@]}"); do
        zfs rollback -r "\$snapshot@current"
    done
    log_end_msg

    log_success_msg "Device restaured to initial state"

    log_begin_msg "Exporting zpools"
    zpool export -a
    log_end_msg

    echo "Press any key to shutdown the computer"
    read -r

    poweroff -f
}

# check kernel command line and look for a rollback argument
for arg in \$(cat /proc/cmdline); do
    if [ "\$arg" = "rollback" ]; then
        rollback
    fi
done
EOF

    chmod +x /etc/initramfs-tools/scripts/local-bottom/zfs-rollback

    refresh_initrd_files

    log_success "Rollback script added to initrd"
}


add_custom_entry_to_grub_menu() {
    log_info "Adding custom entry to GRUB menu…"
    cat <<EOF >>/etc/grub.d/40_custom

submenu 'Restore computer to initial state' {
    menuentry 'Nope, I mistyped, sorry' {
        echo 'OK, shuting down then...'
        halt
    }
    menuentry 'Yes, restore computer to initial state!' {
        load_video
        insmod gzio
        insmod part_gpt
        insmod zfs
        set root='hd0,gpt2'
        echo 'Loading Linux...'
        linux "/BOOT/ubuntu@/vmlinuz" root=ZFS="rpool/ROOT/ubuntu" rollback
        echo 'Loading initial ramdisk...'
        initrd "/BOOT/ubuntu@/initrd.img"
    }
}
EOF

    update-grub

    log_success "GRUB menu updated with custom entry…"
}

snapshot_initial_installation() {
    for dataset in "rpool/ROOT/ubuntu" "bpool/BOOT/ubuntu"; do
        log_info "Creating new snapshots for \"$dataset\" and its descendants…"
        zfs snapshot -r "$dataset@current"
    done
}

main() {

    update_apt_sources

    configure_locales

    configure_tzdata

    configure_keyboard

    create_efi_filesystem

    install_base_packages

    configure_tmpfs_for_tmp

    setup_system_groups

    refresh_initrd_files

    update_grub_config

    install_boot_loader

    fix_filesystem_mount_ordering

    create_user

    full_install

    firefox_install

    chromium_install

    configure_network

    tune_zfs_config

    add_rollback_script_to_initrd

    add_custom_entry_to_grub_menu

    snapshot_initial_installation
}

main
