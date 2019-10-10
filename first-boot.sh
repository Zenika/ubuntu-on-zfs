#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e



clean_itself() {
    rm /usr/local/first-boot.sh
}

main() {
    echo "Coucou !"

    #clean_itself
}

main