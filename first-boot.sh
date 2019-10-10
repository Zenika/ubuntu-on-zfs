#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

create_user() {
    local username=user
    apt install -y whois
    # TODO NO hardcoded password!
    useradd -m -p "$(mkpasswd -m sha-512 zenika)" -s /bin/bash "$username"
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$username"
}

full_install() {
    apt update
    apt full-upgrade -y
    apt install -y ubuntu-desktop
}

configure_network() {
    cat <<EOT > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: NetworkManager
EOT
}

clean_itself() {
    rm /usr/local/first-boot.sh
}

main() {
    create_user

    full_install

    configure_network

    clean_itself
}

main