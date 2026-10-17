#!/usr/bin/env bash
set -euo pipefail

DEBUG=1
log_debug() {
    if [[ "${DEBUG:-0}" -eq 1 ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

normalize_disk_identifier() {
    local serial_input="${1:-}"
    local devType="${2:-}"
    
    if [ "$devType" = "MsftVHD" ]; then
        # For VHDX files, strip hyphens, convert to lowercase, 
        # and extract the trailing 12 characters matching Linux udev properties
        local clean_guid
        clean_guid=$(echo "$serial_input" | tr -d '-' | tr '[:upper:]' '[:lower:]')
        echo "${clean_guid: -12}"
    else
        # For physical disks, clean up standard serial numbers
        echo "$serial_input" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
    fi
}


get_device_by_serial() {
    local target_serial="$1"
    
    if [ -z "$target_serial" ]; then
        echo "Error: Serial number parameter is empty." >&2
        return 1
    fi

    local dev_name=""

    # Method 1: Check via lsblk
    
    #dev_name=$(lsblk -dno NAME,SERIAL | awk -v serial="$target_serial" '$2 == serial {print $1}')
    # Find device matching the normalized target serial/signature across both SERIAL and WWN columns
    dev_name=$(lsblk -dno NAME,SERIAL,WWN | awk -v target="$target_serial" '
        {
            # Combine columns 2 and 3 and convert to lowercase for universal matching
            combined = tolower($2 " " $3)
            t = tolower(target)
            
            # If the target signature exists anywhere inside the serial/WWN string, match it!
            if (length(t) > 0 && index(combined, t) > 0) {
                print $1
                exit
            }
        }
    ')
    log_debug "===>>> found:$dev_name"
    if [ -n "$dev_name" ]; then
        echo "/dev/$dev_name"
        return 0
    fi

    # Method 2: Fallback check using udevadm
    for disk in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        [ -e "$disk" ] || continue
        
        local id_serial id_serial_short
        id_serial=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep '^ID_SERIAL=' | cut -d'=' -f2)
        id_serial_short=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep '^ID_SERIAL_SHORT=' | cut -d'=' -f2)

        if [ "$id_serial" = "$target_serial" ] || [ "$id_serial_short" = "$target_serial" ]; then
            echo "$disk"
            return 0
        fi
    done

    echo "Error: No device found matching serial number '$target_serial'." >&2
    return 1
}

validate_disk() {
    local dev_path="$1"

    if [ ! -b "$dev_path" ]; then
        echo "Error: Device '$dev_path' is not a valid block device." >&2
        return 1
    fi
}

get_partition_info() {
    local target_device="${1:-}"
    
    # Directly query partition names, sizes, and filesystems in raw format (-r -n)
    lsblk -rn -o NAME,SIZE,FSTYPE,TYPE,PARTLABEL "$target_device" | awk '$4 == "part"' | sort -V
}

main(){
    local serial_input="${1:-}"
    local devType="${2:-}"
    log_debug "[get_device_by_serial] Inputed args:"
    log_debug "serial_input:$serial_input"
    log_debug "devType:$devType"
    if [ -z "$serial_input" ]; then
        echo "Usage: $0 <DiskSerialNumber>"
        exit 1
    fi

    normalized_serial=$(normalize_disk_identifier "$serial_input" "$devType") 
    log_debug "normalized_serial: $normalized_serial "
    local target_device 
    target_device=$(get_device_by_serial "$normalized_serial")
    log_debug " found deive: $target_device"
    validate_disk "$target_device"
    #return 
    get_partition_info $target_device
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi