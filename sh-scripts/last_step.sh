#!/usr/bin/env bash


chown_dir_mnt_wsl(){
    local wsl_user=${1:-}

    dirs=$(echo /mnt/wsl/*/)

    for dir in $dirs; do
        if [ -d "${dir}" ]; then
            ramdisk_owner=$(stat -c '%U' ${dir})
            if [ "$ramdisk_owner" != "$wsl_user" ]; then
                echo "Changing ownership of ${dir} to $wsl_user"
                sudo chown -R "$wsl_user":"$wsl_user" ${dir}
            fi
        fi
    done
}


main() {
    
    chown_dir_mnt_wsl "$@"

    df -hT | grep -E '/mnt/wsl/|Used'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi