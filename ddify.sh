#!/bin/sh

set -eu
# BusyBox ash provides pipefail in the rescue environment. The host shell
# may not provide it; destructive installer mode checks it explicitly.
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
NL='
'
export LC_ALL=C

SCRIPT_NAME="${0##*/}"

error() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

info() {
    echo "==> $*" >&2
}

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME freebsd 14|15 [options]
  $SCRIPT_NAME rocky 10 [options]
  $SCRIPT_NAME almalinux 10 [options]
  $SCRIPT_NAME fedora 44 [options]
  $SCRIPT_NAME debian 13 [options]
  $SCRIPT_NAME redhat --img URL [options]

Options:
  --disk DEVICE          Target disk; auto-detected when omitted
  --img URL              Override qcow2/qcow2.xz or FreeBSD raw.xz image URL
  --password PASSWORD    Root password
  --ssh-key KEY          Public key, file, URL, github:user or gitlab:user; repeatable
  --ssh-port PORT        SSH port (default 22)
  --web-port PORT        Write /etc/reinstall-web-port through NoCloud
  --frpc-toml PATH|URL   Embed/download FRPC config
  --post-install-hook P  Run hook after image/NoCloud write

If neither password nor SSH key is given, an empty password prompt generates a random password.
EOF
    exit 0
}

to_lower() {
    printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z'
}

# Match whole metadata lines without Bash's regex operator or capture array.
match_ere() {
    case "$1" in *"$NL"*) return 1 ;; esac
    printf '%s\n' "$1" | grep -Eq -- "$2"
}

to_upper() {
    printf '%s' "$1" | LC_ALL=C tr 'a-z' 'A-Z'
}

prompt_secret() (
    printf '%s' "$1" >&2
    if [ -t 0 ]; then
        saved=$(stty -g) || exit 1
        trap 'stty "$saved" 2>/dev/null || true; printf "\n" >&2' 0
        trap 'exit 130' 2
        trap 'exit 143' 15
        stty -echo || exit 1
    fi
    IFS= read -r secret || exit 1
    printf '%s' "$secret"
)

is_port_valid() {
    match_ere "$1" '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

http_download() {
    local url="$1" dst="$2" tmp
    tmp="${dst}.part.$$"
    { case "$url" in https://*) true ;; *) false ;; esac; } || error "Downloads require HTTPS: $url"
    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fL --progress-bar --proto '=https' --proto-redir '=https' -o "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget --https-only -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    else
        error "Secure download requires curl or wget with --https-only: $url"
    fi

    mv -f "$tmp" "$dst"
}

http_download_stdout() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar --proto '=https' --proto-redir '=https' --tlsv1.2 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -qO- "$1"
    else
        return 1
    fi
}

http_content_length() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsIL --proto '=https' --proto-redir '=https' "$url" | awk '
            /^HTTP\// { n="" }
            /^[Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); n=$2 }
            END { if (n != "") print n }
        '
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget --https-only --server-response --spider "$url" 2>&1 | awk '
            /^[[:space:]]*HTTP\// { n="" }
            /^  [Cc]ontent-[Ll]ength:/ { gsub("\r", "", $2); n=$2 }
            END { if (n != "") print n }
        '
        return 0
    fi

    return 1
}

lsblk_get_kv() {
    local line="$1" key="$2"
    awk -v want="$key" '
        {
            len = length($0)
            i = 1
            while (i <= len) {
                while (i <= len && substr($0, i, 1) == " ") i++
                if (i > len) break

                eq = index(substr($0, i), "=")
                if (eq == 0) break
                eq = i + eq - 1

                k = substr($0, i, eq - i)
                i = eq + 1

                if (substr($0, i, 1) != "\"") break
                i++

                v = ""
                while (i <= len) {
                    c = substr($0, i, 1)
                    if (c == "\\") {
                        i++
                        if (i <= len) v = v substr($0, i, 1)
                    } else if (c == "\"") {
                        i++
                        break
                    } else {
                        v = v c
                    }
                    i++
                }

                if (k == want) {
                    print v
                    exit
                }
            }
        }
    ' <<DDIFY_LSBLK
$line
DDIFY_LSBLK
}

# ----------------- host preparation -----------------

hash_password() {
    command -v openssl >/dev/null 2>&1 || error "Password hashing requires openssl"
    printf '%s\n' "$1" | openssl passwd -6 -stdin
}

detect_os_arch() {
    OS=$(uname -s)
    ARCH=$(uname -m)

    case "$OS" in
        Linux|FreeBSD) ;;
        *) error "Unsupported OS: $OS (only Linux and FreeBSD are supported)" ;;
    esac

    case "$ARCH" in
        x86_64|amd64) MACHINE_ARCH="x86_64" ;;
        aarch64|arm64) MACHINE_ARCH="aarch64" ;;
        *)
            warn "Unknown arch: $ARCH, image URL selection may fail"
            MACHINE_ARCH="$ARCH"
            ;;
    esac
}

LINUX_FAMILY=""

detect_linux_family() {
    local id_val="" id_like_val="" ids=""
    LINUX_FAMILY=""

    [ "$OS" = "Linux" ] || return 0

    if [ -r /etc/os-release ]; then
        id_val="$(
            (
                # shellcheck disable=SC1091
                . /etc/os-release 2>/dev/null
                printf '%s' "${ID:-}"
            ) || true
        )"
        id_like_val="$(
            (
                # shellcheck disable=SC1091
                . /etc/os-release 2>/dev/null
                printf '%s' "${ID_LIKE:-}"
            ) || true
        )"

        ids=" ${id_val} ${id_like_val} "

        case "$ids" in
            *" rhel "*|*" rocky "*|*" almalinux "*|*" centos "*|*" fedora "*)
                LINUX_FAMILY="redhat"
                ;;
            *" debian "*)
                LINUX_FAMILY="debian"
                ;;
            *)
                LINUX_FAMILY=""
                ;;
        esac
    fi
}

have_any_downloader() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

missing_deps_linux_common() {
    command -v xz >/dev/null 2>&1 || printf '%s\n' xz
    command -v openssl >/dev/null 2>&1 || printf '%s\n' openssl
    command -v file >/dev/null 2>&1 || printf '%s\n' file
    command -v tar >/dev/null 2>&1 || printf '%s\n' tar
    have_any_downloader || printf '%s\n' downloader
    return 0
}

missing_deps_freebsd_host() {
    missing_deps_linux_common
    command -v efibootmgr >/dev/null 2>&1 || printf '%s\n' efibootmgr
    return 0
}

install_host_dependencies() {
    local family="$1" item packages=""
    shift
    for item in "$@"; do
        case "$family:$item" in
            debian:xz) packages="$packages xz-utils" ;;
            *:downloader) packages="$packages curl" ;;
            freebsd:tar) error "FreeBSD base tar is unavailable" ;;
            freebsd:efibootmgr) error "FreeBSD base efibootmgr is unavailable" ;;
            *:xz|*:file|*:tar|*:openssl) packages="$packages $item" ;;
            *) error "Unrecognized dependency: $item" ;;
        esac
    done
    [ -n "$packages" ] || return 0
    info "Installing host dependencies:$packages"
    # Package tokens above are fixed literals, never user-supplied arguments.
    case "$family" in
        redhat) dnf install -y $packages ;;
        debian) apt-get update && apt-get install -y $packages ;;
        freebsd) ASSUME_ALWAYS_YES=yes pkg install $packages ;;
        *) error "Unsupported host dependency manager: $family" ;;
    esac
}

ensure_dependencies() {
    local missing family
    if [ "$OS" = Linux ]; then
        [ ! -f /etc/alpine-release ] || return 0
        detect_linux_family
        family=$LINUX_FAMILY
        missing=$(missing_deps_linux_common)
    else
        family=freebsd
        missing=$(missing_deps_freebsd_host)
    fi
    [ -n "$missing" ] || return 0
    install_host_dependencies "$family" $missing
    if [ "$OS" = Linux ]; then missing=$(missing_deps_linux_common)
    else missing=$(missing_deps_freebsd_host); fi
    [ -z "$missing" ] || error "Missing host dependencies: $missing"
}

AUTO_DETECTED_DISK=""
AUTO_DETECT_REASON=""
DISK_CANDIDATE_LINES=""
DISK_CANDIDATE_PATHS=""
DISK_AUTO_SELECTED=0
DISK_ID_WWN=""
DISK_ID_SERIAL=""
DISK_ID_SIZE=""
DISK_ID_MODEL=""
DISK_ID_PTUUID=""
DISK_ID_MBR_ID=""
DISK_ID_ANCHOR_PARTUUID=""

validate_target_disk() {
    local disk="$1" typ d

    [ -n "$disk" ] || error "Target disk is empty"

    if [ "$OS" = "Linux" ]; then
        [ -b "$disk" ] || error "Target disk $disk is not a block device"
        command -v lsblk >/dev/null 2>&1 || error "lsblk is required to validate the target disk on Linux"
        typ=$(lsblk -ndo TYPE "$disk" 2>/dev/null | head -n1 || true)
        [ "$typ" = "disk" ] || error "Target $disk is not a whole disk (lsblk TYPE=${typ:-unknown})"
        return 0
    fi

    { [ -c "$disk" ] || [ -b "$disk" ]; } || error "Target disk $disk does not exist"
    d="${disk#/dev/}"
    command -v sysctl >/dev/null 2>&1 || error "sysctl is required to validate the target disk on FreeBSD"
    case " $(sysctl -n kern.disks 2>/dev/null || true) " in
        *" $d "*) ;;
        *) error "Target $disk is not a whole disk listed by kern.disks" ;;
    esac
}

normalize_disk_wwn() {
    local v="${1:-}"
    v=$(printf '%s' "$v" | tr 'A-Z' 'a-z' | tr -d '[:space:]:-')
    v="${v#0x}"
    v="${v#naa.}"
    printf '%s\n' "$v"
}

freebsd_disk_partition_uuids() {
    local d="${1#/dev/}"
    local inventory
    inventory=$(gpart list "$d" 2>/dev/null) || return 1
    printf '%s\n' "$inventory" | awk -v disk="$d" '
        /^[[:space:]]*[0-9]+\. Name:/ { provider=$3 }
        /^[[:space:]]*rawuuid:/ {
            prefix=disk "p"
            if (index(provider, prefix) == 1 &&
                substr(provider, length(prefix) + 1) ~ /^[0-9]+$/) {
                print tolower($2)
            }
        }
    '
}

capture_target_disk_identity() {
    local disk="$1" line d

    DISK_ID_WWN=""
    DISK_ID_SERIAL=""
    DISK_ID_SIZE=""
    DISK_ID_MODEL=""
    DISK_ID_PTUUID=""
    DISK_ID_MBR_ID=""
    DISK_ID_ANCHOR_PARTUUID=""

    if [ "$OS" = "Linux" ]; then
        line=$(lsblk -b -dn -P -o WWN,SERIAL,SIZE,MODEL "$disk" 2>/dev/null | head -n1 || true)
        [ -n "$line" ] || error "Failed to read target disk identity: $disk"
        DISK_ID_WWN=$(normalize_disk_wwn "$(lsblk_get_kv "$line" "WWN")")
        DISK_ID_SERIAL=$(lsblk_get_kv "$line" "SERIAL")
        DISK_ID_SIZE=$(lsblk_get_kv "$line" "SIZE")
        DISK_ID_MODEL=$(lsblk_get_kv "$line" "MODEL")
        if [ "$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)" = gpt ]; then
            DISK_ID_PTUUID=$(blkid -s PTUUID -o value "$disk" 2>/dev/null || true)
        elif [ "$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)" = dos ]; then
            DISK_ID_MBR_ID=$(blkid -s PTUUID -o value "$disk" 2>/dev/null || true)
            { match_ere "$DISK_ID_MBR_ID" '^[[:xdigit:]]{8}$' && [ "$(to_lower "$DISK_ID_MBR_ID")" != 00000000 ]; } || DISK_ID_MBR_ID=""
        fi
    else
        d="${disk#/dev/}"
        DISK_ID_ANCHOR_PARTUUID=$(freebsd_disk_partition_uuids "$disk" | sed -n '1p')
        match_ere "$DISK_ID_ANCHOR_PARTUUID" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' || \
            error "Cannot capture FreeBSD GPT partition UUID for cross-OS disk verification"
        if command -v diskinfo >/dev/null 2>&1; then
            DISK_ID_SERIAL=$(diskinfo -s "$disk" 2>/dev/null | head -n1 || true)
            DISK_ID_SIZE=$(diskinfo "$disk" 2>/dev/null | awk 'NR==1 {print $3; exit}' || true)
        fi
        if command -v geom >/dev/null 2>&1; then
            DISK_ID_WWN=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*lunid:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
            DISK_ID_WWN=$(normalize_disk_wwn "$DISK_ID_WWN")
            DISK_ID_MODEL=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*descr:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
        fi
    fi

    { match_ere "$DISK_ID_SIZE" '^[0-9]+$' && [ "$DISK_ID_SIZE" -gt 0 ]; } ||
        error "Unable to read target disk size"
    { [ -z "$DISK_ID_PTUUID" ] || match_ere "$DISK_ID_PTUUID" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'; } ||
        error "Target disk GPT GUID is invalid; refusing unattended reinstallation"
    { [ -n "$DISK_ID_SERIAL" ] || [ -n "$DISK_ID_WWN" ] || [ -n "$DISK_ID_PTUUID" ] || [ -n "$DISK_ID_MBR_ID" ] || [ -n "$DISK_ID_ANCHOR_PARTUUID" ]; } || \
        error "Target disk lacks a usable WWN, serial, GPT GUID or MBR signature"

    if { [ -n "$DISK_ID_MBR_ID" ] && [ -z "$DISK_ID_WWN$DISK_ID_SERIAL" ]; }; then
        warn "Using a 32-bit MBR disk signature as fallback identity; cloned disks must be disconnected"
    fi
    info "Target disk identity: serial=${DISK_ID_SERIAL:-unknown} wwn=${DISK_ID_WWN:-unknown} size=${DISK_ID_SIZE:-unknown}"
    [ -z "$DISK_ID_ANCHOR_PARTUUID" ] || info "Portable GPT partition identity: $DISK_ID_ANCHOR_PARTUUID"
}

list_disk_identities() {
    local line path type wwn serial size model ptuuid="" mbr_id="" d

    if [ "$OS" = Linux ]; then
        while IFS= read -r line; do
            type=$(lsblk_get_kv "$line" TYPE)
            [ "$type" = disk ] || continue
            path=$(lsblk_get_kv "$line" PATH)
            wwn=$(normalize_disk_wwn "$(lsblk_get_kv "$line" WWN)")
            serial=$(lsblk_get_kv "$line" SERIAL)
            size=$(lsblk_get_kv "$line" SIZE)
            model=$(lsblk_get_kv "$line" MODEL)
            ptuuid=""; mbr_id=""
            if [ "$(blkid -s PTTYPE -o value "$path" 2>/dev/null || true)" = gpt ]; then
                ptuuid=$(blkid -s PTUUID -o value "$path" 2>/dev/null || true)
            elif [ "$(blkid -s PTTYPE -o value "$path" 2>/dev/null || true)" = dos ]; then
                mbr_id=$(blkid -s PTUUID -o value "$path" 2>/dev/null || true)
                { match_ere "$mbr_id" '^[[:xdigit:]]{8}$' && [ "$(to_lower "$mbr_id")" != 00000000 ]; } || mbr_id=""
            fi
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$path" "$wwn" "$serial" "$size" "$model" "$ptuuid" "$mbr_id"
        done <<DDIFY_INPUT_1
$(lsblk -b -dn -P -o PATH,TYPE,WWN,SERIAL,SIZE,MODEL 2>/dev/null)
DDIFY_INPUT_1
        return
    fi

    for d in $(sysctl -n kern.disks 2>/dev/null || true); do
        path="/dev/$d"
        serial=$(diskinfo -s "$path" 2>/dev/null | head -n1 || true)
        size=$(diskinfo "$path" 2>/dev/null | awk 'NR==1 {print $3; exit}')
        wwn=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*lunid:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
        model=$(geom disk list "$d" 2>/dev/null | awk -F: '/^[[:space:]]*descr:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' || true)
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$path" "$(normalize_disk_wwn "$wwn")" "$serial" "$size" "$model" "$ptuuid" ""
    done
}

disk_contains_anchor_partuuid() {
    local disk="$1" want uuids count
    want=$(to_lower "$2") || return 1
    [ -n "$want" ] || return 1
    if [ "$OS" = FreeBSD ]; then
        uuids=$(freebsd_disk_partition_uuids "$disk") || return 1
    else
        uuids=$(lsblk -rn -o TYPE,PARTUUID "$disk" 2>/dev/null | awk '$1 == "part" && $2 != "" { print tolower($2) }') || return 1
    fi
    count=$(printf '%s\n' "$uuids" | awk -v want="$want" 'tolower($0) == want { n++ } END { print n+0 }')
    [ "$count" = 1 ]
}

disk_identity_matches() {
    local wwn="$1" serial="$2" size="$3" model="$4" ptuuid="${5:-}" mbr_id="${6:-}" pair stored current hit=0
    { [ -n "${DISK_ID_SIZE:-}" ] && [ "$size" = "$DISK_ID_SIZE" ]; } || return 1
    for pair in "${DISK_ID_WWN:-}|$wwn" "${DISK_ID_SERIAL:-}|$serial" "$(to_lower "$DISK_ID_PTUUID")|$(to_lower "$ptuuid")" "$(to_lower "$DISK_ID_MBR_ID")|$(to_lower "$mbr_id")"; do
        stored=${pair%%|*}; current=${pair#*|}
        { [ -n "$stored" ] && [ -n "$current" ]; } || continue
        [ "$stored" = "$current" ] || return 1
        hit=1
    done
    [ "$(( hit ))" -ne 0 ]
}

resolve_target_disk_from_identity() {
    local path wwn serial size model ptuuid mbr_id
    local matches=0 matched_disk=""
    [ -n "${DISK_ID_WWN:-}${DISK_ID_SERIAL:-}${DISK_ID_PTUUID:-}${DISK_ID_MBR_ID:-}${DISK_ID_ANCHOR_PARTUUID:-}" ] || \
        error "No strong target disk identity recorded; refusing destructive write"
    { [ -z "${DISK_ID_ANCHOR_PARTUUID:-}" ] || match_ere "$DISK_ID_ANCHOR_PARTUUID" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'; } || \
        error "Invalid saved GPT partition identity"
    # Native FreeBSD uses GEOM and diskinfo directly. Do not round-trip
    # empty WWN/serial fields through a delimited read on different shells.
    if [ "$OS" = FreeBSD ]; then
        local native_disk native_size native_serial
        for native_disk in $(sysctl -n kern.disks 2>/dev/null); do
            path="/dev/$native_disk"
            [ -c "$path" ] || [ -b "$path" ] || continue
            native_size=$(get_disk_size_bytes "$path") || continue
            [ "$native_size" = "$DISK_ID_SIZE" ] || continue
            disk_contains_anchor_partuuid "$path" "$DISK_ID_ANCHOR_PARTUUID" || continue
            native_serial=$(diskinfo -s "$path" 2>/dev/null || true)
            if [ -n "$DISK_ID_SERIAL" ]; then
                [ "$native_serial" = "$DISK_ID_SERIAL" ] || continue
            fi
            matches=$((matches + 1))
            matched_disk=$path
        done
    else
    while IFS='|' read -r path wwn serial size model ptuuid mbr_id; do
        if [ -n "${DISK_ID_ANCHOR_PARTUUID:-}" ]; then
            [ "$size" = "$DISK_ID_SIZE" ] || continue
            disk_contains_anchor_partuuid "$path" "$DISK_ID_ANCHOR_PARTUUID" || continue
            # An available serial is a second identity check; never accept a
            # mismatched physical disk merely because a GPT was cloned.
            if [ -n "$DISK_ID_SERIAL" ] && [ -n "$serial" ]; then
                [ "$DISK_ID_SERIAL" = "$serial" ] || continue
            fi
            matches=$((matches + 1))
            matched_disk=$path
        else
            disk_identity_matches "$wwn" "$serial" "$size" "$model" "$ptuuid" "$mbr_id" && { matches=$((matches + 1)); matched_disk=$path; }
        fi
    done <<DDIFY_INPUT_2
$(list_disk_identities)
DDIFY_INPUT_2
    fi

    [ "$matches" -eq 1 ] || error "Saved target identity matched $matches disks; refusing destructive write"
    { [ -z "${DISK:-}" ] || [ "$DISK" = "$matched_disk" ]; } || info "Target disk path changed: $DISK -> $matched_disk"
    DISK="$matched_disk"
}

get_disk_size_bytes() {
    local disk="$1"
    if [ "$OS" = "Linux" ]; then
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --getsize64 "$disk" 2>/dev/null && return 0
        fi
        lsblk -b -dn -o SIZE "$disk" 2>/dev/null | head -n1
        return 0
    fi
    diskinfo "$disk" 2>/dev/null | awk 'NR==1 {print $3; exit}'
}

# Rescue runs from RAM. A busy target is unexpected: never unmount or
# deactivate unknown storage automatically, and never treat a failed query as empty.
assert_target_disk_idle() {
    local disk="$1" nodes mounts swaps id dev sys holder member member_id
    [ "$OS" = Linux ] || error "Disk commit must run in Linux rescue"
    nodes=$(lsblk -nr -o MAJ:MIN "$disk") || error "Cannot enumerate target disk devices"
    [ -n "$nodes" ] || error "Empty target disk inventory"
    mounts=$(findmnt -krn -o MAJ:MIN) || error "Cannot read kernel mount inventory"
    swaps=$(awk 'NR > 1 {print $1}' /proc/swaps) || error "Cannot read swap inventory"
    for id in $nodes; do
        match_ere "$id" '^[0-9]+:[0-9]+$' || error "Invalid target device number"
        sys="/sys/dev/block/$id"
        [ -d "$sys/holders" ] || error "Missing target sysfs holder inventory: $id"
        if printf '%s\n' "$mounts" | grep -Fx "$id" >/dev/null; then
            error "Target device $id is mounted; refusing disk commit"
        fi
        for holder in "$sys/holders/"*; do
            [ ! -e "$holder" ] || error "Target device $id has active block holders"
        done
        # A multi-device Btrfs mount can report a different member in mountinfo.
        for member in /sys/fs/btrfs/*/devices/*/dev; do
            [ -e "$member" ] || continue
            member_id=$(cat "$member") || error "Cannot inspect Btrfs member"
            [ "$member_id" != "$id" ] || error "Target device $id belongs to active Btrfs"
        done
    done
    for dev in $swaps; do
        if [ -b "$dev" ]; then
            id=$(lsblk -dnr -o MAJ:MIN "$dev") || error "Cannot identify active swap: $dev"
            if printf '%s\n' "$nodes" | grep -Fx "$id" >/dev/null; then
                error "Target disk has active swap: $dev"
            fi
        elif [ -f "$dev" ]; then
            id=$(findmnt -kn -o MAJ:MIN --target "$dev") || error "Cannot identify swap file filesystem"
            if printf '%s\n' "$nodes" | grep -Fx "$id" >/dev/null; then
                error "Target disk contains active swap file: $dev"
            fi
        else
            error "Cannot identify active swap device or file: $dev"
        fi
    done
}

linux_source_to_disk() {
    local src="${1%%\[*}" name typ
    local disks=0 selected_disk=""
    [ -b "$src" ] || return 1
    while read -r name typ; do
        [ "$typ" = disk ] && { disks=$((disks + 1)); selected_disk=$name; }
    done <<DDIFY_INPUT_9
$(lsblk -s -l -n -p -o NAME,TYPE "$src" 2>/dev/null | awk '!seen[$1]++')
DDIFY_INPUT_9
    [ "$disks" -eq 1 ] || return 1
    printf '%s\n' "$selected_disk"
}

linux_find_mount_source() {
    local mnt="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o SOURCE --mountpoint "$mnt" 2>/dev/null | head -n1 || true
    fi
}

linux_current_root_disk() {
    local src
    src=$(linux_find_mount_source "/")
    [ -n "$src" ] || return 1
    linux_source_to_disk "$src"
}

linux_current_boot_disk() {
    local src
    src=$(linux_find_mount_source "/boot")
    [ -n "$src" ] || return 1
    linux_source_to_disk "$src"
}

linux_current_efi_disk() {
    local src
    src=$(linux_find_mount_source "/boot/efi")
    [ -n "$src" ] || return 1
    linux_source_to_disk "$src"
}

is_mountpoint() {
    local path="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path" 2>/dev/null
        return $?
    fi

    mount -p 2>/dev/null | awk -v mp="$path" '
        $2 == mp {
            found=1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

freebsd_mount_source_for() {
    local mountpoint="$1"

    mount -p 2>/dev/null | awk -v mp="$mountpoint" '
        $2 == mp {
            print $1
            exit
        }
    '
}

freebsd_provider_to_disk() {
    local source="$1"
    local provider disks d resolved=""

    [ -n "$source" ] || return 1
    provider="${source#/dev/}"
    disks=$(sysctl -n kern.disks 2>/dev/null || true)
    [ -n "$disks" ] || return 1

    for d in $disks; do
        case "$provider" in
            "$d"|"$d"p[0-9]*|"$d"s[0-9]*)
                printf '/dev/%s\n' "$d"
                return 0
                ;;
        esac
    done

    if command -v geom >/dev/null 2>&1; then
        resolved=$(
            geom -t 2>/dev/null | awk -v target="$provider" '
                /^[^[:space:]]/ && $2 == "DISK" {
                    disk=$1
                }
                {
                    for (i = 1; i <= NF; i++) {
                        if ($i == target && disk != "") {
                            print "/dev/" disk
                            exit
                        }
                    }
                }
            '
        )
        if [ -n "$resolved" ]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    fi

    return 1
}

print_disk_candidates() {
    [ -n "$DISK_CANDIDATE_LINES" ] || return 0
    echo
    echo "Detected target disk candidates:"
    printf '%s\n' "$DISK_CANDIDATE_LINES"
    echo
    echo "Recommended disk: $AUTO_DETECTED_DISK"
    echo "Reason: $AUTO_DETECT_REASON"
    echo
}

candidate_add() {
    local path="$1" size="$2" tags="${3:-}" note="${4:-}" line
    DISK_CANDIDATE_COUNT=$((DISK_CANDIDATE_COUNT + 1))
    line=$(printf '  [%d] %-16s size=%s bytes' "$DISK_CANDIDATE_COUNT" "$path" "$size")
    [ -z "$tags" ] || line="$line markers:$tags"
    [ -z "$note" ] || line="$line ($note)"
    DISK_CANDIDATE_LINES="${DISK_CANDIDATE_LINES:+$DISK_CANDIDATE_LINES$NL}$line"
    DISK_CANDIDATE_PATHS="$DISK_CANDIDATE_PATHS $path"
}

select_detected_disk() {
    DISK="$1"
    AUTO_DETECTED_DISK="$1"
    AUTO_DETECT_REASON="$2"
    DISK_AUTO_SELECTED=1
    info "Auto-detected disk: $DISK ($AUTO_DETECT_REASON)"
}

auto_detect_linux_disk() {
    local root boot efi preferred reason="" name type rm size path tags

    command -v lsblk >/dev/null 2>&1 || error "lsblk is required for Linux disk auto-detection"

    root=$(linux_current_root_disk || true)
    boot=$(linux_current_boot_disk || true)
    efi=$(linux_current_efi_disk || true)

    [ -z "$root" ] || info "Current /: $root"
    [ -z "$boot" ] || info "Current /boot: $boot"
    [ -z "$efi" ] || info "Current EFI: $efi"

    if { [ -n "$root" ] && [ "$root" = "$boot" ] && [ "$root" = "$efi" ]; }; then
        preferred="$root"; reason="/, /boot and EFI resolve to this disk"
    elif [ -n "$root" ]; then
        preferred="$root"; reason="current / resolves to this disk"
    elif [ -n "$boot" ]; then
        preferred="$boot"; reason="current /boot resolves to this disk"
    else
        preferred="$efi"; reason="current EFI resolves to this disk"
    fi

    while read -r name type rm size; do
        { [ "$type" = disk ] && [ "$rm" = 0 ]; } || continue
        path="/dev/$name"
        tags=""
        [ "$path" != "$root" ] || tags="$tags root"
        [ "$path" != "$boot" ] || tags="$tags boot"
        [ "$path" != "$efi" ] || tags="$tags efi"
        [ "$path" != "$preferred" ] || tags="$tags recommended"
        candidate_add "$path" "$size" "$tags" "$([ "$path" = "$preferred" ] && echo "$reason")"
    done <<DDIFY_INPUT_10
$(lsblk -b -ndo NAME,TYPE,RM,SIZE 2>/dev/null)
DDIFY_INPUT_10

    [ -n "$preferred" ] || error "Unable to identify the current Linux system disk; use --disk"
    select_detected_disk "$preferred" "$reason"
}

auto_detect_freebsd_disk() {
    local disks root_source root_disk d size count=0 only="" tags note
    disks=$(sysctl -n kern.disks 2>/dev/null || true)
    [ -n "$disks" ] || error "kern.disks is empty; use --disk"

    root_source=$(freebsd_mount_source_for "/" || true)
    root_disk=$(freebsd_provider_to_disk "$root_source" || true)
    [ -z "$root_source" ] || info "Current /: $root_source"
    [ -z "$root_disk" ] || info "Current / through GEOM: $root_disk"

    for d in $disks; do
        case "$d" in cd*|md*|lo*|ram*) continue ;; esac
        size=$(diskinfo "/dev/$d" 2>/dev/null | awk 'NR==1 {print $3; exit}')
        size=${size:-0}
        count=$((count + 1)); only="/dev/$d"; tags=""; note=""
        if [ "$only" = "$root_disk" ]; then
            tags=" root recommended"
            note="current / resolves through GEOM to this disk"
        fi
        candidate_add "$only" "$size" "$tags" "$note"
    done

    if [ -n "$root_disk" ] && printf '%s\n' "$disks" | grep -qw "${root_disk#/dev/}"; then
        select_detected_disk "$root_disk" "current / resolves through FreeBSD GEOM to this disk"
        return
    fi
    [ "$count" = 1 ] && { select_detected_disk "$only" "only usable physical disk"; return; }
    error "Unable to identify the FreeBSD system disk confidently; use --disk"
}

auto_detect_disk() {
    info "Auto-detecting target disk..."
    DISK_CANDIDATE_LINES=""
    DISK_CANDIDATE_PATHS=""
    DISK_CANDIDATE_COUNT=0
    AUTO_DETECTED_DISK=""
    AUTO_DETECT_REASON=""
    DISK_AUTO_SELECTED=0

    case "$OS" in
        Linux)   auto_detect_linux_disk ;;
        FreeBSD) auto_detect_freebsd_disk ;;
    esac
}

show_partition_info() {
    echo
    echo "---------------- Disk partition layout ----------------"
    if [ "$OS" = "Linux" ]; then
        if command -v lsblk >/dev/null 2>&1; then
            lsblk "$DISK" || true
        elif command -v fdisk >/dev/null 2>&1; then
            fdisk -l "$DISK" || true
        else
            echo "Could not show partition info (no lsblk/fdisk)."
        fi
    else
        if command -v gpart >/dev/null 2>&1; then
            local d="${DISK#/dev/}"
            gpart show "$d" 2>/dev/null || gpart show "$DISK" 2>/dev/null || echo "Could not show partition info with gpart."
        else
            echo "Could not show partition info (no gpart)."
        fi
    fi
    echo "-------------------------------------------------------"
}

run_post_install_hook() {
    if [ -z "${POST_INSTALL_HOOK:-}" ]; then
        return 0
    fi

    if ! [ -f "$POST_INSTALL_HOOK" ]; then
        warn "Post-install hook not found: $POST_INSTALL_HOOK"
        return 0
    fi

    info "Running explicit post-install hook: $POST_INSTALL_HOOK"
    if ! sh "$POST_INSTALL_HOOK"; then
        error "Post-install hook failed: $POST_INSTALL_HOOK"
    fi
}

parse_ssh_key() {
    local val="$1" url="" text=""
    case "$(to_lower "$val")" in
        github:*|gitlab:*)
            local site user
            site="${val%%:*}"; user="${val#*:}"
            match_ere "$user" '^[A-Za-z0-9_-]+$' || error "Invalid public-key username"
            url="https://$(to_lower "$site").com/${user}.keys" ;;
        https://*) url="$val" ;;
        http://*) error "SSH key URLs must use HTTPS" ;;
    esac
    if [ -n "$url" ]; then
        text=$(http_download_stdout "$url") || error "Unable to download public keys"
    elif [ -f "$val" ]; then
        text=$(cat -- "$val")
    else
        text="$val"
    fi
    local line tmp fingerprint accepted=""
    command -v ssh-keygen >/dev/null 2>&1 || error "ssh-keygen is needed to validate SSH public keys"
    tmp=$(mktemp "${TMPDIR:-/tmp}/ddify-sshkey.XXXXXX") || error "Cannot create temporary SSH-key file"
    chmod 0600 "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$(printf '\r')}"
        { [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] || { case "$line" in \#*) true ;; *) false ;; esac; }; } && continue
        if ! match_ere "$line" '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$'; then
            rm -f "$tmp"
            error "Unsupported or malformed SSH public key"
        fi
        printf '%s\n' "$line" >"$tmp"
        fingerprint=$(ssh-keygen -l -f "$tmp" 2>/dev/null) || {
            rm -f "$tmp"
            error "SSH public key failed cryptographic encoding validation"
        }
        info "Validated SSH public key: $fingerprint"
        accepted="${accepted:+$accepted$NL}$line"
    done <<DDIFY_INPUT_17
$text
DDIFY_INPUT_17
    rm -f "$tmp"
    [ -n "$accepted" ] || error "No supported SSH public key in input"
    printf '%s\n' "$accepted"
}

get_default_image_url() {
    local key="$1:$2:$MACHINE_ARCH"

    case "$key" in
        freebsd:14:x86_64)  echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/amd64/Latest/FreeBSD-14.5-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz" ;;
        freebsd:14:aarch64) echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/aarch64/Latest/FreeBSD-14.5-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.raw.xz" ;;
        freebsd:15:x86_64)  echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz" ;;
        freebsd:15:aarch64) echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/aarch64/Latest/FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.raw.xz" ;;
        rocky:10:x86_64)    echo "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2" ;;
        rocky:10:aarch64)   echo "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2" ;;
        almalinux:10:x86_64)  echo "https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2" ;;
        almalinux:10:aarch64) echo "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2" ;;
        fedora:44:x86_64)   echo "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2" ;;
        fedora:44:aarch64)  echo "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2" ;;
        debian:13:x86_64)   echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2" ;;
        debian:13:aarch64)  echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2" ;;
        redhat::*)           echo "" ;;
        *) error "No built-in image for $1 $2 on $MACHINE_ARCH; use --img URL" ;;
    esac
}

# ----------------- NoCloud seed -----------------

emit_ssh_keys() {
    local indent="$1" key
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        key=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '%s- "%s"\n' "$indent" "$key"
    done <<DDIFY_INPUT_18
$SSH_KEYS_ALL
DDIFY_INPUT_18
}

# Use a consistent hostname in the offline target and NoCloud metadata.
# Fedora cloud-init 25.3 can call hostnamectl before the system bus exists.
seed_hostname() {
    case "$1" in
        rocky|almalinux|fedora|debian|redhat|freebsd) printf 'ddify-%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

seed_account_linux() {
    local hostname
    hostname=$(seed_hostname "$1") || error "Invalid target OS for hostname"
    cat <<EOF
preserve_hostname: true
hostname: $hostname
prefer_fqdn_over_hostname: false
growpart:
  mode: auto
  devices: [/]
resize_rootfs: true
EOF

    { [ -n "$PASSWORD_HASH" ] || [ -n "$SSH_KEYS_ALL" ]; } || return 0
    echo "ssh_pwauth: $([ -n "$PASSWORD_HASH" ] && echo true || echo false)"
    echo "disable_root: false"
    echo "users:"
    echo "  - name: root"
    if [ -n "$PASSWORD_HASH" ]; then
        echo "    lock_passwd: false"
        echo "    hashed_passwd: \"${PASSWORD_HASH}\""
    else
        echo "    lock_passwd: true"
    fi
    [ -n "$SSH_KEYS_ALL" ] || return 0
    echo "    ssh_authorized_keys:"
    emit_ssh_keys "      "
}

seed_write_files() {
    local os="$1" frpc_b64="$2" frpc_path="/etc/frp/frpc.toml" owner="root:root"
    if [ "$os" = freebsd ]; then
        frpc_path="/etc/frpc.toml"
        owner="root:wheel"
    fi
    { [ -n "$WEB_PORT" ] || [ -n "$frpc_b64" ]; } || return 0

    echo
    echo "write_files:"

    [ -z "$WEB_PORT" ] || cat <<EOF
  - path: /etc/reinstall-web-port
    permissions: '0644'
    owner: ${owner}
    content: |
      $WEB_PORT
EOF

    [ -z "$frpc_b64" ] || cat <<EOF
  - path: ${frpc_path}
    permissions: '0600'
    owner: ${owner}
    encoding: b64
    content: $frpc_b64
EOF
}

seed_runcmd_ssh_port() {
    { [ "$1" = "freebsd" ] || [ -n "$PASSWORD_HASH" ] || [ -n "$SSH_KEYS_ALL" ] || [ -n "$SSH_PORT" ]; } || return 0
    local permit="prohibit-password" auth="no" port="${SSH_PORT:-22}"
    [ -z "$PASSWORD_HASH" ] || { permit="yes"; auth="yes"; }
    cat <<EOF
  - |
      (
      cfg=/etc/ssh/sshd_config
      tmp= backup= backup_ready=0 selinux_added=0 firewall_added=0 firewall_zone= ufw_added=0 socket_override=
      ddify_rollback() {
          rc=\$?
          if [ "\$rc" -ne 0 ]; then
              [ "\$backup_ready" = 0 ] || cat "\$backup" > "\$cfg"
              if [ -n "\$socket_override" ]; then
                  rm -f "\$socket_override"
                  systemctl daemon-reload && systemctl restart ssh.socket || true
              fi
              [ "\$selinux_added" = 0 ] || semanage port -d -p tcp $port 2>/dev/null || true
              if [ "\$firewall_added" = 1 ]; then
                  firewall-cmd --permanent --zone="\$firewall_zone" --remove-port=$port/tcp >/dev/null 2>&1 || true
                  firewall-cmd --reload >/dev/null 2>&1 || true
              fi
              [ "\$ufw_added" = 0 ] || ufw --force delete allow $port/tcp >/dev/null 2>&1 || true
              (systemctl restart sshd || systemctl restart ssh || service sshd restart || service ssh restart) >/dev/null 2>&1 || true
          fi
          [ -z "\$tmp" ] || rm -f "\$tmp"
          [ -z "\$backup" ] || rm -f "\$backup"
      }
      trap ddify_rollback EXIT
      [ -f "\$cfg" ] || exit 1
      backup=\$(mktemp) || exit 1
      cp "\$cfg" "\$backup" || exit 1
      backup_ready=1
      tmp=\$(mktemp) || exit 1
      awk '
          BEGIN { print "PermitRootLogin $permit"; print "PasswordAuthentication $auth"; print "KbdInteractiveAuthentication $auth"; print "PubkeyAuthentication yes"; print "Port $port" }
          /^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|Port)[[:space:]]+/ { next }
          { print }
      ' "\$cfg" > "\$tmp" || exit 1
      if [ "$port" != 22 ] && command -v getenforce >/dev/null 2>&1 && [ "\$(getenforce)" = Enforcing ]; then
          if ! command -v semanage >/dev/null 2>&1; then
              (dnf install -y policycoreutils-python-utils || yum install -y policycoreutils-python-utils) >/dev/null 2>&1 || exit 1
          fi
          if semanage port -a -t ssh_port_t -p tcp $port 2>/dev/null; then
              selinux_added=1
          else
              semanage port -l | awk -v p="$port" '\$1=="ssh_port_t" && \$2=="tcp" {for(i=3;i<=NF;i++){gsub(",","",\$i);if(\$i==p) found=1}} END {exit !found}' || exit 1
          fi
      fi
      if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
          iface=
          if command -v ip >/dev/null 2>&1; then
              iface=\$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if(\$i=="dev") {print \$(i+1); exit}}')
              [ -n "\$iface" ] || iface=\$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if(\$i=="dev") {print \$(i+1); exit}}')
          fi
          firewall_zone=
          [ -z "\$iface" ] || firewall_zone=\$(firewall-cmd --get-zone-of-interface="\$iface" 2>/dev/null || true)
          [ -n "\$firewall_zone" ] || firewall_zone=\$(firewall-cmd --get-default-zone) || exit 1
          if ! firewall-cmd --permanent --zone="\$firewall_zone" --query-port=$port/tcp >/dev/null 2>&1; then
              firewall-cmd --permanent --zone="\$firewall_zone" --add-port=$port/tcp || exit 1
              firewall_added=1
          fi
          firewall-cmd --reload || exit 1
      fi
      if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
          if ! ufw status | grep -Eq "^[[:space:]]*$port/tcp([[:space:]]|\$)"; then
              ufw allow $port/tcp || exit 1
              ufw_added=1
          fi
      fi
      ddify_restart_ssh() {
          if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssh.socket; then
              systemctl daemon-reload && systemctl restart ssh.socket || return 1
              if [ "$port" != 22 ] && ! systemctl show -p Listen --value ssh.socket | tr ' ' '\n' | grep -Eq ":${port}\$"; then
                  socket_path=/etc/systemd/system/ssh.socket.d/90-ddify-port.conf
                  [ ! -e "\$socket_path" ] && [ ! -L "\$socket_path" ] || return 1
                  socket_override=\$socket_path
                  mkdir -p /etc/systemd/system/ssh.socket.d || return 1
                  printf '[Socket]\nListenStream=\nBindIPv6Only=both\nListenStream=%s\n' "$port" > "\$socket_override" || return 1
                  systemctl daemon-reload && systemctl restart ssh.socket || return 1
                  systemctl show -p Listen --value ssh.socket | tr ' ' '\n' | grep -Eq ":${port}\$" || return 1
              fi
              return 0
          fi
          systemctl restart sshd || systemctl restart ssh || service sshd restart || service ssh restart
      }
      sshd -t -f "\$tmp" && cat "\$tmp" > "\$cfg" && sshd -t && ddify_restart_ssh || exit 1
      ) || { ddify_ssh_failed=1; echo "DDify: SSH configuration failed; check cloud-init logs" >&2; }
EOF
}

seed_runcmd_expand_root() {
    if [ "$1" = freebsd ]; then
        cat <<'EOF'
  - |
      rootdev=$(mount -p | awk '$2=="/" {print $1; exit}')
      if command -v fstyp >/dev/null 2>&1 && [ "$(fstyp "$rootdev" 2>/dev/null)" = ufs ]; then
          growfs -y / || echo "DDify: FreeBSD UFS expansion needs inspection" >&2
      fi
EOF
        return
    fi
    cat <<'EOF'
  - |
      # Root-only LVM: extend a single-PV, single-LV volume group after partition growth.
      if command -v lvs >/dev/null 2>&1 && command -v pvs >/dev/null 2>&1 &&
         command -v pvresize >/dev/null 2>&1 && command -v lvextend >/dev/null 2>&1; then
          rootdev=$(findmnt -n -o SOURCE --mountpoint / 2>/dev/null)
          vg=$(lvs --noheadings -o vg_name "$rootdev" 2>/dev/null | xargs)
          if [ -n "$vg" ] && [ "$(lvs --noheadings -o lv_name "$vg" | wc -l)" -eq 1 ]; then
              pv=$(pvs --noheadings -o pv_name --select "vg_name=$vg" | xargs)
              case "$pv" in
                  /dev/*) if [ "${pv#* }" = "$pv" ]; then
                      pvresize "$pv" && lvextend -r -l +100%FREE "$rootdev" ||
                          echo "DDify: LVM root expansion unavailable or already complete" >&2
                  fi ;;
              esac
          fi
      fi
EOF
}

seed_runcmd_frpc() {
    local os="$1" frpc_b64="$2" frpc_path="/etc/frp/frpc.toml"
    [ -n "$frpc_b64" ] || return 0
    [ "$os" != freebsd ] || frpc_path="/etc/frpc.toml"
    cat <<EOF
  - |
      (frpc -c ${frpc_path} || /usr/local/bin/frpc -c ${frpc_path} || true) &
EOF
}


seed_runcmd_cleanup_cidata_freebsd() {
    local partuuid="$1"
    printf '  - |\n      ddify_cidata_partuuid="%s"\n' "$partuuid"
    cat <<'EOF'
      if command -v gpart >/dev/null 2>&1 && command -v fstyp >/dev/null 2>&1 && command -v diskinfo >/dev/null 2>&1; then
          found=$(gpart list 2>/dev/null | awk -v id="$ddify_cidata_partuuid" '
              function check() {
                  if (tolower(uuid) == tolower(id)) {
                      count++
                      if (label == "CIDATA" && idx ~ /^[1-9][0-9]*$/) result=name " " idx
                  }
              }
              /^[[:space:]]*[0-9]+\. Name:/ { check(); name=$3; idx=""; uuid=""; label="" }
              /^[[:space:]]*index:/ { idx=$2 }
              /^[[:space:]]*rawuuid:/ { uuid=$2 }
              /^[[:space:]]*label:/ { label=$2 }
              END { check(); if (count == 1) print result }
          ')
          provider=${found%% *} idx=${found#* }
          disk=${provider%p$idx}
          if [ -n "$provider" ] && [ -n "$idx" ] && [ "$disk" != "$provider" ] &&
             [ "$(fstyp "/dev/$provider" 2>/dev/null)" = msdosfs ] &&
             echo " $(sysctl -n kern.disks 2>/dev/null) " | grep -Fq " $disk " &&
             ! mount -p | awk -v p="$provider" -v uuid="$ddify_cidata_partuuid" '
                 $1 == "/dev/" p || $1 == "/dev/gpt/CIDATA" ||
                 $1 == "/dev/msdosfs/CIDATA" || tolower($1) == "/dev/gptid/" tolower(uuid) { found=1 }
                 END {exit !found}
             '; then
              size=$(diskinfo "/dev/$provider" 2>/dev/null | awk 'NR==1 {print $3}')
              case "$size" in ''|*[!0-9]*) size=0 ;; esac
              if [ "$size" -gt 0 ] && [ $((size % 1048576)) -eq 0 ] &&
                 dd if=/dev/zero of="/dev/$provider" bs=1m count=$((size / 1048576)) 2>/dev/null &&
                 gpart delete -i "$idx" "$disk" >/dev/null 2>&1; then
                  echo "DDify: removed temporary CIDATA on $disk"
              else
                  echo "DDify: FreeBSD CIDATA cleanup failed; check the seed partition" >&2
              fi
          else
              echo "DDify: FreeBSD CIDATA not uniquely verified or still mounted; retained" >&2
          fi
      else
          echo "DDify: FreeBSD CIDATA tools unavailable; retained" >&2
      fi
EOF
}

seed_runcmd_cleanup_cidata_mbr() {
    local partuuid="$1"
    printf '  - |\n      ddify_cidata_partuuid="%s"\n' "$partuuid"
    cat <<'EOF'
      if command -v lsblk >/dev/null 2>&1 && command -v sfdisk >/dev/null 2>&1 &&
         command -v blkid >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1; then
          cidata=$(lsblk -p -r -n -o NAME,PARTUUID 2>/dev/null | awk -v id="$ddify_cidata_partuuid" '
              tolower($2) == tolower(id) { n++; path=$1 }
              END { if (n == 1) print path }
          ')
          if [ -n "$cidata" ] && [ -b "$cidata" ] && ! findmnt -rn -S "$cidata" >/dev/null 2>&1 &&
             [ "$(blkid -s TYPE -o value "$cidata")" = vfat ] &&
             [ "$(blkid -s LABEL -o value "$cidata")" = CIDATA ]; then
              num=$(lsblk -dnro PARTN "$cidata")
              parent=$(lsblk -dnro PKNAME "$cidata")
              disk="/dev/$parent"
              case "$num" in 1|2|3|4) ;; *) disk= ;; esac
              if [ -n "$disk" ] && [ -b "$disk" ] &&
                 [ "$(lsblk -dnro TYPE "$disk")" = disk ] &&
                 [ "$(sfdisk --part-size "$disk" "$num" 2>/dev/null)" = 32768 ] &&
                 printf '%s' "$(sfdisk --part-type "$disk" "$num" 2>/dev/null | tr 'A-F' 'a-f')" | grep -Eq '^(0x)?0?e$'; then
                  size=$(blockdev --getsize64 "$cidata")
                  if [ "$size" -eq 16777216 ] &&
                     dd if=/dev/zero of="$cidata" bs=1M count=16 conv=fsync status=none &&
                     sfdisk --no-reread --no-tell-kernel --delete "$disk" "$num" >/dev/null 2>&1; then
                      echo "DDify: removed temporary MBR CIDATA partition"
                  else
                      echo "DDify: MBR CIDATA cleanup incomplete" >&2
                  fi
              fi
          fi
      fi
EOF
}

seed_runcmd_cleanup_cidata() {
    local os="$1" partuuid="${2:-}"
    [ "$os" != "freebsd" ] || { seed_runcmd_cleanup_cidata_freebsd "$partuuid"; return; }
    if match_ere "$partuuid" '^[[:xdigit:]]{8}-[[:xdigit:]]{2}$'; then
        seed_runcmd_cleanup_cidata_mbr "$partuuid"
        return
    fi
    match_ere "$partuuid" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' || \
        error "Missing/invalid CIDATA PARTUUID for Linux cloud-init cleanup"

    printf '  - |\n      ddify_cidata_partuuid="%s"\n' "$partuuid"
    cat <<'EOF'
      ddify_wipe_cidata() {
          command -v blockdev >/dev/null 2>&1 || return 1
          size=$(blockdev --getsize64 "$cidata" 2>/dev/null) || return 1
          case "$size" in ''|*[!0-9]*) return 1 ;; esac
          [ "$size" -gt 0 ] || return 1
          dd if=/dev/zero of="$cidata" bs=1M iflag=count_bytes count="$size" conv=fsync status=none 2>/dev/null
      }
      # Confirm the seed's unique GPT identity both in the kernel and on disk.
      if command -v lsblk >/dev/null 2>&1 && command -v blkid >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1; then
          cidata="$(lsblk -p -r -n -o NAME,PARTUUID 2>/dev/null | awk -v id="$ddify_cidata_partuuid" '
              toupper($2) == toupper(id) { count++; path=$1 }
              END { if (count == 1) print path }
          ')"
          if [ -n "$cidata" ] && [ -b "$cidata" ]; then
              part_kind="$(lsblk -d -n -r -o TYPE "$cidata" 2>/dev/null)"
              part_label="$(lsblk -d -n -r -o PARTLABEL "$cidata" 2>/dev/null)"
              fs_type="$(blkid -s TYPE -o value "$cidata" 2>/dev/null)"
              fs_label="$(blkid -s LABEL -o value "$cidata" 2>/dev/null)"
              partnum="$(lsblk -d -n -r -o PARTN "$cidata" 2>/dev/null)"
              parent="$(lsblk -d -n -r -o PKNAME "$cidata" 2>/dev/null)"
              disk="/dev/$parent"
              if [ "$part_kind" = part ] && [ "$part_label" = CIDATA ] && \
                 [ "$fs_type" = vfat ] && [ "$fs_label" = CIDATA ] && \
                 [ -n "$parent" ] && [ -b "$disk" ] && \
                 [ "$(lsblk -d -n -r -o TYPE "$disk" 2>/dev/null)" = disk ]; then
                  case "$partnum" in
                      ''|0|*[!0-9]*) echo "DDify: invalid CIDATA partition number; leaving seed intact" >&2 ;;
                      *)
                          if findmnt -r -n -S "$cidata" >/dev/null 2>&1; then
                              echo "DDify: CIDATA is mounted; skipping cleanup" >&2
                          elif command -v sfdisk >/dev/null 2>&1; then
                              ondisk_uuid="$(sfdisk --part-uuid "$disk" "$partnum" 2>/dev/null || true)"
                              if [ "$(printf '%s' "$ondisk_uuid" | tr 'A-F' 'a-f')" != "$(printf '%s' "$ddify_cidata_partuuid" | tr 'A-F' 'a-f')" ]; then
                                  echo "DDify: on-disk GPT PARTUUID differs from CIDATA; refusing cleanup" >&2
                               elif ! ddify_wipe_cidata; then
                                   echo "DDify: CIDATA wipe failed; partition retained" >&2
                               elif sfdisk --lock=yes --no-reread --no-tell-kernel --delete "$disk" "$partnum" >/dev/null; then
                                  echo "DDify: removed temporary CIDATA GPT entry on $disk (partition $partnum)"
                              else
                                  echo "DDify: sfdisk failed; CIDATA retained" >&2
                              fi
                          elif command -v sgdisk >/dev/null 2>&1; then
                              ondisk_uuid="$(sgdisk -i "$partnum" "$disk" 2>/dev/null | awk '/Partition unique GUID:/ {print $4; exit}')"
                              if [ "$(printf '%s' "$ondisk_uuid" | tr 'A-F' 'a-f')" != "$(printf '%s' "$ddify_cidata_partuuid" | tr 'A-F' 'a-f')" ]; then
                                  echo "DDify: on-disk GPT PARTUUID differs from CIDATA; refusing cleanup" >&2
                               elif ! ddify_wipe_cidata; then
                                   echo "DDify: CIDATA wipe failed; partition retained" >&2
                               elif sgdisk -d "$partnum" "$disk" >/dev/null; then
                                  echo "DDify: removed temporary CIDATA GPT entry on $disk (partition $partnum)"
                              else
                                  echo "DDify: sgdisk failed; CIDATA retained" >&2
                              fi
                          else
                              echo "DDify: sfdisk/sgdisk unavailable; CIDATA retained" >&2
                          fi
                          ;;
                  esac
              else
                  echo "DDify: CIDATA partition metadata mismatch; refusing cleanup" >&2
              fi
          else
              echo "DDify: no unique matching CIDATA PARTUUID; refusing cleanup" >&2
          fi
      else
          echo "DDify: lsblk/blkid/findmnt unavailable; CIDATA retained" >&2
      fi
EOF
}
seed_runcmd() {
    local os="$1" frpc_b64="$2" cidata_partuuid="${3:-}"

    echo
    echo "runcmd:"
    # The newly created static hostname may not have its SELinux label when
    # PID 1 reads it. After relabeling, reconcile the running hostname too,
    # because NetworkManager may have selected a DHCP name in the meantime.
    local name
    name=$(seed_hostname "$os") || error "Invalid Linux target hostname"
    cat <<EOF
  - |
      ddify_hostname='$name'
EOF
    cat <<'EOF'
      ddify_hostname_failed=0
      if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != Disabled ]; then
          if ! command -v restorecon >/dev/null 2>&1 ||
             ! restorecon -F /etc/hostname /etc/cloud/cloud.cfg; then
              ddify_hostname_failed=1
          fi
      fi
      if [ "$ddify_hostname_failed" = 0 ]; then
          if [ "$(cat /etc/hostname)" != "$ddify_hostname" ] ||
             [ "$(hostname)" != "$ddify_hostname" ]; then
              if command -v hostnamectl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
                  hostnamectl set-hostname "$ddify_hostname" || ddify_hostname_failed=1
              else
                  (printf '%s\n' "$ddify_hostname" > /etc/hostname && hostname "$ddify_hostname") ||
                      ddify_hostname_failed=1
              fi
          fi
          if [ "$(cat /etc/hostname)" != "$ddify_hostname" ] ||
             [ "$(hostname)" != "$ddify_hostname" ]; then
              ddify_hostname_failed=1
          fi
      fi
      if [ "$ddify_hostname_failed" = 0 ]; then
          echo "DDify: verified static and running hostname $ddify_hostname"
      else
          echo "DDify: failed to reconcile static and running hostname" >&2
      fi
EOF
    seed_runcmd_ssh_port "$os"
    seed_runcmd_expand_root "$os"
    seed_runcmd_frpc "$os" "$frpc_b64"
    cat <<'EOF'
  - |
      [ "${ddify_ssh_failed:-0}" = 0 ] && [ "${ddify_hostname_failed:-0}" = 0 ] || {
          echo "DDify: SSH or hostname setup failed; CIDATA retained for recovery" >&2
          exit 1
      }
EOF
    seed_runcmd_cleanup_cidata "$os" "$cidata_partuuid"
}

# nuageinit supports a native executable user-data script. Keep the FreeBSD
# first-boot path separate from Linux cloud-init's YAML dialect.
write_freebsd_seed_script() {
    local user="$1" partuuid="$2" frpc_b64="$3" auth_hash="$PASSWORD_HASH" permit auth
    if [ -n "$auth_hash" ]; then
        permit=yes; auth=yes
    else
        permit=prohibit-password; auth=no
        # Give root a random, undisclosed password hash to avoid account-lock
        # semantics preventing key-only access. SSH password auth stays off.
        auth_hash=$(openssl rand -hex 32 | openssl passwd -6 -stdin) ||
            error "Cannot generate disabled-password root credential"
    fi
    {
        printf '%s\n' '#!/bin/sh' 'set -eu' 'umask 077'
        plan_assignment ddify_root_hash "$auth_hash"
        plan_assignment ddify_root_keys "$SSH_KEYS_ALL"
        plan_assignment ddify_port "${SSH_PORT:-22}"
        plan_assignment ddify_web_port "$WEB_PORT"
        plan_assignment ddify_permit "$permit"
        plan_assignment ddify_auth "$auth"
        plan_assignment ddify_frpc_b64 "$frpc_b64"
        cat <<'FREEBSD_BOOT'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
exec >>/var/log/ddify-firstboot.log 2>&1
echo "DDify: FreeBSD firstboot started"
echo "DDify: FreeBSD firstboot started" >/dev/console || true
printf '%s\n' "$ddify_root_hash" | pw usermod root -H 0
if [ -n "$ddify_root_keys" ]; then
    mkdir -p /root/.ssh
    chmod 0700 /root/.ssh
    printf '%s\n' "$ddify_root_keys" >/root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    chown -R root:wheel /root/.ssh
fi
cfg=/etc/ssh/sshd_config
tmp=$(mktemp)
trap 'rm -f "$tmp"' 0
awk -v permit="$ddify_permit" -v auth="$ddify_auth" -v port="$ddify_port" '
    BEGIN {
        print "PermitRootLogin " permit
        print "PasswordAuthentication " auth
        print "KbdInteractiveAuthentication " auth
        print "PubkeyAuthentication yes"
        print "Port " port
    }
    /^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|Port)[[:space:]]+/ {next}
    {print}
' "$cfg" >"$tmp"
ssh-keygen -A
/usr/sbin/sshd -t -f "$tmp"
cat "$tmp" >"$cfg"
/usr/sbin/sshd -t
sysrc sshd_enable=YES
service sshd restart || service sshd start
if [ -n "$ddify_web_port" ]; then
    printf '%s\n' "$ddify_web_port" >/etc/reinstall-web-port
    chmod 0644 /etc/reinstall-web-port
fi
if [ -n "$ddify_frpc_b64" ]; then
    printf '%s' "$ddify_frpc_b64" | base64 -d >/etc/frpc.toml
    chmod 0600 /etc/frpc.toml
    (frpc -c /etc/frpc.toml || /usr/local/bin/frpc -c /etc/frpc.toml || true) &
fi
# The partition boundary was expanded in Alpine. FreeBSD grows UFS in place.
growfs -y / || echo "DDify: UFS expansion needs inspection" >&2
FREEBSD_BOOT
        # Reuse the UUID-checked cleanup body, stripping only YAML indentation.
        seed_runcmd_cleanup_cidata_freebsd "$partuuid" | sed '1d; s/^      //'
        printf '%s\n' 'echo "DDify: FreeBSD firstboot completed"' \
            'echo "DDify: FreeBSD firstboot completed" >/dev/console || true'
    } >"$user"
    sh -n "$user" || error "Generated FreeBSD firstboot script is invalid"
}

write_nocloud_seed() {
    local os="$1" meta="$2" user="$3" cidata_partuuid="${4:-}" frpc_b64="" hostname
    hostname=$(seed_hostname "$os") || error "Invalid target OS for hostname"

    mkdir -p "$(dirname "$meta")"
    printf 'instance-id: iid-%s\n' "$(date +%s)" >"$meta"
    # FreeBSD nuageinit consumes the metadata hostname itself. Linux already
    # has a static /etc/hostname and does not need a competing early request.
    if [ "$os" = freebsd ]; then
        printf 'local-hostname: %s\n' "$hostname" >>"$meta"
    fi

    { [ -z "${FRPC_PRESENT:-}" ] || [ -z "${FRPC_TOML:-}" ] || ! [ -f "$FRPC_TOML" ]; } || \
        frpc_b64=$(base64 <"$FRPC_TOML" | tr -d '\n')

    if [ "$os" = freebsd ]; then
        write_freebsd_seed_script "$user" "$cidata_partuuid" "$frpc_b64"
    else
        {
            echo "#cloud-config"
            seed_account_linux "$os"
            seed_write_files "$os" "$frpc_b64"
            seed_runcmd "$os" "$frpc_b64" "$cidata_partuuid"
        } >"$user"
    fi
}

# ----------------- bootstrap state -----------------

EFI_MOUNT_POINT="/boot/efi"
PLAN_DIR_REL="REINSTALL"
PLAN_EFI_PART=""
PLAN_EFI_UUID=""
PLAN_STORAGE_MODE="efi"

ALPINE_ENTRY_TITLE="Reinstall Alpine RAM"
ALPINE_REPO_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.22"
ALPINE_NETBOOT_SUBDIR="netboot-3.22.6"
ALPINE_BOOT_SUBDIR="alpine"
ALPINE_BOOT_DIR_REL=""
ALPINE_BOOT_DIR_ABS=""
ALPINE_VMLINUZ_REL=""
ALPINE_INITRAMFS_REL=""
ALPINE_MODLOOP_URL=""
ALPINE_APKOVL_REL="/reinstall.apkovl.tar.gz"
ALPINE_VMLINUZ_ABS=""
ALPINE_INITRAMFS_ABS=""
ALPINE_APKOVL_ABS=""
ALPINE_FREEBSD_GRUB_EFI_REL=""
ALPINE_FREEBSD_GRUB_EFI_ABS=""
ALPINE_FREEBSD_GRUB_CFG_REL=""
ALPINE_FREEBSD_GRUB_CFG_ABS=""
ALPINE_NETBOOT_ARCH=""
ALPINE_KERNEL_FLAVOR="virt"

GRUB_SCRIPT_PATH=""
GRUB_CFG_PATH=""
GRUB_MKCONFIG_CMD=""
GRUB_REBOOT_CMD=""
CURRENT_CONSOLE_ARGS=""
AUTO_YES=0
PASSWORD_TO_DISPLAY=""
STAGED_IMAGE=""
LINUX_COPY_ROOT_USED=""

find_efi_for_plan() {
    local os
    os=$(uname -s)
    if [ "$os" = "Linux" ]; then
        if command -v findmnt >/dev/null 2>&1; then
            local mounted_src
            mounted_src=$(findmnt -n -o SOURCE --mountpoint /boot/efi 2>/dev/null | head -n1 || true)
            if { [ -n "$mounted_src" ] && [ -b "$mounted_src" ]; }; then
                echo "$mounted_src"
                return 0
            fi
        fi

        if command -v lsblk >/dev/null 2>&1; then
            local line name type parttype partlabel partflags fstype path
            while read -r line; do
                path=$(lsblk_get_kv "$line" "PATH")
                name=$(lsblk_get_kv "$line" "NAME")
                type=$(lsblk_get_kv "$line" "TYPE")
                parttype=$(lsblk_get_kv "$line" "PARTTYPE")
                fstype=$(lsblk_get_kv "$line" "FSTYPE")
                partlabel=$(lsblk_get_kv "$line" "PARTLABEL")
                partflags=$(lsblk_get_kv "$line" "PARTFLAGS")

                [ "$type" = "part" ] || continue
                if { [ "$(to_lower "$parttype")" = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ] && [ "$fstype" = "vfat" ]; } && \
                   [ "$(linux_source_to_disk "$path" || true)" = "$DISK" ]; then
                    if [ -n "$path" ]; then
                        echo "$path"
                    else
                        echo "/dev/$name"
                    fi
                    return 0
                fi
            done <<DDIFY_INPUT_11
$(lsblk -P -o PATH,NAME,TYPE,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS 2>/dev/null || true)
DDIFY_INPUT_11
        fi
    elif [ "$os" = "FreeBSD" ]; then
        if command -v sysctl >/dev/null 2>&1 && command -v gpart >/dev/null 2>&1; then
            local d p preferred=""

            if [ -n "${DISK:-}" ]; then
                preferred="${DISK#/dev/}"
                p=$(gpart show -p "$preferred" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [ -n "$p" ]; then
                    echo "/dev/$p"
                    return 0
                fi
            fi

            for d in $(sysctl -n kern.disks 2>/dev/null || true); do
                { [ -n "$preferred" ] && [ "$d" = "$preferred" ]; } && continue
                p=$(gpart show -p "$d" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [ -n "$p" ]; then
                    echo "/dev/$p"
                    return 0
                fi
            done
        fi
    fi
    return 1
}

get_fs_uuid_linux() {
    local dev="$1"
    if command -v blkid >/dev/null 2>&1; then
        blkid -s UUID -o value "$dev" 2>/dev/null || true
    fi
}

get_fs_uuid_freebsd() {
    local dev="$1"
    local desc="" serial=""

    command -v file >/dev/null 2>&1 || return 0
    desc=$(file -s "$dev" 2>/dev/null || true)

    serial=$(printf '%s\n' "$desc" | sed -nE 's/.*serial[[:space:]]number[[:space:]]0x([0-9A-Fa-f]{1,8}).*/\1/p')
    [ -n "$serial" ] || return 0

    while [ "$(( ${#serial} < 8 ))" -ne 0 ]; do
        serial="0${serial}"
    done
    serial="$(to_upper "$serial")"

    printf '%s-%s\n' "$(printf '%s' "$serial" | cut -c1-4)" "$(printf '%s' "$serial" | cut -c5-8)"
}

mount_efi_for_plan() {
    if [ "$OS" = "Linux" ]; then
        if [ -d /boot/efi ] && is_mountpoint /boot/efi; then
            EFI_MOUNT_POINT="/boot/efi"
            PLAN_STORAGE_MODE="efi"
            PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint /boot/efi 2>/dev/null | head -n1 || true)
        else
            local efi_part
            efi_part=$(find_efi_for_plan 2>/dev/null || true)
            if [ -n "$efi_part" ]; then
                EFI_MOUNT_POINT="/boot/efi"
                mkdir -p "$EFI_MOUNT_POINT"
                mount "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    mount -t vfat "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    error "Failed to mount EFI partition $efi_part"
                PLAN_STORAGE_MODE="efi"
                PLAN_EFI_PART="$efi_part"
            else
                [ -d /boot ] || error "No EFI partition and no /boot fallback"
                EFI_MOUNT_POINT="/boot"
                PLAN_STORAGE_MODE="boot"
                if is_mountpoint /boot; then
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint /boot 2>/dev/null | head -n1 || true)
                else
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint / 2>/dev/null | head -n1 || true)
                fi
            fi
        fi
        [ -n "$PLAN_EFI_PART" ] && PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
        return 0
    fi

    local mounted_src="" efi_part=""
    if [ -d "$EFI_MOUNT_POINT" ] && is_mountpoint "$EFI_MOUNT_POINT"; then
        mounted_src=$(freebsd_mount_source_for "$EFI_MOUNT_POINT" || true)
        efi_part=$(find_efi_for_plan 2>/dev/null || true)
        PLAN_EFI_PART="${efi_part:-$mounted_src}"
        { case "$PLAN_EFI_PART" in /dev/*p[0-9]*) true ;; *) false ;; esac; } || error "Could not resolve the physical FreeBSD EFI partition"
        PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
        PLAN_STORAGE_MODE="efi"
        info "Using FreeBSD EFI: ${mounted_src:-$PLAN_EFI_PART} -> $PLAN_EFI_PART"
        return 0
    fi

    efi_part=$(find_efi_for_plan 2>/dev/null || true)
    [ -n "$efi_part" ] || error "Could not find FreeBSD EFI partition"
    mkdir -p "$EFI_MOUNT_POINT"
    if command -v mount_msdosfs >/dev/null 2>&1; then
        mount_msdosfs "$efi_part" "$EFI_MOUNT_POINT" || error "Failed to mount $efi_part"
    else
        mount -t msdosfs "$efi_part" "$EFI_MOUNT_POINT" || error "Failed to mount $efi_part"
    fi
    PLAN_STORAGE_MODE="efi"
    PLAN_EFI_PART="$efi_part"
    PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
}

# Portable assignment quoting: the rescue init sources this plan with /bin/sh.
# Preserve quotes, newlines and empty values without Bash printf %q.
plan_assignment() (
    name=$1 value=$2
    case "$name" in ''|[0-9]*|*[!A-Za-z0-9_]*) exit 1 ;; esac
    printf '%s=' "$name"
    case "$value" in
        ''|*[!A-Za-z0-9_./:-]*)
            printf "'"
            while :; do
                case "$value" in
                    *"'"*) printf '%s' "${value%%\'*}"; printf '%s' "'\\''"; value=${value#*\'} ;;
                    *) printf "%s'\n" "$value"; break ;;
                esac
            done ;;
        *) printf '%s\n' "$value" ;;
    esac
)

write_install_plan() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    {
        plan_assignment TARGET_OS "$TARGET_OS"
        plan_assignment TARGET_VER "$TARGET_VER"
        plan_assignment DISK "$DISK"
        plan_assignment DISK_ID_WWN "${DISK_ID_WWN:-}"
        plan_assignment DISK_ID_SERIAL "${DISK_ID_SERIAL:-}"
        plan_assignment DISK_ID_SIZE "${DISK_ID_SIZE:-}"
        plan_assignment DISK_ID_MODEL "${DISK_ID_MODEL:-}"
        plan_assignment DISK_ID_PTUUID "${DISK_ID_PTUUID:-}"
        plan_assignment DISK_ID_MBR_ID "${DISK_ID_MBR_ID:-}"
        plan_assignment DISK_ID_ANCHOR_PARTUUID "${DISK_ID_ANCHOR_PARTUUID:-}"
        plan_assignment IMG_URL "$IMG_URL"
        plan_assignment IMAGE_BUILTIN "${IMAGE_BUILTIN:-0}"
        plan_assignment PASSWORD_HASH "$PASSWORD_HASH"
        plan_assignment SSH_KEYS_ALL "$SSH_KEYS_ALL"
        plan_assignment SSH_PORT "$SSH_PORT"
        plan_assignment WEB_PORT "$WEB_PORT"
        plan_assignment FRPC_TOML "$FRPC_TOML"
        plan_assignment POST_INSTALL_HOOK "$POST_INSTALL_HOOK"
        plan_assignment AUTO_PASSWORD "$AUTO_PASSWORD"
        plan_assignment PLAN_EFI_UUID "$PLAN_EFI_UUID"
    } >"$path"
    chmod 0600 "$path" 2>/dev/null || true
}

load_install_plan() {
    local plan="/etc/reinstall/plan.env"
    [ -f "$plan" ] || error "Embedded install plan not found: $plan"
    # shellcheck disable=SC1090
    . "$plan"
    PASSWORD=""
    PASSWORD_HASH="${PASSWORD_HASH:-}"
    ! [ -f /etc/reinstall/frpc.toml ] || FRPC_TOML="/etc/reinstall/frpc.toml"
    ! [ -f /etc/reinstall/post-install-hook.sh ] || POST_INSTALL_HOOK="/etc/reinstall/post-install-hook.sh"
    info "Loaded embedded install plan"
}

# ----------------- Alpine RAM / boot bootstrap -----------------

detect_current_console_args() {
    CURRENT_CONSOLE_ARGS=""
    if [ -r /proc/cmdline ]; then
        local tok
        for tok in $(cat /proc/cmdline); do
            case "$tok" in
                console=*)
                    CURRENT_CONSOLE_ARGS="$CURRENT_CONSOLE_ARGS $tok"
                    ;;
            esac
        done
    fi

    if [ -z "$CURRENT_CONSOLE_ARGS" ]; then
        CURRENT_CONSOLE_ARGS=" console=ttyS0 console=tty0"
    fi
}

ensure_grub_tools() {
    [ "$OS" = "Linux" ] || error "GRUB bootstrap requires Linux host"

    if command -v grub2-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub2-mkconfig"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        GRUB_MKCONFIG_CMD="grub-mkconfig"
    else
        error "grub-mkconfig not found"
    fi

    if command -v grub2-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub2-reboot"
    elif command -v grub-reboot >/dev/null 2>&1; then
        GRUB_REBOOT_CMD="grub-reboot"
    else
        error "grub-reboot not found"
    fi

    [ -d /etc/grub.d ] || error "/etc/grub.d not found"
    GRUB_SCRIPT_PATH="/etc/grub.d/41_reinstall_alpine"

    if [ -f /boot/grub2/grub.cfg ]; then
        GRUB_CFG_PATH="/boot/grub2/grub.cfg"
    elif [ -f /boot/grub/grub.cfg ]; then
        GRUB_CFG_PATH="/boot/grub/grub.cfg"
    else
        error "GRUB config not found"
    fi
}

ensure_freebsd_boot_tools() {
    [ "$OS" = "FreeBSD" ] || error "Automatic FreeBSD BootNext bootstrap only supports FreeBSD host"
    command -v efibootmgr >/dev/null 2>&1 || error "efibootmgr is required on FreeBSD host"
    command -v tar >/dev/null 2>&1 || error "tar is required on FreeBSD host"
    command -v file >/dev/null 2>&1 || error "file is required on FreeBSD host"
    command -v dd >/dev/null 2>&1 || error "dd is required on FreeBSD host"
    command -v cmp >/dev/null 2>&1 || error "cmp is required on FreeBSD host"
    command -v grep >/dev/null 2>&1 || error "grep is required on FreeBSD host"

    if ! efibootmgr -v >/dev/null 2>&1; then
        error "efibootmgr is present but EFI NVRAM is not accessible; FreeBSD automatic boot requires UEFI boot mode"
    fi
}

prepare_alpine_paths() {
    mount_efi_for_plan

    case "$MACHINE_ARCH" in
        x86_64)
            ALPINE_NETBOOT_ARCH="x86_64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubx64.efi"
            ;;
        aarch64)
            ALPINE_NETBOOT_ARCH="aarch64"
            ALPINE_FREEBSD_GRUB_EFI_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR/reinstall-grubaa64.efi"
            ;;
        *)
            error "Alpine RAM bootstrap supports only x86_64 and aarch64"
            ;;
    esac

    { [ "$PLAN_STORAGE_MODE" != "efi" ] || [ -n "$PLAN_EFI_UUID" ]; } || error "Bootstrap filesystem UUID unavailable"

    ALPINE_BOOT_DIR_REL="/$PLAN_DIR_REL/$ALPINE_BOOT_SUBDIR"
    ALPINE_BOOT_DIR_ABS="$EFI_MOUNT_POINT$ALPINE_BOOT_DIR_REL"
    ALPINE_FREEBSD_GRUB_CFG_REL="$ALPINE_BOOT_DIR_REL/grub/grub.cfg"
    ALPINE_FREEBSD_GRUB_CFG_ABS="$EFI_MOUNT_POINT$ALPINE_FREEBSD_GRUB_CFG_REL"
    ALPINE_VMLINUZ_REL="$ALPINE_BOOT_DIR_REL/vmlinuz"
    ALPINE_INITRAMFS_REL="$ALPINE_BOOT_DIR_REL/initramfs"
    ALPINE_MODLOOP_URL="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}/modloop-${ALPINE_KERNEL_FLAVOR}"
    ALPINE_VMLINUZ_ABS="$EFI_MOUNT_POINT$ALPINE_VMLINUZ_REL"
    ALPINE_INITRAMFS_ABS="$EFI_MOUNT_POINT$ALPINE_INITRAMFS_REL"
    ALPINE_APKOVL_ABS="$EFI_MOUNT_POINT$ALPINE_APKOVL_REL"
    if [ "$PLAN_STORAGE_MODE" = boot ] && ! is_mountpoint /boot; then
        local root_fs root_source root_type
        root_fs=$(findmnt -n -o FSTYPE --mountpoint / 2>/dev/null || true)
        root_source=$(findmnt -n -o SOURCE --mountpoint / 2>/dev/null || true)
        root_source="${root_source%%\[*}"
        root_type=$(lsblk -dn -o TYPE "$root_source" 2>/dev/null || true)
        { [ "$root_fs" = ext2 ] || [ "$root_fs" = ext3 ] || [ "$root_fs" = ext4 ]; } &&
        { [ "$root_type" = part ] || [ "$root_type" = disk ]; } ||
            error "BIOS without separate /boot requires a directly accessible ext root for Alpine apkovl discovery"
        ALPINE_APKOVL_ABS="$ALPINE_APKOVL_REL"
    fi
    ALPINE_FREEBSD_GRUB_EFI_ABS="$EFI_MOUNT_POINT$ALPINE_FREEBSD_GRUB_EFI_REL"
}

download_alpine_ram_files() {
    mkdir -p "$ALPINE_BOOT_DIR_ABS"

    local base tmpdir
    tmpdir=$(mktemp -d /tmp/reinstall-alpine-netboot.XXXXXX)

    base="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/${ALPINE_NETBOOT_SUBDIR}"

    rm -f "$ALPINE_BOOT_DIR_ABS/modloop"
    sync

    local free_kb
    free_kb=$(df -Pk "$ALPINE_BOOT_DIR_ABS" 2>/dev/null | awk 'NR==2 {print $4; exit}')
    if match_ere "$free_kb" '^[0-9]+$' && [ "$(( free_kb < 22528 ))" -ne 0 ]; then
        rm -rf "$tmpdir"
        error "Bootstrap filesystem has only ${free_kb} KiB free after removing stale modloop; at least 22 MiB is required for Alpine kernel/initramfs and bootstrap files"
    fi

    info "Using fixed Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}, source=${base}"
    info "Alpine modloop will be fetched by initramfs over HTTPS at boot:"
    info "  ${ALPINE_MODLOOP_URL}"

    if ! http_download "$base/vmlinuz-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/vmlinuz"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine kernel"
    fi
    if ! http_download "$base/initramfs-${ALPINE_KERNEL_FLAVOR}" "$tmpdir/initramfs"; then
        rm -rf "$tmpdir"
        error "Failed to download Alpine initramfs"
    fi

    mv "$tmpdir/vmlinuz" "$ALPINE_VMLINUZ_ABS"
    mv "$tmpdir/initramfs" "$ALPINE_INITRAMFS_ABS"

    chmod 0644 "$ALPINE_VMLINUZ_ABS" "$ALPINE_INITRAMFS_ABS"
    rm -rf "$tmpdir"
    sync

    info "Selected Alpine RAM assets: arch=${ALPINE_NETBOOT_ARCH}, flavor=${ALPINE_KERNEL_FLAVOR}"
}

build_alpine_apkovl() {
    local tmp ovl_dir startfile initfile self
    tmp=$(mktemp -d /tmp/reinstall-alpine-apkovl.XXXXXX)
    ovl_dir="$tmp/ovl"

    mkdir -p "$ovl_dir/etc/apk" "$ovl_dir/etc/reinstall" "$ovl_dir/usr/local/sbin"
    : >"$ovl_dir/etc/.default_boot_services"
    printf 'DDIFY_ALPINE_REPO=%s\n' "$ALPINE_REPO_BASE" >"$ovl_dir/etc/reinstall/alpine-repo.conf"

    cat >"$ovl_dir/etc/apk/repositories" <<EOF
${ALPINE_REPO_BASE}/main
${ALPINE_REPO_BASE}/community
EOF

    write_install_plan "$ovl_dir/etc/reinstall/plan.env"

    self="$0"
    if command -v readlink >/dev/null 2>&1; then
        self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")
    elif command -v realpath >/dev/null 2>&1; then
        self=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
    fi
    [ -f "$self" ] || error "Cannot locate current script: $self"
    cp "$self" "$ovl_dir/usr/local/sbin/reinstall-installer.sh"
    chmod 0755 "$ovl_dir/usr/local/sbin/reinstall-installer.sh"

    if { [ -n "${FRPC_TOML:-}" ] && ! match_ere "$FRPC_TOML" '^https?://' && [ -f "$FRPC_TOML" ]; }; then
        cp "$FRPC_TOML" "$ovl_dir/etc/reinstall/frpc.toml"
        chmod 0600 "$ovl_dir/etc/reinstall/frpc.toml"
    fi
    if [ -n "${POST_INSTALL_HOOK:-}" ]; then
        [ -f "$POST_INSTALL_HOOK" ] || error "Post-install hook not found: $POST_INSTALL_HOOK"
        cp "$POST_INSTALL_HOOK" "$ovl_dir/etc/reinstall/post-install-hook.sh"
        chmod 0700 "$ovl_dir/etc/reinstall/post-install-hook.sh"
    fi

    startfile="$ovl_dir/usr/local/sbin/reinstall-auto.sh"
    cat >"$startfile" <<'EOF'
#!/bin/sh
set -eu

LOG="/var/log/reinstall-auto.log"
mkdir -p /var/log
touch "$LOG"
# look idle at a login prompt while destructive work is running.
if [ -w /dev/console ] && command -v mkfifo >/dev/null 2>&1; then
    fifo=/run/reinstall-console-log.fifo
    rm -f "$fifo"
    mkfifo -m 0600 "$fifo"
    tee -a "$LOG" <"$fifo" >/dev/console &
    exec >"$fifo" 2>&1
else
    exec >>"$LOG" 2>&1
fi

echo "===== reinstall-auto start $(date) ====="

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

is_mountpoint() {
    local p="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$p" 2>/dev/null
        return $?
    fi

    awk -v p="$p" '$2 == p { found=1; exit } END { exit(found ? 0 : 1) }' /proc/mounts 2>/dev/null
}

ensure_network() {
    local n

    if ip route 2>/dev/null | grep -q '^default ' || ip -6 route 2>/dev/null | grep -q '^default '; then
        echo "Network already configured by Alpine initramfs."
        return 0
    fi

    echo "No default route found; retrying DHCP."
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        n="${n##*/}"
        [ "$n" = "lo" ] && continue
        ip link set dev "$n" up 2>/dev/null || true
        if command -v udhcpc >/dev/null 2>&1; then
            if udhcpc -i "$n" -f -q -n -t 5 2>/dev/null; then
                break
            fi
        fi
    done

    { ip route 2>/dev/null | grep -q '^default ' || ip -6 route 2>/dev/null | grep -q '^default '; } || {
        echo "Failed to obtain a default route in Alpine RAM."
        exit 1
    }
}

install_runtime_deps_online() {
    . /etc/reinstall/alpine-repo.conf
    cat > /etc/apk/repositories <<REPOEOF
${DDIFY_ALPINE_REPO}/main
${DDIFY_ALPINE_REPO}/community
REPOEOF

    echo "[stage] apk update (online)"
    apk update
    echo "[stage] apk add (rescue SSH prerequisites)"
    apk add --no-cache openssh openssl
    start_reinstall_rescue_ssh
    echo "[stage] apk add (online official repos)"
    apk add --no-cache \
        curl wget ca-certificates xz qemu-img jq util-linux blkid lsblk findmnt coreutils grep sed gawk findutils file tar \
        e2fsprogs e2fsprogs-extra dosfstools sgdisk kmod lvm2 xfsprogs xfsprogs-extra
    if ! grep -q '^TARGET_OS=freebsd$' /etc/reinstall/plan.env; then
        echo "[stage] apk add (Linux filesystem-copy tools)"
        apk add --no-cache rsync btrfs-progs btrfs-progs-extra
        for cmd in rsync mkfs.btrfs btrfstune btrfs xfs_growfs; do
            command -v "$cmd" >/dev/null 2>&1 || {
                echo "Linux file-copy dependency is missing: $cmd" >&2
                exit 1
            }
        done
    fi
    update-ca-certificates 2>/dev/null || true
    blkid -V 2>&1 | grep -qi util-linux || { echo "Full util-linux blkid is required" >&2; exit 1; }

    # Fail here with a precise message instead of reaching the destructive stage
    for cmd in sgdisk sfdisk mkfs.ext4 qemu-img qemu-nbd jq xz curl lsblk blkid mount umount blockdev mknod pvresize xfs_db dumpe2fs resize2fs e2fsck; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Required Alpine runtime command is missing after apk add: $cmd"
            echo "Installed matching packages:"
            apk info 2>/dev/null | grep -E '^(xfsprogs|e2fsprogs|lvm2)' || true
            exit 1
        }
    done
}

start_reinstall_rescue_ssh() {
    . /etc/reinstall/plan.env
    rescue_port="${SSH_PORT:-22}"
    case "$rescue_port" in
        ''|*[!0-9]*) echo "Invalid rescue SSH port" >&2; exit 1 ;;
    esac
    [ "$rescue_port" -ge 1 ] && [ "$rescue_port" -le 65535 ] || exit 1
    mkdir -p /root/.ssh /run/sshd
    chmod 0700 /root/.ssh
    : > /root/.ssh/authorized_keys
    if [ -n "${SSH_KEYS_ALL:-}" ]; then
        printf '%s\n' "$SSH_KEYS_ALL" > /root/.ssh/authorized_keys
    fi
    chmod 0600 /root/.ssh/authorized_keys

    if [ -n "${PASSWORD_HASH:-}" ]; then
        rescue_hash="$PASSWORD_HASH"
        pw_auth=yes
    else
        rescue_hash=$(head -c 48 /dev/urandom | base64 | openssl passwd -6 -stdin) || exit 1
        pw_auth=no
    fi
    awk -F: -v hash="$rescue_hash" 'BEGIN {OFS=FS} $1=="root"{$2=hash} {print}' /etc/shadow > /etc/shadow.ddify
    cat /etc/shadow.ddify > /etc/shadow
    rm -f /etc/shadow.ddify
    chmod 0600 /etc/shadow
    if [ ! -s /root/.ssh/authorized_keys ] && [ "$pw_auth" = no ]; then
        echo "No credentials for rescue SSH; refusing to proceed." >&2
        exit 1
    fi
    ssh-keygen -A >/dev/null || exit 1
    cat > /etc/ssh/sshd_config <<SSHEOF
Port $rescue_port
PermitRootLogin yes
PasswordAuthentication $pw_auth
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
UsePAM no
Subsystem sftp internal-sftp
SSHEOF
    /usr/sbin/sshd -t || exit 1
    /usr/sbin/sshd || { echo "Failed to start Alpine rescue SSH" >&2; exit 1; }
    if command -v ss >/dev/null 2>&1; then
        ss -ltn | grep -Eq ":${rescue_port}[[:space:]]" || { echo "Rescue sshd is not listening on port $rescue_port" >&2; exit 1; }
    fi
    echo "Alpine rescue SSH available on port $rescue_port (root); remains alive after installer failure."
}

ensure_modloop_ready() {
    local kver attempt modloop_file

    kver="$(uname -r)"
    modloop_file="/lib/modloop-${ALPINE_KERNEL_FLAVOR:-virt}"

    if is_mountpoint /.modloop && [ -d "/.modloop/modules/$kver" ] && [ -e "/lib/modules/$kver" ]; then
        echo "Alpine modloop is already mounted and matches kernel $kver."
        return 0
    fi

    echo "[stage] ensuring Alpine modloop for kernel $kver"
    echo "Remote modloop: ${ALPINE_MODLOOP_URL:-from-kernel-cmdline}"

    for attempt in 1 2 3 4 5; do
        echo "Starting Alpine modloop service (attempt $attempt/5)..."

        rc-service modloop stop >/dev/null 2>&1 || true
        if is_mountpoint /.modloop; then
            umount /.modloop >/dev/null 2>&1 || true
        fi

        rm -f "$modloop_file"
        rm -f /lib/modloop-virt /lib/modloop-lts 2>/dev/null || true

        if rc-service modloop start; then
            if is_mountpoint /.modloop && \
               [ -d "/.modloop/modules/$kver" ] && \
               [ -e "/lib/modules/$kver" ]; then
                echo "Alpine modloop mounted successfully for kernel $kver."
                findmnt /.modloop 2>/dev/null || true
                return 0
            fi
        fi

        echo "Modloop attempt $attempt failed; removing any partial download before retry."
        rc-service modloop stop >/dev/null 2>&1 || true
        rm -f "$modloop_file" /lib/modloop-virt /lib/modloop-lts 2>/dev/null || true
        sleep 3
    done

    echo "Failed to obtain a valid Alpine modloop after 5 attempts."
    echo "Expected URL: ${ALPINE_MODLOOP_URL:-see /proc/cmdline}"
    echo "Kernel cmdline:"
    cat /proc/cmdline 2>/dev/null || true
    ls -lh /lib/modloop-* 2>/dev/null || true
    exit 1
}

setup_zram_swap() {
    local mem_kb zram_bytes min_bytes max_bytes

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [ -n "$mem_kb" ] || {
        echo "Could not determine MemTotal; refusing to continue without zram swap."
        exit 1
    }

    # QEMU and firmware reserve some installed RAM before Linux sees it.
    # The low-memory CI profile allocates 720 MiB, not 720 MiB MemTotal.
    case "$mem_kb" in ''|*[!0-9]*) echo "Invalid MemTotal" >&2; exit 1 ;; esac
    [ "$mem_kb" -ge 655360 ] || {
        echo "DDify requires at least 640 MiB usable Linux RAM (MemTotal=$mem_kb KiB)." >&2
        exit 1
    }
    zram_bytes=$((mem_kb * 1024 * 2))
    min_bytes=1073741824
    max_bytes=8589934592
    [ "$zram_bytes" -lt "$min_bytes" ] && zram_bytes="$min_bytes"
    [ "$zram_bytes" -gt "$max_bytes" ] && zram_bytes="$max_bytes"

    modprobe zram || {
        echo "zram kernel module is unavailable even after modloop setup."
        echo "Kernel: $(uname -r)"
        echo "/lib/modules:"
        ls -la /lib/modules 2>/dev/null || true
        exit 1
    }
    [ -e /dev/zram0 ] || mdev -s 2>/dev/null || true
    [ -b /dev/zram0 ] || {
        echo "zram0 block device was not created."
        exit 1
    }

    swapoff /dev/zram0 2>/dev/null || true
    if [ -e /sys/block/zram0/reset ]; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    echo "$zram_bytes" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0

    echo "$zram_bytes" > /run/reinstall-zram-bytes
    echo "Enabled zram swap: $((zram_bytes / 1024 / 1024)) MiB logical size"
    free -m 2>/dev/null || true
}

setup_work_tmpfs() {
    local mem_kb mem_bytes work_bytes reserve

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    mem_bytes=$((mem_kb * 1024))
    reserve=201326592
    # Logical compressed swap is not extra physical RAM.
    work_bytes=$((mem_bytes - reserve))
    [ "$work_bytes" -ge 134217728 ] || {
        echo "Insufficient RAM for the rescue workspace." >&2
        exit 1
    }

    mkdir -p /run/reinstall-work
    if is_mountpoint /run/reinstall-work; then
        umount /run/reinstall-work 2>/dev/null || true
    fi
    mount -t tmpfs -o "size=${work_bytes},mode=0700" tmpfs /run/reinstall-work
    echo "Created swap-backed tmpfs work area: $((work_bytes / 1024 / 1024)) MiB limit"
}

relocate_modloop_to_ram() {
    local loopdev backing ram_modloop kver new_loopdev

    kver="$(uname -r)"

    if ! is_mountpoint /.modloop; then
        echo "No /.modloop mount is active; no boot-media modloop relocation is needed."
        return 0
    fi

    loopdev="$(findmnt -rn -o SOURCE --target /.modloop 2>/dev/null | head -n1 || true)"
    [ -n "$loopdev" ] || {
        echo "Could not determine the block device backing /.modloop."
        exit 1
    }

    backing=""
    if command -v losetup >/dev/null 2>&1; then
        backing="$(losetup -n -O BACK-FILE "$loopdev" 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$backing" ]; then
        case "$loopdev" in
            /dev/loop*)
                backing="$(cat "/sys/class/block/${loopdev#/dev/}/loop/backing_file" 2>/dev/null || true)"
                [ -n "$backing" ] && backing="/${backing#/}"
                ;;
        esac
    fi

    [ -n "$backing" ] && [ -f "$backing" ] || {
        echo "Could not determine the modloop backing file for $loopdev."
        echo "Current mounts:"
        findmnt /.modloop 2>/dev/null || true
        losetup -a 2>/dev/null || true
        exit 1
    }

    # Network boot already downloads modloop into the diskless root in RAM.
    # Avoid holding two copies. Only reuse a backing file whose filesystem
    # is demonstrably independent of the target disk.
    local backing_fs
    backing_fs=$(findmnt -rn -o FSTYPE --target "$backing") || exit 1
    case "$backing_fs" in
        tmpfs|ramfs|rootfs)
            [ -d "/.modloop/modules/$kver" ] && [ -e "/lib/modules/$kver" ] || {
                echo "RAM-backed modloop is missing kernel modules." >&2
                exit 1
            }
            echo "Alpine modloop already resides on $backing_fs; no duplicate RAM copy needed."
            return 0 ;;
    esac
    ram_modloop="/run/reinstall-work/modloop.ram.squashfs"
    echo "Relocating Alpine modloop to RAM: $backing -> $ram_modloop"
    cp "$backing" "$ram_modloop"
    sync

    umount /.modloop || {
        echo "Failed to unmount the original /.modloop."
        exit 1
    }
    if command -v losetup >/dev/null 2>&1; then
        losetup -d "$loopdev" 2>/dev/null || true
    fi

    mount -o loop,ro "$ram_modloop" /.modloop || {
        echo "Failed to mount RAM-backed modloop."
        exit 1
    }

    [ -d "/.modloop/modules/$kver" ] || {
        echo "RAM-backed modloop does not contain modules for kernel $kver."
        exit 1
    }
    [ -e "/lib/modules/$kver" ] || {
        echo "/lib/modules/$kver is unavailable after modloop relocation."
        exit 1
    }

    new_loopdev="$(findmnt -rn -o SOURCE --target /.modloop 2>/dev/null | head -n1 || true)"
    echo "RAM-backed modloop active: ${new_loopdev:-unknown} -> $ram_modloop"

    echo "Modloop relocation complete."
}

main() {
    PLAN_FILE="/etc/reinstall/plan.env"
    SCRIPT_FILE="/usr/local/sbin/reinstall-installer.sh"

    [ -f "$PLAN_FILE" ] || {
        echo "Embedded plan file not found: $PLAN_FILE"
        exit 1
    }
    [ -f "$SCRIPT_FILE" ] || {
        echo "Embedded installer script not found: $SCRIPT_FILE"
        exit 1
    }

    echo "[stage] using embedded apkovl plan and installer"

    echo "[stage] ensure_network"
    ensure_network

    echo "[stage] install_runtime_deps_online"
    install_runtime_deps_online

    echo "[stage] ensure_modloop_ready"
    ensure_modloop_ready

    echo "[stage] setup_zram_swap"
    setup_zram_swap

    echo "[stage] setup_work_tmpfs"
    setup_work_tmpfs

    cd /

    echo "[stage] relocate_modloop_to_ram"
    relocate_modloop_to_ram

    RUN_SCRIPT="/run/reinstall-installer.sh"
    cp "$SCRIPT_FILE" "$RUN_SCRIPT"
    chmod 0755 "$RUN_SCRIPT"

    echo "[stage] launch installer"
    echo "Launching installer phase..."
    if sh "$RUN_SCRIPT" --phase installer --yes; then
        rc=0
    else
        rc=$?
    fi
    echo "Installer phase finished with rc=$rc"

    if [ "$rc" -eq 0 ]; then
        sync
        sleep 2
        reboot -f || poweroff -f || true
    fi

    exit "$rc"
}

main
EOF
    chmod 0755 "$startfile"

    initfile="$ovl_dir/usr/local/sbin/reinstall-init.sh"
    cat >"$initfile" <<'EOF'
#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
export PATH

echo "===== reinstall-init start $(date) ====="
echo "[init] deferring Alpine modloop until full network download tools are installed"
rm -f /etc/runlevels/sysinit/modloop 2>/dev/null || true

echo "[init] bringing up Alpine sysinit services"

/sbin/openrc sysinit || exec /sbin/init

echo "[init] bringing up Alpine boot services"
/sbin/openrc boot || exec /sbin/init

echo "[init] launching reinstall runner directly"
if /usr/local/sbin/reinstall-auto.sh; then
    rc=0
else
    rc=$?
fi

echo "[init] reinstall runner returned rc=$rc"
echo "[init] entering normal Alpine init for troubleshooting."
exec /sbin/init
EOF
    chmod 0755 "$initfile"

    # Alpine mkinitfs finds exactly one *.apkovl.tar.gz in the boot filesystem root.
    # Do not force an absolute apkovl= path: it resolves inside initramfs, not GRUB.
    local existing_apkovl
    for existing_apkovl in "$(dirname "$ALPINE_APKOVL_ABS")/"*.apkovl.tar.gz; do
        { ! [ -e "$existing_apkovl" ] || [ "$existing_apkovl" = "$ALPINE_APKOVL_ABS" ]; } || \
            error "Another apkovl exists on the boot filesystem: $existing_apkovl"
    done
    tar -C "$ovl_dir" -czf "$ALPINE_APKOVL_ABS" .
    chmod 0600 "$ALPINE_APKOVL_ABS" || error "Cannot restrict apkovl permissions"
    if [ "$(stat -c %a "$ALPINE_APKOVL_ABS" 2>/dev/null || stat -f %Lp "$ALPINE_APKOVL_ABS" 2>/dev/null)" != 600 ]; then
        warn "Boot filesystem cannot enforce owner-only apkovl access; password hash/FRPC credentials are exposed to local readers"
    fi
    rm -rf "$tmp"
    sync
    info "Built Alpine apkovl overlay: $ALPINE_APKOVL_ABS"
}

install_grub_entry_for_alpine() {
    ensure_grub_tools
    detect_current_console_args

    if [ "$PLAN_STORAGE_MODE" = "efi" ]; then
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' --id=ddify-reinstall-alpine {
    search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
    linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
    initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
}
EOF
    else
        local grub_boot_prefix="/boot"
        is_mountpoint /boot && grub_boot_prefix=""
        [ -n "$PLAN_EFI_UUID" ] || error "Cannot locate BIOS bootstrap filesystem UUID"
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' --id=ddify-reinstall-alpine {
    search --no-floppy --fs-uuid --set=root ${PLAN_EFI_UUID}
    linux ${grub_boot_prefix}${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
    initrd ${grub_boot_prefix}${ALPINE_INITRAMFS_REL}
}
EOF
    fi
    chmod 0755 "$GRUB_SCRIPT_PATH"
    # A previous version placed the rescue menu ahead of normal GRUB_DEFAULT=0.
    # Remove only the recognizable legacy entry; refuse to replace unrelated code.
    if [ -f /etc/grub.d/09_reinstall_alpine ]; then
        grep -Fq "menuentry '${ALPINE_ENTRY_TITLE}'" /etc/grub.d/09_reinstall_alpine ||             error "Conflicting legacy GRUB entry must be reviewed manually"
        rm -f /etc/grub.d/09_reinstall_alpine
    fi

    info "Regenerating GRUB config..."
    "$GRUB_MKCONFIG_CMD" -o "$GRUB_CFG_PATH" >/dev/null

    info "Scheduling one-time GRUB boot into: ${ALPINE_ENTRY_TITLE}"
    "$GRUB_REBOOT_CMD" ddify-reinstall-alpine
}

freebsd_grub_arch() {
    case "$ALPINE_NETBOOT_ARCH" in
        x86_64)
            FREEBSD_GRUB_EFI_NAME="bootx64.efi"
            FREEBSD_ALPINE_CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8"
            ;;
        aarch64)
            FREEBSD_GRUB_EFI_NAME="bootaa64.efi"
            FREEBSD_ALPINE_CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8 console=ttyAMA0,115200n8"
            ;;
        *) error "Unsupported UEFI bootstrap arch: $ALPINE_NETBOOT_ARCH" ;;
    esac
}

extract_alpine_grub_efi() {
    local iso="$1" member p normalized
    member=$(
        while IFS= read -r p; do
            normalized="${p#./}"
            [ "$(to_lower "$normalized")" = "efi/boot/$(to_lower "$FREEBSD_GRUB_EFI_NAME")" ] || continue
            echo "$p"; break
        done <<DDIFY_INPUT_12
$(tar -tf "$iso" 2>/dev/null)
DDIFY_INPUT_12
    )
    [ -n "$member" ] || error "${FREEBSD_GRUB_EFI_NAME} not found in Alpine ISO"
    mkdir -p "$(dirname "$ALPINE_FREEBSD_GRUB_EFI_ABS")"
    tar -xOf "$iso" "$member" >"$ALPINE_FREEBSD_GRUB_EFI_ABS" || error "Failed to extract Alpine GRUB EFI"
    [ -s "$ALPINE_FREEBSD_GRUB_EFI_ABS" ] || error "Extracted GRUB EFI is empty"
}

patch_alpine_grub_efi() {
    local tmp="$1" release="$2" volid marker offset old_cfg new_cfg old_len new_len patch
    volid="alpine-virt ${release} ${ALPINE_NETBOOT_ARCH}"
    # Command substitution strips trailing newlines; append a sentinel so
    # the exact binary configuration length (including the LF) is preserved.
    old_cfg=$(printf 'search --no-floppy --set=root --label "%s"\nset prefix=($root)/boot/grub\n.' "$volid")
    old_cfg=${old_cfg%.}
    new_cfg=$(printf 'search --no-floppy --fs-uuid --set=root %s\nset prefix=($root)%s/grub\n.' "$PLAN_EFI_UUID" "$ALPINE_BOOT_DIR_REL")
    new_cfg=${new_cfg%.}
    old_len=${#old_cfg}; new_len=${#new_cfg}
    [ "$(( new_len <= old_len ))" -ne 0 ] || error "Patched GRUB early config is too large"

    marker="search --no-floppy --set=root --label \"${volid}\""
    offset=$(LC_ALL=C grep -a -b -o -F "$marker" "$ALPINE_FREEBSD_GRUB_EFI_ABS" | head -n1 | cut -d: -f1) || true
    match_ere "$offset" '^[0-9]+$' || error "Could not locate Alpine GRUB early config"

    dd if="$ALPINE_FREEBSD_GRUB_EFI_ABS" of="$tmp/original.cfg" bs=1 skip="$offset" count="$old_len" status=none
    printf '%s' "$old_cfg" >"$tmp/expected.cfg"
    cmp -s "$tmp/expected.cfg" "$tmp/original.cfg" || error "Unexpected Alpine GRUB early config; refusing binary patch"

    patch="$tmp/patch.cfg"
    printf '%s' "$new_cfg" >"$patch"
    printf '%*s' $((old_len - new_len)) '' >>"$patch"
    dd if="$patch" of="$ALPINE_FREEBSD_GRUB_EFI_ABS" bs=1 seek="$offset" conv=notrunc status=none
    grep -a -Fq "search --no-floppy --fs-uuid --set=root ${PLAN_EFI_UUID}" "$ALPINE_FREEBSD_GRUB_EFI_ABS" || \
        error "Patched GRUB EFI verification failed"
}

write_freebsd_grub_cfg() {
    mkdir -p "$(dirname "$ALPINE_FREEBSD_GRUB_CFG_ABS")"
    cat >"$ALPINE_FREEBSD_GRUB_CFG_ABS" <<EOF
set timeout=0
set default=0
search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh ${FREEBSD_ALPINE_CONSOLE_ARGS}
initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
boot
EOF
}

build_freebsd_grub_efi() {
    ensure_freebsd_boot_tools
    [ "$PLAN_STORAGE_MODE" = efi ] || error "FreeBSD bootstrap requires EFI"
    match_ere "$PLAN_EFI_UUID" '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$' || error "Invalid ESP UUID: $PLAN_EFI_UUID"

    local release tmp iso url
    release="${ALPINE_NETBOOT_SUBDIR#netboot-}"
    freebsd_grub_arch
    url="${ALPINE_REPO_BASE}/releases/${ALPINE_NETBOOT_ARCH}/alpine-virt-${release}-${ALPINE_NETBOOT_ARCH}.iso"
    tmp=$(mktemp -d /tmp/reinstall-alpine-efi.XXXXXX); iso="$tmp/alpine.iso"

    info "Downloading Alpine virt ISO for GRUB EFI"
    http_download "$url" "$iso" || error "Failed to download Alpine virt ISO"
    extract_alpine_grub_efi "$iso"
    patch_alpine_grub_efi "$tmp" "$release"
    write_freebsd_grub_cfg
    chmod 0644 "$ALPINE_FREEBSD_GRUB_EFI_ABS" "$ALPINE_FREEBSD_GRUB_CFG_ABS"
    rm -rf "$tmp"; sync
    info "Prepared FreeBSD UEFI bootstrap: $ALPINE_FREEBSD_GRUB_EFI_ABS"
}

# Read actual EFI variable names, including boot entries not in BootOrder.
# efibootmgr -v is for diagnostics; it may omit or fail to decode device paths.
efi_boot_variable_numbers() {
    local vars
    vars=$(efivar -l) || return 1
    printf '%s\n' "$vars" | awk '
        tolower($0) ~ /^8be4df61-93ca-11d2-aa0d-00e098032b8c-boot[0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/ {
            print toupper(substr($0,length($0)-3))
        }
    ' | sort -u
}

efi_bootorder() {
    local listing
    listing=$(efibootmgr) || return 1
    printf '%s\n' "$listing" | awk -F: '/^BootOrder[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
}

efi_bootnext_number() {
    local listing
    listing=$(efibootmgr) || return 1
    printf '%s\n' "$listing" | awk -F: '/^BootNext[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
}

# Reserve a deterministic unused boot number, including missing BootOrder
# entries. FreeBSD efibootmgr -c -b HEX also refuses an existing variable.
efi_choose_boot_number() {
    printf '%s\n' "$1" | awk -v order="$2" '
        { if(NF) used[toupper($0)]=1 }
        END {
            n=split(order,a,",")
            for(i=1;i<=n;i++) used[toupper(a[i])]=1
            for(i=0;i<=65535;i++) {
                slot=sprintf("%04X",i)
                if(!(slot in used)) { print slot; exit }
            }
            exit 1
        }
    '
}

efi_verify_created_entry() {
    local listing="$1" number="$2" title="$3"
    printf '%s\n' "$listing" | awk -v number="$number" -v title="$title" '
        {
            line=$0
            sub(/^[[:space:]]*[+*]?Boot/,"",line)
            if(toupper(substr(line,1,4)) != number) next
            line=substr(line,5)
            if(substr(line,1,1)!="*") next
            sub(/^\*[[:space:]]+/,"",line)
            if(line==title) count++
        }
        END {exit count!=1}
    '
}

install_freebsd_bootnext_entry() {
    ensure_freebsd_boot_tools
    command -v efivar >/dev/null 2>&1 || error "efivar is required on FreeBSD"
    local before num order bootnext current listing after created

    listing=$(efibootmgr -v) || error "Cannot inspect current UEFI entries"
    info "UEFI entries before bootstrap:"
    printf '%s\n' "$listing"
    if printf '%s\n' "$listing" | grep -Fq "$ALPINE_ENTRY_TITLE"; then
        error "An existing Alpine reinstall EFI entry needs manual removal"
    fi
    order=$(efi_bootorder) || error "Cannot read original UEFI BootOrder"
    match_ere "$order" '^[0-9A-F]{4}(,[0-9A-F]{4})*$' ||
        error "Could not safely capture the original UEFI BootOrder"

    before=$(efi_boot_variable_numbers) || error "Cannot enumerate EFI boot variables"
    [ -n "$before" ] || error "EFI boot variable inventory is empty"
    num=$(efi_choose_boot_number "$before" "$order") || error "No unused EFI boot number"
    match_ere "$num" '^[0-9A-F]{4}$' || error "Invalid EFI boot number"
    info "Creating one-time Alpine boot entry Boot$num"
    if ! created=$(efibootmgr -a -c -b "$num" -l "$ALPINE_FREEBSD_GRUB_EFI_ABS" -L "$ALPINE_ENTRY_TITLE" 2>&1); then
        printf '%s\n' "$created" >&2
        error "Failed to create UEFI boot entry"
    fi
    printf '%s\n' "$created"

    # Restore the original order immediately, before any further validation.
    # Only this explicitly reserved and successfully created entry may be
    # removed on rollback. Never delete an existing entry by its label.
    if ! efibootmgr -o "$order" >/dev/null; then
        efibootmgr -B -b "$num" >/dev/null 2>&1 || true
        error "Failed to restore original UEFI BootOrder"
    fi
    current=$(efi_bootorder) || error "Cannot verify restored UEFI BootOrder"
    [ "$current" = "$order" ] || error "UEFI BootOrder changed unexpectedly: $current"
    after=$(efi_boot_variable_numbers) || error "Cannot verify new EFI variable"
    if ! printf '%s\n' "$after" | grep -Fxq "$num" ||
       ! efi_verify_created_entry "$created" "$num" "$ALPINE_ENTRY_TITLE"; then
        efibootmgr -B -b "$num" >/dev/null 2>&1 || true
        error "New UEFI boot variable or active entry label could not be verified"
    fi
    if ! efibootmgr -n -b "$num" >/dev/null; then
        efibootmgr -B -b "$num" >/dev/null 2>&1 || true
        error "Failed to set BootNext=$num"
    fi
    bootnext=$(efi_bootnext_number) || error "Cannot verify BootNext"
    [ "$bootnext" = "$num" ] || error "BootNext verification failed: $bootnext != $num"
    info "BootNext=$num ($ALPINE_ENTRY_TITLE); original BootOrder preserved"
}

check_secure_boot() {
    if [ "$OS" = FreeBSD ]; then
        # efivar returns the one-byte UEFI global SecureBoot variable.
        local sb
        local efiv
        efiv=$(mktemp) || error "Cannot allocate EFI variable buffer"
        if efivar -N -b -p -n 8be4df61-93ca-11d2-aa0d-00e098032b8c-SecureBoot >"$efiv" 2>/dev/null && [ "$(wc -c <"$efiv" | tr -d ' ')" = 1 ]; then
            sb=$(od -An -tu1 "$efiv" | tr -d '[:space:]')
        else
            sb=
        fi
        rm -f "$efiv"
        case "$sb" in
            0) info "Secure Boot disabled (FreeBSD EFI variable)"; return 0 ;;
            1) error "UEFI Secure Boot is enabled; unsigned Alpine bootstrap is unsupported" ;;
            *) if [ "${DDIFY_ASSUME_SECURE_BOOT_DISABLED:-0}" = 1 ]; then
                   warn "FreeBSD Secure Boot state unknown; using explicitly confirmed disabled state"
                   return 0
               fi
               error "FreeBSD Secure Boot status unknown; verify firmware settings before reinstalling" ;;
        esac
    fi
    local value="" status="" kernel_messages=""
    [ -d /sys/firmware/efi ] || return 0
    kernel_messages=$(dmesg 2>/dev/null || true)
    if printf '%s\n' "$kernel_messages" | grep -Fqi 'Secure boot enabled'; then
        error "UEFI Secure Boot is enabled; unsigned Alpine bootstrap is unsupported"
    fi
    if ! command -v mokutil >/dev/null 2>&1; then
        detect_linux_family
        case "$LINUX_FAMILY" in
            redhat)
                command -v dnf >/dev/null 2>&1 || error "Cannot install mokutil: dnf unavailable"
                info "Installing mokutil for Secure Boot detection"
                dnf install -y mokutil || error "Failed to install mokutil"
                ;;
            debian)
                command -v apt-get >/dev/null 2>&1 || error "Cannot install mokutil: apt-get unavailable"
                info "Installing mokutil for Secure Boot detection"
                apt-get update && apt-get install -y mokutil || error "Failed to install mokutil"
                ;;
            *)
                error "mokutil is missing and automatic installation is unsupported on this Linux distribution"
                ;;
        esac
    fi
    command -v mokutil >/dev/null 2>&1 || error "mokutil is unavailable after dependency installation"
    status=$(mokutil --sb-state 2>&1 || true)
    if printf '%s\n' "$status" | grep -Eiq '^(SecureBoot|Secure Boot)[[:space:]]+enabled([[:space:]]|$)'; then
        value=1
    elif printf '%s\n' "$status" | grep -Eiq '^(SecureBoot|Secure Boot)[[:space:]]+disabled([[:space:]]|$)'; then
        value=0
        info "Secure Boot disabled (mokutil)"
    elif { { case "$status" in *"doesn't support Secure Boot"*) true ;; *) false ;; esac; } || { case "$status" in *"SecureBoot not supported"*) true ;; *) false ;; esac; }; } &&
         printf '%s\n' "$kernel_messages" | grep -Fqi 'Secure boot disabled'; then
        value=0
        info "Secure Boot unsupported by firmware; kernel confirms disabled"
    fi
    case "$value" in
        0) return 0 ;;
        1) error "UEFI Secure Boot is enabled; unsigned Alpine bootstrap is unsupported" ;;
    esac
    if [ "${DDIFY_ASSUME_SECURE_BOOT_DISABLED:-0}" = 1 ]; then
        warn "Secure Boot status is unknown; proceeding only because DDIFY_ASSUME_SECURE_BOOT_DISABLED=1 was set"
        return 0
    fi
    error "Secure Boot status unknown. Verify 'mokutil --sb-state' (install mokutil if needed); if independently confirmed disabled, use DDIFY_ASSUME_SECURE_BOOT_DISABLED=1"
}

prepare_and_boot_alpine_ram() {
    check_secure_boot
    prepare_alpine_paths
    local boot_disk
    if [ "$OS" = Linux ]; then
        boot_disk=$(linux_source_to_disk "$PLAN_EFI_PART" || true)
    else
        boot_disk=$(freebsd_provider_to_disk "$PLAN_EFI_PART" || true)
    fi
    { [ -n "$boot_disk" ] && [ "$boot_disk" = "$DISK" ]; } || \
        error "Bootstrap partition is not on target disk $DISK; refusing unsafe cross-disk install"
    download_alpine_ram_files
    build_alpine_apkovl

    case "$OS" in
        Linux)
            install_grub_entry_for_alpine
            info "Rebooting into one-time GRUB entry: $ALPINE_ENTRY_TITLE"
            sync
            sleep 2
            reboot
            ;;
        FreeBSD)
            build_freebsd_grub_efi
            install_freebsd_bootnext_entry
            info "Rebooting into one-time UEFI entry: $ALPINE_ENTRY_TITLE"
            sync
            sleep 2
            shutdown -r now
            ;;
        *)
            error "Unsupported bootstrap host: $OS"
            ;;
    esac
}

# ----------------- installer execution -----------------

reread_partition_table_strict() {
    sync

    local reread_ok=0

    if command -v blockdev >/dev/null 2>&1; then
        if blockdev --rereadpt "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    if command -v partprobe >/dev/null 2>&1; then
        if partprobe "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    if command -v partx >/dev/null 2>&1; then
        if partx -u "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        elif partx -a "$DISK" >/dev/null 2>&1; then
            reread_ok=1
        fi
    fi

    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    [ "$reread_ok" -eq 1 ] || {
        warn "Kernel could not reread the target partition table."
        lsblk -a -o NAME,PATH,TYPE,SIZE,PARTN,PARTLABEL "$DISK" >&2 2>/dev/null || true
        error "Failed to synchronize the target partition table with the kernel"
    }
}

create_mbr_cidata_partition() {
    local table line num type slot= last_end=0 start size sectors dev
    command -v sfdisk >/dev/null 2>&1 || error "sfdisk is required for MBR CIDATA"
    table=$(sfdisk -d "$DISK") || error "Cannot read target MBR for CIDATA"
    { case "$table" in *"label: dos"*) true ;; *) false ;; esac; } || error "Target is not an MBR disk"
    if lsblk -nr -o LABEL "$DISK" | awk '$0 == "CIDATA" {found=1} END {exit !found}'; then
        error "Target MBR image already contains a CIDATA volume"
    fi

    local used=""
    while IFS= read -r line; do
        { { case "$line" in "$DISK"*' : '*) true ;; *) false ;; esac; } || { case "$line" in "$DISK"*' :'*) true ;; *) false ;; esac; }; } || continue
        start=$(printf '%s\n' "$line" | sed -nE 's/.*start=[[:space:]]*([0-9]+).*/\1/p')
        [ -n "$start" ] || error "Malformed MBR partition start"
        size=$(printf '%s\n' "$line" | sed -nE 's/.*size=[[:space:]]*([0-9]+).*/\1/p')
        [ -n "$size" ] || error "Malformed MBR partition size"
        type=$(printf '%s\n' "$line" | sed -nE 's/.*type=[[:space:]]*([[:xdigit:]]+).*/\1/p')
        [ -n "$type" ] || error "Malformed MBR partition type"
        num="${line%%:*}"; num="${num%% *}"; num="${num#"$DISK"}"; num="${num#p}"
        match_ere "$num" '^[1-4]$' || error "Extended/logical MBR partitions are unsupported"
        case "$(to_lower "$type")" in 5|05|f|0f|85) error "Extended MBR partitions are unsupported" ;; esac
        used="$used $num"
        [ "$(( start + size - 1 > last_end ))" -ne 0 ] && last_end=$((start + size - 1))
    done <<DDIFY_INPUT_19
$table
DDIFY_INPUT_19
    for num in 1 2 3 4; do
        case " $used " in *" $num "*) ;; *) slot=$num; break ;; esac
    done
    [ -n "$slot" ] || error "No free MBR primary partition slot for CIDATA"
    start=$((((last_end + 2048) / 2048) * 2048))
    size=32768
    sectors=$(blockdev --getsz "$DISK")
    [ "$(( start >= 2048 && start + size + 2048 <= sectors ))" -ne 0 ] ||         error "Not enough trailing MBR space for the 16 MiB CIDATA partition"

    printf 'start=%s, size=%s, type=e\n' "$start" "$size" |         sfdisk --no-reread --no-tell-kernel -N "$slot" "$DISK" >/dev/null ||         error "Could not create MBR CIDATA partition"
    reread_partition_table_strict
    dev=$(partition_device_for_number "$DISK" "$slot")
    ensure_linux_block_node_from_sysfs "$dev" || [ -b "$dev" ] || error "MBR CIDATA partition node missing"
    mkfs.vfat -F 16 -n CIDATA "$dev" >/dev/null || error "Cannot format MBR CIDATA"
    printf '%s\n' "$dev"
}

create_nocloud_cidata_partition() {
    [ "$OS" = "Linux" ] || error "Creating the standard NoCloud CIDATA partition requires the Linux/Alpine installer environment"
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required to create a standard NoCloud CIDATA partition"
    command -v mkfs.vfat >/dev/null 2>&1 || error "mkfs.vfat is required to create a standard NoCloud CIDATA partition"

    if ! sgdisk -p "$DISK" >/dev/null 2>&1; then
        error "Target image does not expose a usable GPT; refusing non-standard EFI:/nocloud injection"
    fi

    if [ "${QCOW_PARTITION_TABLE:-gpt}" = dos ]; then
        create_mbr_cidata_partition
        return
    fi

    local existing_cidata seed_part seed_matches
    existing_cidata=$(lsblk -lnpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk '$2=="CIDATA" {print $1}')
    [ -z "$existing_cidata" ] || error "Image already contains a CIDATA partition; refusing to format an ambiguous seed: $existing_cidata"

    info "Creating temporary 16 MiB NoCloud CIDATA seed partition..."
    sgdisk -e "$DISK" >/dev/null || error "Failed to relocate GPT backup header on $DISK"
    sgdisk -n 0:0:+16M -t 0:0700 -c 0:CIDATA "$DISK" >/dev/null || \
        error "Failed to create CIDATA partition; target disk may not have enough unallocated GPT space"
    reread_partition_table_strict
    sleep 1

    seed_matches=$(lsblk -lnpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk '$2=="CIDATA" {print $1}') || error "Cannot list CIDATA partitions"
    case "$seed_matches" in ''|*"$NL"*) error "Expected exactly one newly created CIDATA partition" ;; esac
    seed_part=$seed_matches
    [ -b "$seed_part" ] || error "New CIDATA partition is not a block device: $seed_part"
    mkfs.vfat -F 16 -n CIDATA "$seed_part" >/dev/null || error "Failed to format CIDATA partition: $seed_part"
    printf '%s\n' "$seed_part"
}

TEMP_STAGE_SIZE_MIB=3072
TEMP_STAGE_SIZE_BYTES=$((TEMP_STAGE_SIZE_MIB * 1024 * 1024))
TEMP_STAGE_PART_NUM=1
TEMP_STAGE_LABEL="REINSTALL_TMP"
TEMP_STAGE_MNT="/mnt/reinstall-stage"
TEMP_STAGE_PART=""
TEMP_STAGE_START_SECTOR=""
TEMP_STAGE_START_BYTES=""
TEMP_STAGE_SECTOR_SIZE=""
QCOW_VIRTUAL_SIZE=""
QCOW_GPT_GUID=""
QCOW_MBR_ID=""
QCOW_PARTITION_TABLE="gpt"
QCOW_MAX_PART_END_BYTES=""
QCOW_MAX_PART_END_SECTOR=""
QCOW_PARTITION_CROSSES_STAGE=0
QCOW_NBD_DEV=""
TEMP_STAGE_RELEASED=0

partition_device_for_number() {
    local disk="$1" num="$2"
    case "$disk" in
        /dev/nvme*|/dev/mmcblk*|/dev/loop*|/dev/nbd*)
            printf '%sp%s\n' "$disk" "$num"
            ;;
        *)
            printf '%s%s\n' "$disk" "$num"
            ;;
    esac
}

ensure_linux_block_node_from_sysfs() {
    local devpath="$1" name sysdev maj min

    [ -n "$devpath" ] || return 1
    [ -b "$devpath" ] && return 0

    name="${devpath#/dev/}"
    sysdev="/sys/class/block/$name/dev"

    [ -r "$sysdev" ] || return 1

    IFS=: read -r maj min <"$sysdev"
    { match_ere "$maj" '^[0-9]+$' && match_ere "$min" '^[0-9]+$'; } || return 1

    if { [ -e "$devpath" ] && ! [ -b "$devpath" ]; }; then
        rm -f "$devpath"
    fi

    mknod "$devpath" b "$maj" "$min" || return 1
    chmod 0600 "$devpath" 2>/dev/null || true

    [ -b "$devpath" ]
}

reset_disk_for_staging() {
    { [ -z "${DISK_ID_PTUUID:-}" ] || match_ere "$DISK_ID_PTUUID" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'; } ||
        error "Invalid saved GPT GUID; refusing destructive write"
    wipefs -a "$DISK" >/dev/null || error "Cannot clear target disk signatures"
    sgdisk -Z "$DISK" >/dev/null || error "Cannot clear target partition tables"
    partx -d "$DISK" >/dev/null 2>&1 || true
    blockdev --rereadpt "$DISK" >/dev/null 2>&1 || true
    mdev -s 2>/dev/null || true

    sgdisk -o "$DISK" >/dev/null || error "Failed to create temporary GPT"
    if [ -n "${DISK_ID_PTUUID:-}" ]; then
        sgdisk -U "$DISK_ID_PTUUID" "$DISK" >/dev/null || error "Failed to preserve target GPT identity"
    fi
    sgdisk -n "${TEMP_STAGE_PART_NUM}:-${TEMP_STAGE_SIZE_MIB}M:0" -t "${TEMP_STAGE_PART_NUM}:8300" \
        -c "${TEMP_STAGE_PART_NUM}:${TEMP_STAGE_LABEL}" "$DISK" >/dev/null || error "Failed to create staging partition"
    reread_partition_table_strict
}

wait_for_stage_partition() {
    local i
    TEMP_STAGE_PART=$(partition_device_for_number "$DISK" "$TEMP_STAGE_PART_NUM")
    for i in 1 2 3 4 5 6 7 8; do
        [ -b "$TEMP_STAGE_PART" ] && return
        partx -u "$DISK" >/dev/null 2>&1 || partx -a "$DISK" >/dev/null 2>&1 || true
        mdev -s 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        ensure_linux_block_node_from_sysfs "$TEMP_STAGE_PART" && return
        sleep 1
    done
    sgdisk -p "$DISK" >&2 || true
    lsblk -a -o NAME,PATH,TYPE,SIZE,PARTN,PARTLABEL,MAJ:MIN "$DISK" >&2 || true
    error "Staging partition node did not appear: $TEMP_STAGE_PART"
}

read_stage_geometry() {
    local first last actual
    TEMP_STAGE_SECTOR_SIZE=$(blockdev --getss "$DISK")
    first=$(sgdisk -i "$TEMP_STAGE_PART_NUM" "$DISK" | awk '/First sector:/ {print $3; exit}')
    last=$(sgdisk -i "$TEMP_STAGE_PART_NUM" "$DISK" | awk '/Last sector:/ {print $3; exit}')
    { match_ere "$first" '^[0-9]+$' && match_ere "$last" '^[0-9]+$'; } || error "Could not read staging geometry"

    TEMP_STAGE_START_SECTOR="$first"
    TEMP_STAGE_START_BYTES=$((first * TEMP_STAGE_SECTOR_SIZE))
    actual=$(((last - first + 1) * TEMP_STAGE_SECTOR_SIZE))
    [ "$(( actual >= TEMP_STAGE_SIZE_BYTES - 2 * 1024 * 1024 ))" -ne 0 ] || error "Staging partition is smaller than requested ${TEMP_STAGE_SIZE_MIB} MiB"
    TEMP_STAGE_LAST_SECTOR="$last"
}

prepare_fixed_temp_staging_partition() {
    local disk_size min_remaining=$((2 * 1024 * 1024 * 1024))
    [ "$OS" = Linux ] || error "Staging requires Alpine/Linux"
    disk_size=$(get_disk_size_bytes "$DISK")
    [ "$(( disk_size > TEMP_STAGE_SIZE_BYTES + min_remaining ))" -ne 0 ] || error "Target disk cannot accommodate the requested ${TEMP_STAGE_SIZE_MIB} MiB staging"

    info "Preparing ${TEMP_STAGE_SIZE_MIB} MiB staging partition at the end of $DISK"
    reset_disk_for_staging
    wait_for_stage_partition
    read_stage_geometry

    mkfs.ext4 -F -m 0 -L "$TEMP_STAGE_LABEL" "$TEMP_STAGE_PART" >/dev/null || error "Failed to format staging partition"
    mkdir -p "$TEMP_STAGE_MNT"
    mount -t ext4 -o noatime "$TEMP_STAGE_PART" "$TEMP_STAGE_MNT" || error "Failed to mount staging partition"

    info "Staging: $TEMP_STAGE_PART mounted at $TEMP_STAGE_MNT"
    info "Staging boundary: ${TEMP_STAGE_START_BYTES} bytes"
    df -h "$TEMP_STAGE_MNT" || true
}

cleanup_qcow_nbd() {
    if [ -n "${QCOW_NBD_DEV:-}" ]; then
        qemu-nbd --disconnect "$QCOW_NBD_DEV" >/dev/null || return 1
        QCOW_NBD_DEV=""
    fi
}

connect_qcow_readonly_nbd() {
    local img="$1" n dev size

    command -v qemu-nbd >/dev/null 2>&1 || error "qemu-nbd is required to inspect qcow2 partition layout"
    modprobe nbd max_part=64 >/dev/null 2>&1 || error "Could not load nbd kernel module"
    mdev -s 2>/dev/null || true

    for n in $(seq 0 15); do
        dev="/dev/nbd$n"
        [ -b "$dev" ] || continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [ "$size" = "0" ] || continue
        if qemu-nbd --connect="$dev" --read-only --format=qcow2 "$img" >/dev/null 2>&1; then
            QCOW_NBD_DEV="$dev"
            sleep 1
            return 0
        fi
    done

    error "Could not allocate a free NBD device for qcow2 inspection"
}

inspect_qcow_partition_layout() {
    local img="$1" nbd sector_size max_end table

    QCOW_VIRTUAL_SIZE=$(get_qcow_virtual_size_bytes "$img" || true)
    { match_ere "$QCOW_VIRTUAL_SIZE" '^[0-9]+$' && [ "$QCOW_VIRTUAL_SIZE" -gt 0 ]; } || \
        error "Could not determine qcow2 virtual size"

    connect_qcow_readonly_nbd "$img"
    nbd="$QCOW_NBD_DEV"

    local nbd_virtual_size
    nbd_virtual_size=$(blockdev --getsize64 "$nbd" 2>/dev/null || true)
    { match_ere "$nbd_virtual_size" '^[0-9]+$' && [ "$nbd_virtual_size" -gt 0 ]; } ||         error "Could not determine qcow2 guest-visible size through qemu-nbd"
    if [ "$QCOW_VIRTUAL_SIZE" != "$nbd_virtual_size" ]; then
        warn "qemu-img reported ${QCOW_VIRTUAL_SIZE} bytes, but qemu-nbd exposes ${nbd_virtual_size} bytes; using qemu-nbd size."
    fi
    QCOW_VIRTUAL_SIZE="$nbd_virtual_size"

    QCOW_PARTITION_TABLE=$(blkid -p -s PTTYPE -o value "$nbd" 2>/dev/null || true)
    case "$QCOW_PARTITION_TABLE" in
        gpt) ;;
        dos)
            { [ "$TARGET_OS" != freebsd ] && ! [ -d /sys/firmware/efi ]; } ||                 error "MBR images are supported for Linux BIOS boot only"
            local dump line num start size type count=0
            dump=$(sfdisk -d "$nbd") || error "Cannot inspect MBR image"
            { case "$dump" in *"label: dos"*) true ;; *) false ;; esac; } || error "Malformed MBR image"
            QCOW_MBR_ID=$(printf '%s\n' "$dump" | sed -n 's/^label-id: //p' | head -n1)
            match_ere "$QCOW_MBR_ID" '^0x[[:xdigit:]]{8}$' || error "Invalid MBR disk signature"
            max_end=0
            while IFS= read -r line; do
                { { case "$line" in "$nbd"*' : '*) true ;; *) false ;; esac; } || { case "$line" in "$nbd"*' :'*) true ;; *) false ;; esac; }; } || continue
                start=$(printf '%s\n' "$line" | sed -nE 's/.*start=[[:space:]]*([0-9]+).*/\1/p')
                [ -n "$start" ] || error "Invalid MBR start sector"
                size=$(printf '%s\n' "$line" | sed -nE 's/.*size=[[:space:]]*([0-9]+).*/\1/p')
                [ -n "$size" ] || error "Invalid MBR partition length"
                type=$(printf '%s\n' "$line" | sed -nE 's/.*type=[[:space:]]*([[:xdigit:]]+).*/\1/p')
                [ -n "$type" ] || error "Invalid MBR partition type"
                num="${line%%:*}"; num="${num%% *}"; num="${num#"$nbd"}"; num="${num#p}"
                match_ere "$num" '^[1-4]$' || error "MBR logical partitions are not supported"
                case "$(to_lower "$type")" in 5|05|f|0f|85) error "MBR extended partitions are not supported" ;; esac
                count=$((count + 1)); [ "$count" -le 3 ] || error "MBR image has no free primary slot for CIDATA"
                [ "$(( size > 0 && start >= 2048 && start + size <= QCOW_VIRTUAL_SIZE / 512 ))" -ne 0 ] ||                     error "Invalid MBR partition boundaries"
                [ "$(( start + size - 1 > max_end ))" -ne 0 ] && max_end=$((start + size - 1))
            done <<DDIFY_INPUT_20
$dump
DDIFY_INPUT_20
            [ "$(( count > 0 ))" -ne 0 ] || error "MBR image contains no primary partitions"
            sfdisk --verify "$nbd" >/dev/null || error "Inconsistent MBR partition layout"
            sector_size=$(blockdev --getss "$nbd")
            { [ "$sector_size" = 512 ] && [ "$sector_size" = "$(blockdev --getss "$DISK")" ]; } ||                 error "MBR image requires matching 512-byte logical sectors"
            QCOW_MAX_PART_END_SECTOR="$max_end"
            QCOW_MAX_PART_END_BYTES=$(((max_end + 1) * sector_size))
            [ "$(( QCOW_MAX_PART_END_BYTES + 8 * 1024 * 1024 <= TEMP_STAGE_START_BYTES ))" -ne 0 ] ||                 error "MBR image partitions cross the staging area; MBR shrinking is unsupported"
            cleanup_qcow_nbd || error "Cannot disconnect validated source NBD"
            QCOW_PARTITION_CROSSES_STAGE=0
            info "MBR image partitions end at ${QCOW_MAX_PART_END_BYTES} bytes; staging starts at ${TEMP_STAGE_START_BYTES} bytes"
            return 0
            ;;
        *) error "Target QCOW2 partition table must be GPT or DOS/MBR" ;;
    esac

    if ! table=$(sgdisk -p "$nbd" 2>&1); then
        echo "$table" >&2
        error "Target qcow2 does not expose a usable GPT; cannot safely use an in-disk staging partition"
    fi

    verify_gpt_strict "$nbd"
    QCOW_GPT_GUID=$(printf '%s\n' "$table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    match_ere "$QCOW_GPT_GUID" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' || \
        error "Target image has no valid GPT disk GUID"

    sector_size=$(blockdev --getss "$nbd" 2>/dev/null || true)
    { match_ere "$sector_size" '^[0-9]+$' && [ "$sector_size" -gt 0 ]; } || \
        error "Could not determine qcow2 logical sector size"
    [ "$sector_size" = "$(blockdev --getss "$DISK")" ] || error "Image/target logical sector-size mismatch"

    max_end=$(printf '%s\n' "$table" | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {
            if ($3 + 0 > max + 0) max=$3
        }
        END { if (max != "") print max }
    ')
    match_ere "$max_end" '^[0-9]+$' || error "Could not determine the last partition sector inside qcow2"

    QCOW_MAX_PART_END_SECTOR="$max_end"
    QCOW_MAX_PART_END_BYTES=$(((max_end + 1) * sector_size))

    cleanup_qcow_nbd || error "Cannot disconnect validated source NBD"

    info "qcow2 virtual size:          ${QCOW_VIRTUAL_SIZE} bytes"
    info "qcow2 last partition end:    ${QCOW_MAX_PART_END_BYTES} bytes"
    info "temporary partition begins:  ${TEMP_STAGE_START_BYTES} bytes"

    QCOW_PARTITION_CROSSES_STAGE=0

    # A cloud image may have a sparse logical layout that crosses staging.
    # This requires separate, explicitly budgeted shadow handling.
    if [ "$QCOW_MAX_PART_END_BYTES" -gt $((TEMP_STAGE_START_BYTES - 8 * 1024 * 1024)) ]; then
        QCOW_PARTITION_CROSSES_STAGE=1
        warn "qcow2 GPT layout reaches the temporary staging area."
        warn "Overlapping staging will be refused; no full RAW shadow is allocated."
    fi

    # Never trust a QCOW2 virtual size smaller than its GPT partition extent.
    if [ "$QCOW_VIRTUAL_SIZE" -lt "$QCOW_MAX_PART_END_BYTES" ]; then
        warn "qemu-img virtual-size (${QCOW_VIRTUAL_SIZE}) is smaller than GPT partition end (${QCOW_MAX_PART_END_BYTES}); refusing to trust the smaller value for write-safety decisions."
        QCOW_VIRTUAL_SIZE="$QCOW_MAX_PART_END_BYTES"
        QCOW_PARTITION_CROSSES_STAGE=1
    fi
}

# Official HTTPS checksum manifests protect built-in images without adding CLI options.
# Manifest authenticity relies on TLS; this is not a GPG-signature verification.
image_checksum_from_official_manifest() {
    local name="${IMG_URL##*/}" base="${IMG_URL%/*}" url algo=SHA256 manifest expected
    case "$TARGET_OS" in
        rocky)      url="${IMG_URL}.CHECKSUM" ;;
        almalinux)  url="$base/CHECKSUM" ;;
        fedora)     url="$base/Fedora-Cloud-44-1.7-${MACHINE_ARCH}-CHECKSUM" ;;
        freebsd)    url="$base/CHECKSUM.SHA256" ;;
        debian)     url="$base/SHA512SUMS"; algo=SHA512 ;;
        *) error "No official checksum source for built-in $TARGET_OS image" ;;
    esac
    manifest="$INSTALL_TMPDIR/official-image-checksum"
    curl -fL --progress-bar --proto '=https' --proto-redir '=https' "$url" -o "$manifest" ||
        error "Could not retrieve official checksum manifest: $url"
    expected=$(awk -v file="$name" -v algorithm="$algo" '
        $1 == algorithm && $2 == "(" file ")" && $3 == "=" { print $4; exit }
        $2 == file || $2 == "*" file { print $1; exit }
    ' "$manifest")
    case "$algo:$expected" in
        SHA256:*) match_ere "$expected" '^[[:xdigit:]]{64}$' ;;
        SHA512:*) match_ere "$expected" '^[[:xdigit:]]{128}$' ;;
    esac || error "Official checksum manifest lacks a valid entry for $name"
    IMAGE_HASH_ALGO="$(to_lower "$algo")"
    IMAGE_HASH_EXPECTED="$(to_lower "$expected")"
}

prepare_image_validation() {
    case "$IMG_URL" in https://*) ;; *) error "Target image must use HTTPS" ;; esac
    validate_target_capacity
    if [ "${IMAGE_BUILTIN:-0}" = 1 ]; then
        image_checksum_from_official_manifest
    else
        IMAGE_HASH_EXPECTED="" IMAGE_HASH_ALGO=""
        warn "Custom --img has no publisher-verified checksum; partition layout will still be validated"
    fi
    calculate_disk_staging_budget
    if ! image_is_freebsd_raw; then
        probe_remote_qcow_virtual_size >/dev/null || error "Cannot read remote QCOW2 header before disk commit"
    fi
}

# The script never accepts decompression output beyond the negotiated workspace limit.
bounded_image_copy() {
    local limit="$1"
    match_ere "$limit" '^[0-9]+$' && [ "$limit" -gt 0 ] || return 1
    # Copy at most one excess byte; the caller rejects oversized output by
    # stat and pipefail rejects a prematurely terminated decoder/downloader.
    head -c "$((limit + 1))"
}

download_target_image_in_alpine() {
    local dst="$1" tmp="${1}.part.$$" remote_size allocated digest= hash_pid= fifo=

    rm -f "$tmp"
    { case "$IMG_URL" in https://*) true ;; *) false ;; esac; } || error "Target image must use HTTPS"
    { [ -n "${IMAGE_HASH_ALGO:-}" ] || [ -z "${IMAGE_HASH_EXPECTED:-}" ]; } || error "Missing image checksum algorithm"
    info "Downloading target image to verified workspace: $IMG_URL"
    local limit="${IMAGE_DOWNLOAD_LIMIT_BYTES:?missing image staging limit}"
    { match_ere "$limit" '^[0-9]+$' && [ "$limit" -gt 0 ]; } || error "Invalid image download limit"

    remote_size=$(http_content_length "$IMG_URL" || true)
    if { match_ere "$remote_size" '^[0-9]+$' && [ "$remote_size" -gt "$limit" ]; }; then
        error "Remote image exceeds available validated staging budget: ${remote_size} > ${limit} bytes"
    fi

    if { case "$IMG_URL" in *.xz) true ;; *) false ;; esac; }; then
        if [ -n "$IMAGE_HASH_EXPECTED" ]; then
            fifo="$INSTALL_TMPDIR/image-checksum.fifo"
            mkfifo "$fifo" || error "Could not create image checksum pipe"
            "${IMAGE_HASH_ALGO}sum" <"$fifo" >"$INSTALL_TMPDIR/image-hash" &
            hash_pid=$!
            if ! curl -fL --progress-bar --proto '=https' --proto-redir '=https' "$IMG_URL" |
                    tee "$fifo" | xz --threads=1 --memlimit-decompress=128MiB -dc | bounded_image_copy "$limit" >"$tmp"; then
                rm -f "$tmp" "$fifo"
                wait "$hash_pid" || true
                error "Failed to download/decompress target image"
            fi
            wait "$hash_pid" || error "Failed to calculate compressed image hash"
            rm -f "$fifo"
            digest=$(awk '{print $1; exit}' "$INSTALL_TMPDIR/image-hash")
        else
            curl -fL --progress-bar --proto '=https' --proto-redir '=https' "$IMG_URL" |
                xz --threads=1 --memlimit-decompress=128MiB -dc | bounded_image_copy "$limit" >"$tmp" ||
                error "Failed to download/decompress target image"
        fi
    else
        curl -fL --progress-bar --max-filesize "$limit" --proto '=https' --proto-redir '=https' "$IMG_URL" -o "$tmp" ||
            error "Failed to download target image"
        [ -z "$IMAGE_HASH_EXPECTED" ] ||
            digest=$("${IMAGE_HASH_ALGO}sum" "$tmp" | awk '{print $1}')
    fi
    if [ -n "$IMAGE_HASH_EXPECTED" ]; then
        [ "$(to_lower "$digest")" = "$IMAGE_HASH_EXPECTED" ] || error "Official image checksum mismatch"
        info "Official $(to_upper "$IMAGE_HASH_ALGO") checksum verified (HTTPS manifest; signature not checked)"
    fi

    local actual_bytes
    actual_bytes=$(stat -c %s "$tmp") || error "Cannot stat downloaded image"
    [ "$(( actual_bytes <= limit ))" -ne 0 ] || error "Expanded QCOW2 exceeds staging policy: $actual_bytes bytes"
    validate_qcow_metadata "$tmp"
    mv -f "$tmp" "$dst"
    sync
    allocated=$(du -B1 "$dst" 2>/dev/null | awk '{print $1; exit}' || true)
    info "Verified QCOW2 ready: $dst"
    [ -n "$allocated" ] && info "qcow2 allocated staging space: ${allocated} bytes"
    df -h "$(dirname "$dst")" || true
}

validate_qcow_metadata() {
    local img="$1" json
    json=$(qemu-img info -f qcow2 --output=json "$img") || error "Could not parse QCOW2 metadata"
    printf '%s\n' "$json" | jq -e '
        type == "object" and
        .format == "qcow2" and
        ((.encrypted // false) == false) and
        ((has("backing-filename") or has("full-backing-filename") or has("backing-filename-format")) | not) and
        (."format-specific".data // {} | ((has("data-file") or has("data-file-raw")) | not)) and
        (."virtual-size" | type == "number") and
        (."virtual-size" > 0 and (."virtual-size" | floor) == ."virtual-size")
    ' >/dev/null || error "QCOW2 needs external resources, is encrypted, or has unsupported metadata"
    qemu-img check -f qcow2 "$img" >/dev/null || error "QCOW2 structural check failed"
}

get_qcow_virtual_size_bytes() {
    qemu-img info --output=json "$1" 2>/dev/null | jq -er '."virtual-size" | select(type == "number" and . > 0 and floor == .)'
}

write_qcow_without_overwriting_staging() {
    local img="$1" bs_arg count_arg

    [ -n "$TEMP_STAGE_START_BYTES" ] || error "Temporary staging boundary is unknown"
    TEMP_STAGE_RELEASED=0

    if [ "${QCOW_PARTITION_CROSSES_STAGE:-0}" = 1 ]; then
        error "QCOW2 partitions overlap protected staging; refusing full RAW shadow allocation"
    fi

    if [ "$QCOW_VIRTUAL_SIZE" -le "$TEMP_STAGE_START_BYTES" ]; then
        info "qcow2 virtual disk ends before the staging partition; converting the whole image."
        qemu-img convert -p -n -S 0 -f qcow2 -O raw "$img" "$DISK" || \
            error "qemu-img failed while writing the target disk"
        return 0
    fi

    # The virtual disk extends beyond staging, but verified partitions end
    # before it. Copy only the safe prefix, then reconstruct the backup GPT
    # after the temporary partition has been removed.
    if [ "$(( TEMP_STAGE_START_BYTES % (4 * 1024 * 1024) == 0 ))" -ne 0 ]; then
        bs_arg="4M"
        count_arg=$((TEMP_STAGE_START_BYTES / (4 * 1024 * 1024)))
    elif [ "$(( TEMP_STAGE_START_BYTES % (1024 * 1024) == 0 ))" -ne 0 ]; then
        bs_arg="1M"
        count_arg=$((TEMP_STAGE_START_BYTES / (1024 * 1024)))
    else
        bs_arg="$TEMP_STAGE_SECTOR_SIZE"
        count_arg="$TEMP_STAGE_START_SECTOR"
    fi

    info "qcow2 virtual size crosses the staging area, but all image partitions fit before it."
    info "Writing only the safe prefix with qemu-img dd: bs=$bs_arg count=$count_arg"
    qemu-img dd -f qcow2 -O raw "bs=$bs_arg" "count=$count_arg" \
        "if=$img" "of=$DISK" || error "qemu-img dd failed while writing the safe image prefix"
}

release_temp_staging_partition() {
    local old_stage="${TEMP_STAGE_PART:-}"

    sync
    cd /

    if is_mountpoint "$TEMP_STAGE_MNT"; then
        umount "$TEMP_STAGE_MNT" || error "Failed to unmount temporary staging partition"
    fi

    # Drop stale temporary partition mappings before repairing the target GPT.
    if command -v partx >/dev/null 2>&1; then
        if ! partx -d "$DISK" >/dev/null 2>&1; then
            warn "Could not immediately delete stale staging partition mappings with partx; continuing with GPT repair."
        fi
    fi

    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    if [ -n "$old_stage" ]; then
        info "Released temporary staging partition: $old_stage"
    fi

    TEMP_STAGE_PART=""
}

find_last_growable_gpt_partition() {
    local line num end code best_num="" best_code="" best_end=0

    while IFS= read -r line; do
        match_ere "$line" '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[[:xdigit:]]{4}([[:space:]]|$)' || continue
        set -- $line
        num=$1; end=$3; code=$(to_upper "$6")
        if [ "$(( end > best_end ))" -ne 0 ]; then
            best_end="$end"
            best_num="$num"
            best_code="$code"
        fi
    done <<DDIFY_INPUT_13
$(sgdisk -p "$DISK" 2>/dev/null || true)
DDIFY_INPUT_13

    [ -n "$best_num" ] || return 1
    case "$best_code" in
        EF00|EF02|8200|A502)
            warn "Last GPT partition is $best_code; skipping automatic expansion of EFI/BIOS/swap."
            return 2
            ;;
        FFFF)
            warn "Last GPT partition type is unknown; refusing automatic expansion."
            return 1
            ;;
    esac

    printf '%s\n' "$best_num"
}
grow_last_partition_reserving_cidata() {
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required to expand the target GPT"

    local partnum info_text start end type_guid unique_guid attrs name
    local sector_size reserve_bytes reserve_sectors last_usable new_end

    sgdisk -e "$DISK" >/dev/null || error "Failed to relocate/rebuild target backup GPT after staging write"

    partnum=$(find_last_growable_gpt_partition) || {
        local rc=$?
        [ "$rc" = 2 ] || error "Could not identify a safe final GPT data partition to expand"
        info "Leaving the trailing non-data partition unchanged; CIDATA will use available free space."
        return 0
    }

    info_text=$(sgdisk -i "$partnum" "$DISK" 2>/dev/null) || error "Failed to inspect target partition $partnum"
    start=$(printf '%s\n' "$info_text" | awk '/First sector:/ {print $3; exit}')
    end=$(printf '%s\n' "$info_text" | awk '/Last sector:/ {print $3; exit}')
    type_guid=$(printf '%s\n' "$info_text" | awk '/Partition GUID code:/ {print $4; exit}')
    unique_guid=$(printf '%s\n' "$info_text" | awk '/Partition unique GUID:/ {print $4; exit}')
    attrs=$(printf '%s\n' "$info_text" | awk '/Attribute flags:/ {print $3; exit}')
    name=$(printf '%s\n' "$info_text" | sed -n "s/^Partition name: '\(.*\)'$/\1/p" | head -n1)

    { match_ere "$start" '^[0-9]+$' && match_ere "$end" '^[0-9]+$' && [ -n "$type_guid" ]; } || \
        error "Could not preserve partition metadata while preparing expansion"

    sector_size=$(blockdev --getss "$DISK")
    reserve_bytes=$((32 * 1024 * 1024))
    reserve_sectors=$(((reserve_bytes + sector_size - 1) / sector_size))
    last_usable=$(sgdisk -p "$DISK" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p' | head -n1)
    { match_ere "$last_usable" '^[0-9]+$' && [ "$last_usable" -gt "$end" ]; } || \
        error "Could not identify safe trailing GPT space after the final data partition"
    new_end=$((last_usable - reserve_sectors))
    if [ "$new_end" -eq "$end" ]; then
        info "Target partition $partnum already ends at the CIDATA-safe boundary."
        return 0
    fi
    if [ "$new_end" -lt "$end" ]; then
        error "Target partition $partnum still extends beyond the CIDATA-safe boundary after image preparation; refusing an unsafe blind shrink"
    fi

    info "Expanding target GPT partition $partnum from end sector $end to $new_end; reserving temporary CIDATA alignment space."
    sgdisk -d "$partnum" "$DISK" >/dev/null || error "Failed to delete partition $partnum for boundary-only resize"
    sgdisk -n "${partnum}:${start}:${new_end}" "$DISK" >/dev/null || error "Failed to recreate expanded partition $partnum"
    sgdisk -t "${partnum}:${type_guid}" "$DISK" >/dev/null || error "Failed to restore GPT type for partition $partnum"
    [ -z "$unique_guid" ] || sgdisk -u "${partnum}:${unique_guid}" "$DISK" >/dev/null || error "Failed to restore PARTUUID for partition $partnum"
    [ -z "$name" ] || sgdisk -c "${partnum}:${name}" "$DISK" >/dev/null || error "Failed to restore GPT name for partition $partnum"
    if { [ -n "$attrs" ] && [ "$attrs" != "0000000000000000" ]; }; then
        sgdisk -A "${partnum}:=:${attrs}" "$DISK" >/dev/null || \
            error "Failed to restore GPT attributes for partition $partnum"
    fi

    reread_partition_table_strict
    verify_gpt_strict "$DISK"
    sleep 1
}

cleanup_install_stage() {
    local path vg mounts
    [ -n "${INSTALL_TMPDIR:-}" ] || return 0
    case "$INSTALL_TMPDIR" in /run/reinstall-work/install.*) ;; *) warn "Unexpected workspace; refusing recursive cleanup"; return 1 ;; esac
    cd /
    # Release all known child mounts, including a failed NoCloud seed write.
    for path in "${LINUX_COPY_ROOT_MNT:-}" "${LINUX_COPY_SRC_MNT:-}" \
        "$INSTALL_TMPDIR/linux-src-boot" "$INSTALL_TMPDIR/linux-src-efi" \
        "$INSTALL_TMPDIR/linux-probe" "$INSTALL_TMPDIR/precheck-efi" \
        "$INSTALL_TMPDIR/precheck-btrfs-top" "$INSTALL_TMPDIR/linux-btrfs-source-top" \
        "$INSTALL_TMPDIR/linux-btrfs-target-top" "$INSTALL_TMPDIR/cidata"; do
        [ -n "$path" ] || continue
        if is_mountpoint "$path"; then
            umount -R "$path" || { warn "Cannot release $path; preserving workspace"; return 1; }
        fi
    done
    mounts=$(findmnt -krn -o TARGET) || { warn "Cannot verify mount inventory; preserving workspace"; return 1; }
    if printf '%s\n' "$mounts" | awk -v p="$INSTALL_TMPDIR" '$0 == p || index($0,p "/") == 1 {found=1} END {exit !found}'; then
        warn "Workspace still contains mounted filesystems; refusing recursive cleanup"
        return 1
    fi
    for vg in $LINUX_COPY_SOURCE_VGS; do
        vgchange -an "$vg" >/dev/null || { warn "Cannot deactivate $vg; preserving workspace"; return 1; }
    done
    LINUX_COPY_SOURCE_VGS=""
    cleanup_qcow_nbd || { warn "Cannot disconnect source image; preserving workspace"; return 1; }
    if is_mountpoint "$TEMP_STAGE_MNT"; then
        umount "$TEMP_STAGE_MNT" || { warn "Cannot release staging filesystem"; return 1; }
    fi
    rm -rf "$INSTALL_TMPDIR" || return 1
}

installer_workspace() {
    is_mountpoint /run/reinstall-work || error "Alpine work tmpfs is not mounted"
    INSTALL_TMPDIR=$(mktemp -d /run/reinstall-work/install.XXXXXX)
    trap cleanup_install_stage EXIT
}

installer_stage_optional_inputs() {
    { [ -n "${FRPC_TOML:-}" ] && match_ere "$FRPC_TOML" '^https?://'; } || return 0
    local dst="$INSTALL_TMPDIR/frpc.toml"
    { case "$FRPC_TOML" in https://*) true ;; *) false ;; esac; } || error "FRPC config URL must use HTTPS"
    info "Downloading FRPC config"
    http_download "$FRPC_TOML" "$dst" || error "Failed to download FRPC config"
    FRPC_TOML="$dst"
}

confirm_destructive_write() {
    echo
    echo "WARNING: $DISK will be repartitioned. ALL DATA WILL BE LOST."
    [ "$AUTO_YES" = 1 ] && [ -n "${DISK_ID_WWN:-}${DISK_ID_SERIAL:-}${DISK_ID_PTUUID:-}${DISK_ID_MBR_ID:-}${DISK_ID_ANCHOR_PARTUUID:-}" ] && return 0
    printf "Type yes to continue: " >&2
    IFS= read -r ans || error "Confirmation required"
    case "$ans" in y|Y|yes|YES|Yes) return ;; *) error "Cancelled" ;; esac
}

# Validate the disk-staged source. Keep the read-only
# Linux source mounted for the copy instead of rescanning it after commit.
validate_linux_source() {
    local efi_bytes boot_bytes=0 root_budget source_dir top fs cmd esp efi_candidate
    source_dir="$LINUX_COPY_SRC_MNT"
    if [ "$LINUX_COPY_ROOT_TYPE" = btrfs ]; then
        top="$INSTALL_TMPDIR/precheck-btrfs-top"
        mkdir -p "$top"
        mount -t btrfs -o ro,subvolid=5 "$LINUX_COPY_SRC_ROOT" "$top" || error "Cannot inspect Btrfs source subvolumes"
        LINUX_COPY_ROOT_USED=$(du -s -B1 --apparent-size "$top" | awk '{print $1}') || error "Cannot measure Btrfs source"
        umount "$top" || error "Cannot release Btrfs source inspection"
    else
        LINUX_COPY_ROOT_USED=$(du -sx -B1 "$source_dir" | awk '{print $1}') || error "Cannot measure source root"
    fi
    efi_bytes=$(blockdev --getsize64 "$LINUX_COPY_SRC_EFI") || error "Cannot read EFI size"
    efi_bytes=$(((efi_bytes + 1048575) / 1048576 * 1048576))
    [ "$efi_bytes" -ge $((32 * 1048576)) ] || efi_bytes=$((32 * 1048576))
    if [ -n "$LINUX_COPY_SRC_BOOT" ]; then
        boot_bytes=$(blockdev --getsize64 "$LINUX_COPY_SRC_BOOT") || error "Cannot read boot size"
        boot_bytes=$(((boot_bytes + 1048575) / 1048576 * 1048576))
        fs=$(blkid -s TYPE -o value "$LINUX_COPY_SRC_BOOT") || error "Cannot identify /boot filesystem"
        case "$fs" in ext4|xfs) ;; *) error "Unsupported /boot filesystem: $fs" ;; esac
    fi
    root_budget=$((TEMP_STAGE_START_BYTES - efi_bytes - boot_bytes - 16 * 1048576))
    match_ere "$LINUX_COPY_ROOT_USED" '^[0-9]+$' || error "Cannot measure root data"
    [ "$root_budget" -gt $((LINUX_COPY_ROOT_USED + 256 * 1048576)) ] ||
        error "Source data exceeds estimated destination root budget (data=$LINUX_COPY_ROOT_USED, budget=$root_budget)"
    for fs in "$LINUX_COPY_ROOT_TYPE" "${fs:-}"; do
        case "$fs" in xfs) cmd=mkfs.xfs ;; ext4) cmd=mkfs.ext4 ;; *) continue ;; esac
        { [ -x "$source_dir/usr/sbin/$cmd" ] || [ -x "$source_dir/sbin/$cmd" ]; } ||
            error "Source image has no matching $cmd formatter"
    done
    case "$LINUX_COPY_SRC_ROOT" in
        /dev/mapper/*|/dev/dm-*)
            { [ -x "$source_dir/usr/bin/dracut" ] || [ -x "$source_dir/usr/sbin/dracut" ] || [ -x "$source_dir/sbin/dracut" ]; } ||
                error "LVM image has no dracut to rebuild its initramfs" ;;
    esac
    esp="$INSTALL_TMPDIR/precheck-efi"
    mkdir -p "$esp"
    linux_copy_source_mount "$LINUX_COPY_SRC_EFI" "$esp" vfat
    case "$MACHINE_ARCH" in
        x86_64) efi_candidate=$(find "$esp/EFI" -type f \( -iname 'BOOTX64.EFI' -o -iname 'grubx64.efi' \) -print -quit) ;;
        aarch64) efi_candidate=$(find "$esp/EFI" -type f \( -iname 'BOOTAA64.EFI' -o -iname 'grubaa64.efi' \) -print -quit) ;;
        *) error "Unsupported EFI architecture" ;;
    esac
    [ -n "$efi_candidate" ] || error "Image lacks a matching EFI bootloader"
    umount "$esp" || error "Cannot release EFI inspection"
    info "Linux source and estimated destination capacity validated"
}

# ----------------- bounded low-memory image backends -----------------

image_is_freebsd_raw() {
    [ "$TARGET_OS" = freebsd ] || return 1
    case "$IMG_URL" in *.raw.xz) return 0 ;; *) return 1 ;; esac
}

# Disk staging is the sole installation path and is deliberately destructive.
# RAW.xz stays compressed until the final disk write. Plain QCOW2 is
# accessed in place via NBD. Compressed custom QCOW2 needs expansion space.
calculate_disk_staging_budget() {
    local payload bytes disk_bytes
    payload=$(http_content_length "$IMG_URL") || error "Cannot determine image transfer size"
    case "$payload" in ''|*[!0-9]*) error "Missing image Content-Length" ;; esac
    [ "$payload" -gt 0 ] || error "Empty image"
    if image_is_freebsd_raw; then
        bytes=$((payload + 192 * 1024 * 1024))
    else
        case "$IMG_URL" in
            *.qcow2.xz)
                # The decompressed length is not known from HTTP Content-Length.
                # Keep the existing bounded fallback for custom compressed QCOW2.
                bytes=$((3072 * 1024 * 1024)) ;;
            *) bytes=$((payload + 192 * 1024 * 1024)) ;;
        esac
    fi
    TEMP_STAGE_SIZE_MIB=$(((bytes + 1048575) / 1048576))
    [ "$TEMP_STAGE_SIZE_MIB" -ge 256 ] || TEMP_STAGE_SIZE_MIB=256
    TEMP_STAGE_SIZE_BYTES=$((TEMP_STAGE_SIZE_MIB * 1048576))
    disk_bytes=$(get_disk_size_bytes "$DISK") || error "Cannot read disk size"
    [ "$disk_bytes" -gt $((TEMP_STAGE_SIZE_BYTES + 2 * 1024 * 1024 * 1024)) ] ||
        error "Disk cannot accommodate the image staging partition"
    [ "$payload" -lt "$TEMP_STAGE_SIZE_BYTES" ] || error "Image transfer exceeds staging partition"
    info "Disk staging budget: $TEMP_STAGE_SIZE_MIB MiB (download $payload bytes)"
}

set_disk_download_limit() {
    local available
    available=$(df -B1 --output=avail "$TEMP_STAGE_MNT" | awk 'NR==2 {print $1}')
    case "$available" in ''|*[!0-9]*) error "Cannot determine staging filesystem space" ;; esac
    [ "$available" -gt $((32 * 1048576)) ] || error "Insufficient staging filesystem space"
    IMAGE_DOWNLOAD_LIMIT_BYTES=$((available - 32 * 1048576))
}

# Download the compressed RAW file once. Verify the publisher checksum before
# decompressing or writing any image bytes to the target system area.
download_freebsd_raw() {
    local dst="$1" tmp="$1.part" digest limit actual
    limit=${IMAGE_DOWNLOAD_LIMIT_BYTES:?missing image staging limit}
    rm -f "$tmp"
    curl -fL --proto '=https' --proto-redir '=https' --max-filesize "$limit" \
        "$IMG_URL" -o "$tmp" || error "Failed to download compressed FreeBSD RAW image"
    actual=$(stat -c %s "$tmp") || error "Cannot read RAW payload length"
    [ "$actual" -le "$limit" ] || error "RAW payload exceeds staging budget"
    [ -n "${IMAGE_HASH_EXPECTED:-}" ] || error "FreeBSD RAW requires an official checksum"
    digest=$(sha256sum "$tmp" | awk '{print $1}') || error "Cannot hash RAW payload"
    [ "$digest" = "$IMAGE_HASH_EXPECTED" ] || error "FreeBSD RAW checksum mismatch"
    mv -f "$tmp" "$dst"
    sync
    info "Verified compressed FreeBSD RAW image"
}

# Validate both GPT copies in a sparse metadata-only file. Only the first and
# final MiB of the RAW disk are retained; xz processes the entire stream and
# verifies its integrity. No full RAW or QCOW2 is allocated in RAM.
inspect_freebsd_raw() {
    local img="$1" layout="$INSTALL_TMPDIR/raw-gpt.layout" size tail_offset table end
    size=$(xz --robot --list "$img" | awk '$1=="totals" {print $5; exit}') ||
        error "Cannot inspect XZ index"
    case "$size" in ''|*[!0-9]*) error "Invalid RAW virtual size" ;; esac
    [ "$size" -ge 2097152 ] && [ $((size % 512)) -eq 0 ] ||
        error "Invalid RAW sector geometry"
    [ "$size" -le $((TEMP_STAGE_START_BYTES - 8 * 1048576)) ] ||
        error "RAW image would overlap protected staging; refusing write"
    rm -f "$layout"
    truncate -s "$size" "$layout" || error "Cannot allocate sparse GPT metadata"
    tail_offset=$((size / 512 - 2048))
    # The outer installer currently enables pipefail. Both dd and tail must
    # consume the same stream; fullblock prevents a short pipe read.
    if ! xz --threads=1 --memlimit-decompress=128MiB -dc "$img" | (
        dd of="$layout" bs=1048576 count=1 iflag=fullblock conv=notrunc status=none &&
        tail -c 1048576 | dd of="$layout" bs=512 seek="$tail_offset" conv=notrunc status=none
    ); then
        rm -f "$layout"
        error "FreeBSD RAW integrity/GPT metadata extraction failed"
    fi
    verify_gpt_strict "$layout"
    table=$(sgdisk -p "$layout") || error "Cannot read RAW GPT"
    QCOW_GPT_GUID=$(printf '%s\n' "$table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    [ -n "$QCOW_GPT_GUID" ] || error "RAW GPT has no disk identifier"
    end=$(printf '%s\n' "$table" | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {if($3>max)max=$3} END {if(max)printf "%.0f\n",max}')
    case "$end" in ''|*[!0-9]*) error "Cannot determine RAW partition boundaries" ;; esac
    [ $(((end + 1) * 512)) -lt "$size" ] || error "RAW partition exceeds image size"
    QCOW_PARTITION_TABLE=gpt
    RAW_IMAGE_BYTES=$size
    rm -f "$layout"
    info "Verified RAW GPT and bounded image size: $RAW_IMAGE_BYTES bytes"
}

installer_write_freebsd_raw() {
    local img="$STAGED_IMAGE" written_guid written_table
    info "Writing verified FreeBSD RAW stream (no full decompressed image)"
    xz --threads=1 --memlimit-decompress=128MiB -dc "$img" |
        dd of="$DISK" bs=1M iflag=fullblock conv=notrunc,fsync status=progress ||
        error "FreeBSD RAW disk write failed"
    release_temp_staging_partition
    written_table=$(sgdisk -p "$DISK" 2>&1) || error "Cannot read written RAW GPT"
    written_guid=$(printf '%s\n' "$written_table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    [ "$written_guid" = "$QCOW_GPT_GUID" ] || error "Written RAW GPT identity mismatch"
    case "$written_table" in *REINSTALL_TMP*) error "Temporary GPT survived RAW write" ;; esac
    sgdisk -e "$DISK" >/dev/null || error "Failed to repair RAW backup GPT"
    verify_gpt_strict "$DISK"
    grow_last_partition_reserving_cidata
}

# Calculate a conservative boundary for validation without changing a disk.
# The actual partition boundary is checked against it after commit.
planned_stage_boundary() {
    local disk_bytes
    disk_bytes=$(get_disk_size_bytes "$DISK") || error "Cannot read target disk size"
    TEMP_STAGE_START_BYTES=$((disk_bytes - TEMP_STAGE_SIZE_BYTES - 4 * 1048576))
    [ "$TEMP_STAGE_START_BYTES" -gt $((2 * 1024 * 1048576)) ] || error "Insufficient destination space"
}

stage_source_image() {
    local dir="$1"
    if image_is_freebsd_raw; then
        STAGED_IMAGE="$dir/image.raw.xz"
        download_freebsd_raw "$STAGED_IMAGE"
    else
        STAGED_IMAGE="$dir/image.qcow2"
        download_target_image_in_alpine "$STAGED_IMAGE"
    fi
}

validate_staged_source() {
    if image_is_freebsd_raw; then
        inspect_freebsd_raw "$STAGED_IMAGE"
    elif [ "$TARGET_OS" = freebsd ]; then
        inspect_qcow_partition_layout "$STAGED_IMAGE"
        [ "$QCOW_PARTITION_TABLE" = gpt ] || error "FreeBSD installation requires GPT"
        [ "$QCOW_PARTITION_CROSSES_STAGE" = 0 ] || error "FreeBSD source overlaps staging"
    else
        connect_qcow_readonly_nbd "$STAGED_IMAGE"
        linux_copy_scan_source
        validate_linux_source
    fi
}

commit_disk_and_prepare_source() {
    local planned
    if [ "$TARGET_OS" != freebsd ]; then TEMP_STAGE_PART_NUM=128; fi
    resolve_target_disk_from_identity
    validate_target_disk "$DISK"
    ensure_supported_sector_size
    validate_target_capacity
    planned_stage_boundary
    planned="$TEMP_STAGE_START_BYTES"
    confirm_destructive_write
    assert_target_disk_idle "$DISK"
    prepare_fixed_temp_staging_partition
    [ "$TEMP_STAGE_START_BYTES" -ge "$planned" ] || error "Actual staging boundary is smaller than validated plan"
    set_disk_download_limit
    stage_source_image "$TEMP_STAGE_MNT"
    validate_staged_source
}

installer_write_image() {
    IMG_QCOW="$STAGED_IMAGE"

    write_qcow_without_overwriting_staging "$IMG_QCOW"

    [ "${TEMP_STAGE_RELEASED:-0}" = 1 ] || release_temp_staging_partition
    sync
    if [ "$QCOW_PARTITION_TABLE" = dos ]; then
        local written_id
        local disk_sectors
        disk_sectors=$(blockdev --getsz "$DISK")
        [ "$(( disk_sectors > 2048 ))" -ne 0 ] || error "Invalid target sector count"
        dd if=/dev/zero of="$DISK" bs=512 seek=$((disk_sectors - 2048)) count=2048             conv=notrunc,fsync status=none || error "Failed to clear obsolete backup GPT at disk tail"
        written_id=$(sfdisk --disk-id "$DISK" 2>/dev/null || true)
        [ "$(to_lower "$written_id")" = "$(to_lower "$QCOW_MBR_ID")" ] || error "Written MBR signature differs from source image"
        [ "$(blkid -p -s PTTYPE -o value "$DISK" 2>/dev/null || true)" = dos ] ||             error "Written target does not expose the expected MBR"
        sfdisk --verify "$DISK" >/dev/null || error "Written MBR partition layout is inconsistent"
        return 0
    fi
    local written_table written_guid
    written_table=$(sgdisk -p "$DISK" 2>&1) || error "Target GPT unreadable after image write: $written_table"
    written_guid=$(printf '%s\n' "$written_table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    [ "$(to_lower "$written_guid")" = "$(to_lower "$QCOW_GPT_GUID")" ] || \
        error "Target GPT identity differs from verified image; refusing backup GPT repair"
    { case "$written_table" in *REINSTALL_TMP*) false ;; *) true ;; esac; } || error "Staging GPT survived image write; refusing GPT repair"
    sgdisk -e "$DISK" >/dev/null || error "Failed to repair target GPT"
    verify_gpt_strict "$DISK"
    grow_last_partition_reserving_cidata
}

# Linux cloud images are installed by copying files, not by shrinking an XFS image.
# FreeBSD retains its original block-level QCOW2 installation path.
LINUX_COPY_SRC_ROOT=""
LINUX_COPY_SRC_BOOT=""
LINUX_COPY_SRC_EFI=""
LINUX_COPY_ROOT_TYPE=""
LINUX_COPY_ROOT_UUID=""
LINUX_COPY_BOOT_UUID=""
LINUX_COPY_EFI_UUID=""
LINUX_COPY_ROOT_TARGET=""
LINUX_COPY_ROOT_MNT=""
LINUX_COPY_SRC_MNT=""
LINUX_COPY_EFI_PARTNUM=""
LINUX_COPY_BOOT_PARTNUM=""
LINUX_COPY_ROOT_PARTNUM=""
LINUX_COPY_SOURCE_VGS=""
LINUX_COPY_BTRFS_MOUNTS=""

linux_copy_source_mount() {
    local dev="$1" dir="$2" fs="$3"
    mkdir -p "$dir"
    case "$fs" in
        xfs) mount -t xfs -o ro,nouuid,norecovery "$dev" "$dir" ;;
        ext4|ext3|ext2) mount -t "$fs" -o ro,noload "$dev" "$dir" ;;
        vfat) mount -t vfat -o ro "$dev" "$dir" ;;
        btrfs)
            # Fedora Cloud uses a root subvolume rather than the Btrfs top level.
            mount -t btrfs -o ro,subvol=root "$dev" "$dir" 2>/dev/null ||
                mount -t btrfs -o ro "$dev" "$dir" ;;

        *) error "Unsupported Linux source filesystem for file-copy installation: $fs ($dev)" ;;
    esac || error "Failed to mount source filesystem read-only: $dev"
}

verify_gpt_strict() {
    local device="$1" verification
    verification=$(LC_ALL=C sgdisk -v "$device" 2>&1) || {
        printf '%s\n' "$verification" >&2
        error "GPT verification command failed on $device"
    }
    # gdisk/s gdisk may return status 0 even when -v identified CRC problems.
    # Only an explicit clean report is accepted; unknown output fails closed.
    if ! printf '%s\n' "$verification" | grep -Eq '^[[:space:]]*No problems found\.'; then
        printf '%s\n' "$verification" >&2
        error "GPT integrity validation failed on $device"
    fi
}

linux_copy_scan_source() {
    # Scan the staged source once; the validated mount is reused for copying.
    LINUX_COPY_SRC_ROOT= LINUX_COPY_SRC_BOOT= LINUX_COPY_SRC_EFI=
    LINUX_COPY_ROOT_TYPE= LINUX_COPY_ROOT_UUID= LINUX_COPY_BOOT_UUID= LINUX_COPY_EFI_UUID=
    local nbd="$QCOW_NBD_DEV" table pv vg dev fs type mp path count=0
    table=$(blkid -p -s PTTYPE -o value "$nbd" 2>/dev/null || true)
    [ "$table" = gpt ] || error "Linux file-copy installer currently requires a GPT cloud image (detected: ${table:-unknown})"
    verify_gpt_strict "$nbd"
    [ "$(blockdev --getss "$nbd")" = "$(blockdev --getss "$DISK")" ] || error "Source/target sector size mismatch"

    # Activate only the image's volume groups, if any. Alpine rescue has no VG of its own.
    while read -r dev fs; do
        [ "$fs" = LVM2_member ] || continue
        vg=$(pvs --readonly --noheadings -o vg_name "$dev" 2>/dev/null | awk 'NF {print $1; exit}')
        [ -n "$vg" ] || error "Could not determine source LVM volume group on $dev"
        # vgchange by name is unsafe when a visible host PV or clone shares
        # that VG name. Do not activate any ambiguous group from the image.
        local other_pv other_vg source_nodes pv_inventory
        source_nodes=$(lsblk -pnr -o NAME "$nbd" 2>/dev/null) || error "Cannot list image LVM source devices"
        pv_inventory=$(pvs --readonly --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null) || \
            error "Cannot enumerate LVM physical volumes before activating $vg"
        while IFS='|' read -r other_pv other_vg; do
            other_pv="$(printf '%s' "$other_pv" | tr -d '[:space:]')"
            other_vg="$(printf '%s' "$other_vg" | tr -d '[:space:]')"
            [ "$other_vg" = "$vg" ] || continue
            if ! printf '%s\n' "$source_nodes" | grep -Fxq -- "$other_pv"; then
                error "Volume group $vg also contains or collides with non-image PV $other_pv; refusing activation"
            fi
        done <<DDIFY_INPUT_21
$pv_inventory
DDIFY_INPUT_21
        if ! { case " $LINUX_COPY_SOURCE_VGS " in *" $vg "*) true ;; *) false ;; esac; }; then
            vgchange -ay "$vg" >/dev/null || error "Cannot activate source LVM group: $vg"
            LINUX_COPY_SOURCE_VGS="${LINUX_COPY_SOURCE_VGS:+$LINUX_COPY_SOURCE_VGS }$vg"
        fi
    done <<DDIFY_INPUT_14
$(lsblk -pnr -o NAME,FSTYPE "$nbd")
DDIFY_INPUT_14
    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true

    LINUX_COPY_SRC_MNT="$INSTALL_TMPDIR/linux-source"
    local probe="$INSTALL_TMPDIR/linux-probe"
    mkdir -p "$LINUX_COPY_SRC_MNT" "$probe"
    # lsblk includes active LVM logical volumes after vgchange -ay.
    while read -r dev fs type; do
        case "$fs" in xfs|ext4|ext3|ext2|vfat|btrfs) ;; *) continue ;; esac
        [ "$type" != disk ] || continue
        linux_copy_source_mount "$dev" "$probe" "$fs"
        if [ -f "$probe/etc/os-release" ]; then
            count=$((count + 1)); [ "$count" -eq 1 ] || error "Ambiguous Linux source root filesystems"
            LINUX_COPY_SRC_ROOT="$dev"
            LINUX_COPY_ROOT_TYPE="$fs"
        elif { [ "$fs" = vfat ] && [ -d "$probe/EFI" ]; }; then
            [ -z "$LINUX_COPY_SRC_EFI" ] || error "Ambiguous source EFI partitions"
            LINUX_COPY_SRC_EFI="$dev"
        elif { [ "$fs" != vfat ] && [ -n "$(find "$probe" -maxdepth 1 -name 'vmlinuz*' -print -quit 2>/dev/null)" ]; }; then
            [ -z "$LINUX_COPY_SRC_BOOT" ] || error "Ambiguous source /boot partitions"
            LINUX_COPY_SRC_BOOT="$dev"
        elif { [ -d "$probe/grub2" ] || [ -d "$probe/grub" ] || [ -d "$probe/loader/entries" ]; }; then
            [ -z "$LINUX_COPY_SRC_BOOT" ] || error "Ambiguous source /boot partitions"
            LINUX_COPY_SRC_BOOT="$dev"
        else
            # A second unknown Linux filesystem may be /var or /home; do not silently lose it.
            if [ "$fs" != vfat ]; then
                umount "$probe" || true
                error "Unrecognized additional source filesystem $dev ($fs); refusing incomplete file copy"
            fi
        fi
        umount "$probe" || error "Cannot unmount source probe $dev"
    done <<DDIFY_INPUT_15
$(lsblk -pnr -o NAME,FSTYPE,TYPE "$nbd")
DDIFY_INPUT_15
    [ "$(( count == 1 ))" -ne 0 ] || error "Exactly one Linux root filesystem is required (found $count)"
    { [ "$LINUX_COPY_ROOT_TYPE" = xfs ] || [ "$LINUX_COPY_ROOT_TYPE" = ext4 ] || [ "$LINUX_COPY_ROOT_TYPE" = btrfs ]; } || error "Unsupported Linux root filesystem"
    { [ -z "$LINUX_COPY_SRC_BOOT" ] || [ "$LINUX_COPY_SRC_BOOT" != "$LINUX_COPY_SRC_ROOT" ]; } || error "Invalid source /boot"
    { [ -z "$LINUX_COPY_SRC_EFI" ] || [ "$LINUX_COPY_SRC_EFI" != "$LINUX_COPY_SRC_ROOT" ]; } || error "Invalid source EFI"
    if [ -d /sys/firmware/efi ]; then
        [ -n "$LINUX_COPY_SRC_EFI" ] || error "UEFI host requires a source EFI system partition"
    else
        error "Linux file-copy installation on legacy BIOS is not yet implemented; refusing to produce an unbootable system"
    fi

    linux_copy_source_mount "$LINUX_COPY_SRC_ROOT" "$LINUX_COPY_SRC_MNT" "$LINUX_COPY_ROOT_TYPE"
    LINUX_COPY_ROOT_UUID=$(blkid -s UUID -o value "$LINUX_COPY_SRC_ROOT" 2>/dev/null || true)
    [ -n "$LINUX_COPY_ROOT_UUID" ] || error "Source root filesystem has no UUID"
    if [ -n "$LINUX_COPY_SRC_BOOT" ]; then
        LINUX_COPY_BOOT_UUID=$(blkid -s UUID -o value "$LINUX_COPY_SRC_BOOT" 2>/dev/null || true)
        [ -n "$LINUX_COPY_BOOT_UUID" ] || error "Source /boot filesystem has no UUID"
    fi
    if [ -n "$LINUX_COPY_SRC_EFI" ]; then
        LINUX_COPY_EFI_UUID=$(blkid -s UUID -o value "$LINUX_COPY_SRC_EFI" 2>/dev/null || true)
        match_ere "$LINUX_COPY_EFI_UUID" '^[[:xdigit:]]{4}-[[:xdigit:]]{4}$' || error "Invalid source EFI FAT UUID"
    fi
    info "File-copy source: root=$LINUX_COPY_SRC_ROOT ($LINUX_COPY_ROOT_TYPE); boot=${LINUX_COPY_SRC_BOOT:-in-root}; EFI=${LINUX_COPY_SRC_EFI:-none}"
}

linux_copy_preserve_partuuid() {
    local src="$1" num="$2" uuid
    { [ -n "$src" ] && { case "$src" in "$QCOW_NBD_DEV"p*) true ;; *) false ;; esac; }; } || return 0
    uuid=$(blkid -s PARTUUID -o value "$src" 2>/dev/null || true)
    [ -z "$uuid" ] || sgdisk -u "$num:$uuid" "$DISK" >/dev/null || error "Cannot retain PARTUUID for partition $num"
}

linux_copy_create_partitions() {
    local n=1 efi_mb boot_mb efi_dev boot_dev root_dev src_size stage_boundary
    # Staging is partition 128, leaving standard partition numbers free for Linux.
    [ "$TEMP_STAGE_PART_NUM" = 128 ] || error "Linux file-copy requires staging partition 128"
    [ -n "$LINUX_COPY_SRC_EFI" ] || error "No EFI system partition"
    src_size=$(blockdev --getsize64 "$LINUX_COPY_SRC_EFI")
    efi_mb=$(((src_size + 1024 * 1024 - 1) / (1024 * 1024)))
    [ "$(( efi_mb >= 32 ))" -ne 0 ] || efi_mb=32
    LINUX_COPY_EFI_PARTNUM="$n"
    sgdisk -n "$n:0:+${efi_mb}M" -t "$n:EF00" -c "$n:EFI System" "$DISK" >/dev/null || error "Cannot create Linux EFI partition"
    linux_copy_preserve_partuuid "$LINUX_COPY_SRC_EFI" "$n"
    n=$((n + 1))

    if [ -n "$LINUX_COPY_SRC_BOOT" ]; then
        src_size=$(blockdev --getsize64 "$LINUX_COPY_SRC_BOOT")
        boot_mb=$(((src_size + 1024 * 1024 - 1) / (1024 * 1024)))
        LINUX_COPY_BOOT_PARTNUM="$n"
        sgdisk -n "$n:0:+${boot_mb}M" -t "$n:8300" -c "$n:Linux boot" "$DISK" >/dev/null || error "Cannot create Linux /boot partition"
        linux_copy_preserve_partuuid "$LINUX_COPY_SRC_BOOT" "$n"
        n=$((n + 1))
    fi

    LINUX_COPY_ROOT_PARTNUM="$n"
    stage_boundary=$((TEMP_STAGE_START_SECTOR - 16384))
    sgdisk -n "$n:0:$stage_boundary" -t "$n:8300" -c "$n:Linux root" "$DISK" >/dev/null || error "Target disk lacks space for Linux root alongside staging"
    linux_copy_preserve_partuuid "$LINUX_COPY_SRC_ROOT" "$n"
    verify_gpt_strict "$DISK"
    reread_partition_table_strict
    efi_dev=$(partition_device_for_number "$DISK" "$LINUX_COPY_EFI_PARTNUM")
    root_dev=$(partition_device_for_number "$DISK" "$LINUX_COPY_ROOT_PARTNUM")
    ensure_linux_block_node_from_sysfs "$efi_dev" || [ -b "$efi_dev" ] || error "Missing Linux EFI block device"
    ensure_linux_block_node_from_sysfs "$root_dev" || [ -b "$root_dev" ] || error "Missing Linux root block device"
    LINUX_COPY_ROOT_TARGET="$root_dev"
    if [ -n "$LINUX_COPY_BOOT_PARTNUM" ]; then
        boot_dev=$(partition_device_for_number "$DISK" "$LINUX_COPY_BOOT_PARTNUM")
        ensure_linux_block_node_from_sysfs "$boot_dev" || [ -b "$boot_dev" ] || error "Missing Linux /boot block device"
    fi
    info "Copy target: root=$root_dev, boot=${boot_dev:-in-root}, EFI=$efi_dev, staging=$TEMP_STAGE_PART"
}

linux_copy_format_ext4_or_xfs() {
    local dev="$1" src="$2" fs uuid label tool toolpath=""
    fs=$(blkid -s TYPE -o value "$src" 2>/dev/null || true)
    uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
    label=$(blkid -s LABEL -o value "$src" 2>/dev/null || true)
    [ -n "$uuid" ] || error "Source filesystem UUID missing: $src"
    case "$fs" in
        ext4)
            tool=mkfs.ext4
            set -- -F -m 0 -U "$uuid"
            [ -z "$label" ] || set -- "$@" -L "$label"
            ;;
        xfs)
            tool=mkfs.xfs
            set -- -f -m "uuid=$uuid"
            [ -z "$label" ] || set -- "$@" -L "$label"
            ;;
        *) error "Unsupported Linux filesystem to recreate: $fs ($src)" ;;
    esac
    # Run the matching distro's formatter: Alpine's newer filesystem features
    # are not necessarily understood by the destination image's GRUB.
    for toolpath in "/usr/sbin/$tool" "/sbin/$tool"; do
        ! [ -x "$LINUX_COPY_SRC_MNT$toolpath" ] || break
    done
    [ -x "$LINUX_COPY_SRC_MNT$toolpath" ] || error "Source Linux image has no $tool formatter"
    mount --bind /dev "$LINUX_COPY_SRC_MNT/dev" || error "Cannot bind /dev for source formatter"
    mount -t proc proc "$LINUX_COPY_SRC_MNT/proc" || error "Cannot mount /proc for source formatter"
    if ! chroot "$LINUX_COPY_SRC_MNT" "$toolpath" "$@" "$dev" >/dev/null; then
        umount "$LINUX_COPY_SRC_MNT/proc" || true
        umount "$LINUX_COPY_SRC_MNT/dev" || true
        error "Source Linux $tool failed while formatting $dev"
    fi
    umount "$LINUX_COPY_SRC_MNT/proc" || error "Cannot unmount source formatter procfs"
    umount "$LINUX_COPY_SRC_MNT/dev" || error "Cannot unmount source formatter devfs"
}

linux_copy_mount_target() {
    local dev="$1" where="$2" fs="$3"
    mkdir -p "$where"
    if [ "$fs" = xfs ]; then
        mount -t xfs -o nouuid "$dev" "$where" || error "Cannot mount target XFS: $dev"
    else
        mount "$dev" "$where" || error "Cannot mount target filesystem: $dev"
    fi
}

# Rewrite literal kernel arguments, not GRUB variables such as root=$root.
# GNU sed is installed in the Alpine rescue environment; use the same filter
# for text configurations and the unpadded portion of GRUB environment blocks.
linux_copy_filter_cmdline() {
    local uuid="$1" is_lvm="$2"
    if [ "$is_lvm" = 1 ]; then
        sed -E \
            -e "s/(^|[^[:alnum:]_])resume=[^[:space:]\"']+[[:blank:]]*/\\1/g" \
            -e "s/(^|[^[:alnum:]_])root=[^\$[:space:]\"'][^[:space:]\"']*/\\1root=UUID=$uuid/g" \
            -e "s/(^|[[:space:]])rd\\.lvm\\.(lv|vg|uuid)=[^[:space:]\"']+[[:blank:]]*/\\1/g"
    else
        sed -E \
            -e "s/(^|[^[:alnum:]_])resume=[^[:space:]\"']+[[:blank:]]*/\\1/g" \
            -e "s/(^|[^[:alnum:]_])root=[^\$[:space:]\"'][^[:space:]\"']*/\\1root=UUID=$uuid/g"
    fi
}

linux_copy_repair_boot_configs() {
    local root="$LINUX_COPY_ROOT_MNT" uuid="$LINUX_COPY_ROOT_UUID" boot_uuid="$LINUX_COPY_BOOT_UUID"
    local efi_uuid="$LINUX_COPY_EFI_UUID" is_lvm=0 path size pad tmp fstab
    match_ere "$uuid" '^[[:xdigit:]-]+$' || error "Invalid root filesystem UUID"
    case "$LINUX_COPY_SRC_ROOT" in /dev/mapper/*|/dev/dm-*) is_lvm=1 ;; esac
    tmp="$INSTALL_TMPDIR/linux-boot-repair.tmp"
    fstab="$root/etc/fstab"
    mkdir -p "$root/etc"
    [ ! -L "$fstab" ] || error "Refusing to rewrite a symlinked fstab"
    [ -e "$fstab" ] || : >"$fstab"
    [ -f "$fstab" ] || error "Target fstab is not a regular file"
    awk -v uuid="$uuid" -v boot="$boot_uuid" -v efi="$efi_uuid" -v lvm="$is_lvm" '
        BEGIN { OFS="\t" }
        /^[[:space:]]*#/ || NF<3 { print; next }
        $3=="swap" { print "# DDify: source swap partition was not copied: " $0; next }
        $2=="/" { $1="UUID=" uuid; root_seen=1; print; next }
        $2=="/boot" { boot_seen=1; if(boot!="") $1="UUID=" boot; print; next }
        $2=="/boot/efi" { efi_seen=1; if(efi!="") $1="UUID=" efi; print; next }
        lvm==1 && $1 ~ /\/dev\/(mapper\/|[^/]+\/)/ {
            print "Unsupported additional LVM mount: " $0 > "/dev/stderr"
            bad=1; exit 1
        }
        { print }
        END {
            if(bad) exit 1
            if(!root_seen) print "UUID=" uuid, "/", "auto", "defaults", 0, 1
            if(boot!="" && !boot_seen) print "UUID=" boot, "/boot", "auto", "defaults", 0, 2
            if(efi!="" && !efi_seen) print "UUID=" efi, "/boot/efi", "vfat", "defaults", 0, 2
        }
    ' "$fstab" >"$tmp" || error "Failed to repair target fstab"
    cat "$tmp" >"$fstab" || error "Cannot write target fstab"

    for path in "$root/etc/default/grub" "$root/etc/default/grub.d/"*.cfg \
        "$root/etc/kernel/cmdline" "$root/boot/grub2/grub.cfg" "$root/boot/grub/grub.cfg" \
        "$root/boot/loader/entries/"*.conf "$root/boot/efi/loader/entries/"*.conf \
        "$root/boot/efi/EFI/"*/*.cfg; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        linux_copy_filter_cmdline "$uuid" "$is_lvm" <"$path" >"$tmp" || error "Cannot repair $path"
        if ! cmp -s "$path" "$tmp"; then
            cat "$tmp" >"$path" || error "Cannot update $path"
        fi
    done

    # GRUB uses an exact 1024-byte block padded with '#' bytes. Strip only
    # trailing padding, rewrite kernel arguments, and restore the byte length.
    for path in "$root/boot/grub2/grubenv" "$root/boot/grub/grubenv" "$root/boot/efi/EFI/"*/grubenv; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        size=$(wc -c <"$path")
        if [ "$size" -ne 1024 ] || [ "$(head -n 1 "$path")" != '# GRUB Environment Block' ]; then
            if grep -Eq 'rd\.lvm\.|root=/dev/mapper/' "$path"; then
                error "Cannot safely repair unknown GRUB environment format: $path"
            fi
            continue
        fi
        sed -z 's/#*$//' "$path" | linux_copy_filter_cmdline "$uuid" "$is_lvm" >"$tmp" ||
            error "Cannot repair GRUB environment: $path"
        size=$(wc -c <"$tmp")
        [ "$size" -le 1024 ] || error "Updated GRUB environment exceeds 1024 bytes"
        pad=$((1024 - size))
        head -c "$pad" /dev/zero | tr '\000' '#' >>"$tmp" ||
            error "Cannot restore GRUB environment padding"
        [ "$(wc -c <"$tmp")" -eq 1024 ] || error "Invalid GRUB environment block size"
        if ! cmp -s "$path" "$tmp"; then
            cat "$tmp" >"$path" || error "Cannot update GRUB environment"
        fi
    done
    rm -f "$tmp"
}

linux_copy_regenerate_lvm_initramfs() {
    { { case "$LINUX_COPY_SRC_ROOT" in /dev/mapper/*) true ;; *) false ;; esac; } || { case "$LINUX_COPY_SRC_ROOT" in /dev/dm-*) true ;; *) false ;; esac; }; } || return 0
    local root="$LINUX_COPY_ROOT_MNT"
    { [ -x "$root/usr/bin/dracut" ] || [ -x "$root/usr/sbin/dracut" ] || [ -x "$root/sbin/dracut" ]; } || \
        error "LVM-to-partition conversion requires dracut inside the Linux cloud image"
    info "Regenerating initramfs after removing source LVM root dependency"
    mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/run"
    mount --rbind /dev "$root/dev" || error "Could not bind /dev into target chroot"
    mount --make-rslave "$root/dev" || true
    mount -t proc proc "$root/proc" || error "Could not mount target /proc"
    mount --rbind /sys "$root/sys" || error "Could not bind /sys into target chroot"
    mount --make-rslave "$root/sys" || true
    if ! chroot "$root" /bin/sh -c 'dracut --force --regenerate-all --no-hostonly'; then
        umount -R "$root/sys" 2>/dev/null || true
        umount "$root/proc" 2>/dev/null || true
        umount -R "$root/dev" 2>/dev/null || true
        error "dracut failed to regenerate an initramfs that can boot from a plain root partition"
    fi
    umount -R "$root/sys" || error "Could not unmount chroot sysfs"
    umount "$root/proc" || error "Could not unmount chroot procfs"
    umount -R "$root/dev" || error "Could not unmount chroot devfs"
}

linux_copy_ensure_efi_fallback() {
    local esp="$LINUX_COPY_ROOT_MNT/boot/efi" bootfile candidate loader
    case "$MACHINE_ARCH" in
        aarch64) bootfile=BOOTAA64.EFI; loader=grubaa64.efi ;;
        x86_64) bootfile=BOOTX64.EFI; loader=grubx64.efi ;;
        *) error "Unsupported UEFI architecture for Linux file-copy: $MACHINE_ARCH" ;;
    esac
    [ -f "$esp/EFI/BOOT/$bootfile" ] && return 0
    candidate=$(find "$esp/EFI" -type f \( -iname "$loader" -o -iname "$bootfile" \) -print -quit 2>/dev/null)
    [ -n "$candidate" ] || error "Source cloud image has no UEFI fallback loader or reusable GRUB EFI binary"
    mkdir -p "$esp/EFI/BOOT"
    cp -p "$candidate" "$esp/EFI/BOOT/$bootfile" || error "Could not install UEFI fallback path"
    warn "Added UEFI fallback $bootfile from $(basename "$candidate")"
}


# rsync's progress2 emits a carriage-return update for nearly every small
# file. On a serial console that floods both the UART and RAM-backed log.
# Keep transfer options intact, report bounded periodic resource/IO samples,
# and fail on prolonged rsync protocol inactivity instead of waiting forever.
linux_copy_rsync() (
    label="$1"
    shift
    rsync --timeout=300 --info=stats2 "$@" &
    copy_pid=$!
    reporter_pid=
    cleanup_copy_reporter() {
        if [ -n "$reporter_pid" ]; then
            kill "$reporter_pid" 2>/dev/null || true
            wait "$reporter_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_copy_reporter 0
    trap 'kill "$copy_pid" 2>/dev/null || true; exit 130' INT
    trap 'kill "$copy_pid" 2>/dev/null || true; exit 143' TERM
    (
        while kill -0 "$copy_pid" 2>/dev/null; do
            mem=$(awk '/^(MemAvailable|SwapFree|Dirty|Writeback):/ {printf "%s%sKiB ",$1,$2}' /proc/meminfo)
            proc=$(awk '/^(State|VmRSS|VmSwap):/ {printf "%s%s ",$1,$2}' "/proc/$copy_pid/status" 2>/dev/null || true)
            io=$(awk -v disk="${DISK##*/}" '
                $3==disk {printf "disk_read_sectors=%s disk_written_sectors=%s pending_io=%s",$6,$10,$12}
            ' /proc/diskstats)
            printf '[copy] %s: %s%s%s\n' "$label" "$mem" "$proc" "$io"
            sleep 15
        done
    ) &
    reporter_pid=$!
    if wait "$copy_pid"; then
        rc=0
    else
        rc=$?
    fi
    cleanup_copy_reporter
    reporter_pid=
    if [ "$rc" -ne 0 ]; then
        warn "rsync failed for $label (rc=$rc); recent kernel messages follow"
        dmesg | tail -n 40 >&2 || true
        exit "$rc"
    fi
    info "Copy complete: $label"
)

linux_copy_btrfs_subvolumes() {
    local dest_root="$1" source_top="$INSTALL_TMPDIR/linux-btrfs-source-top" \
        dest_top="$INSTALL_TMPDIR/linux-btrfs-target-top" subvol path mp opts root_subvol="" line id default_subvol=""
    local subvols
    mkdir -p "$source_top" "$dest_top"
    mount -t btrfs -o ro,subvolid=5 "$LINUX_COPY_SRC_ROOT" "$source_top" || error "Cannot mount source Btrfs top-level"
    mount -t btrfs -o subvolid=5 "$LINUX_COPY_ROOT_TARGET" "$dest_top" || error "Cannot mount target Btrfs top-level"
    subvols=$(btrfs subvolume list "$source_top" | sed -n 's/^.* path //p' | LC_ALL=C sort) || error "Cannot list Btrfs subvolumes"
    [ -n "$subvols" ] || error "Btrfs source has no subvolumes; unsupported cloud image layout"
    # Validate each complete line before using a space-delimited list.
    while IFS= read -r path; do
        match_ere "$path" '^[a-zA-Z0-9_@.+/-]+$' || error "Unsupported Btrfs path: $path"
    done <<DDIFY_SUBVOLS
$subvols
DDIFY_SUBVOLS
    for path in $subvols; do
        { match_ere "$path" '^[a-zA-Z0-9_@.+/-]+$' && { case "$path" in /*) false ;; *) true ;; esac; } && { case "$path" in *../*) false ;; *) true ;; esac; } && [ "$path" != .. ]; } || error "Invalid source Btrfs subvolume path: $path"
        mkdir -p "$(dirname "$dest_top/$path")"
        btrfs subvolume create "$dest_top/$path" >/dev/null || error "Cannot create target Btrfs subvolume: $path"
    done
    for path in $subvols; do
        info "Copying Btrfs subvolume: $path"
        linux_copy_rsync "Btrfs $path" -aHAXS --numeric-ids --one-file-system \
            "$source_top/$path/" "$dest_top/$path/" || error "Could not copy Btrfs subvolume: $path"
    done
    info "All Btrfs subvolumes copied; restoring default subvolume and mount layout"
    default_subvol=$(btrfs subvolume get-default "$source_top" | sed -n 's/^.* path //p' | head -n1)
    if { [ -n "$default_subvol" ] && [ "$default_subvol" != '<FS_TREE>' ]; }; then
        id=$(btrfs subvolume list "$dest_top" | awk -v name="$default_subvol" '$0 ~ " path " name "$" {print $2; exit}')
        match_ere "$id" '^[0-9]+$' || error "Cannot map Btrfs default subvolume: $default_subvol"
        btrfs subvolume set-default "$id" "$dest_top" || error "Cannot set target Btrfs default subvolume"
    fi
    # Root and auxiliary mountpoints are specified by the source's fstab.
    local fstab="$LINUX_COPY_SRC_MNT/etc/fstab" rootopts=""
    if [ -f "$fstab" ]; then
        rootopts=$(awk '$1 !~ /^#/ && $2 == "/" && $3 == "btrfs" {print $4; exit}' "$fstab")
    fi
    for opts in $(printf '%s' "$rootopts" | tr ',' ' '); do
        case "$opts" in subvol=*) root_subvol="${opts#subvol=}" ;; esac
    done
    [ -n "$root_subvol" ] || root_subvol=root
    root_subvol="${root_subvol#/}"
    { match_ere "$root_subvol" '^[a-zA-Z0-9_@.+/-]+$' && { case "$root_subvol" in *../*) false ;; *) true ;; esac; } && [ "$root_subvol" != .. ]; } || \
        error "Invalid root Btrfs subvolume: $root_subvol"
    btrfs subvolume show "$dest_top/$root_subvol" >/dev/null 2>&1 || \
        error "Root Btrfs subvolume missing after copy: $root_subvol"
    umount "$dest_top" || error "Cannot unmount target Btrfs top-level"
    umount "$source_top" || error "Cannot unmount source Btrfs top-level"
    mkdir -p "$dest_root"
    mount -t btrfs -o "subvol=$root_subvol" "$LINUX_COPY_ROOT_TARGET" "$dest_root" || error "Cannot mount destination Btrfs root subvolume"

    while read -r subvol mp; do
        { [ -n "$subvol" ] && [ -n "$mp" ]; } || continue
        case "$mp" in /boot|/home|/var|/var/log) ;; *) error "Unsupported Btrfs subvolume mountpoint: $mp" ;; esac
        subvol="${subvol#/}"
        { match_ere "$subvol" '^[a-zA-Z0-9_@.+/-]+$' && { case "$subvol" in *../*) false ;; *) true ;; esac; }; } || error "Invalid subvolume in fstab: $subvol"
        mkdir -p "$dest_root$mp"
        mount -t btrfs -o "subvol=$subvol" "$LINUX_COPY_ROOT_TARGET" "$dest_root$mp" || error "Cannot mount target Btrfs subvolume $mp"
        LINUX_COPY_BTRFS_MOUNTS="$dest_root$mp${LINUX_COPY_BTRFS_MOUNTS:+ $LINUX_COPY_BTRFS_MOUNTS}"
    done <<DDIFY_INPUT_16
$(awk '$1 !~ /^#/ && $3 == "btrfs" && $2 != "/" {split($4,a,","); for(i in a) if(a[i] ~ /^subvol=/) {sub(/^subvol=/,"",a[i]); print a[i], $2}}' "$fstab" | LC_ALL=C sort -k2,2)
DDIFY_INPUT_16
}

# Set the static hostname while the copied root is writable. This avoids
# cloud-init local-stage hostnamectl calls before D-Bus starts. Keep the
# existing inode and its SELinux attributes when the file already exists.
linux_copy_set_hostname() {
    local root="$1" os="$2" name file
    name=$(seed_hostname "$os") || error "Invalid Linux target hostname"
    file="$root/etc/hostname"
    [ ! -L "$file" ] || error "Refusing to rewrite a symlinked target hostname"
    if [ -e "$file" ]; then
        [ -f "$file" ] || error "Target hostname is not a regular file"
    fi
    (umask 022; printf '%s\n' "$name" >"$file") || error "Cannot write target hostname"
    chmod 0644 "$file" || error "Cannot set target hostname permissions"
    [ "$(cat "$file")" = "$name" ] || error "Target hostname verification failed"

    # cloud-init 25.3 calls _maybe_set_hostname in init-local and init-net
    # BEFORE consuming user-data. Set the option in the image's base config,
    # retaining its inode and SELinux attributes; user-data alone is too late.
    local cfg="$root/etc/cloud/cloud.cfg" tmp
    [ -f "$cfg" ] && [ ! -L "$cfg" ] || error "Missing or symlinked target cloud.cfg"
    tmp=$(mktemp "$INSTALL_TMPDIR/hostname-config.XXXXXX") || error "Cannot allocate cloud.cfg buffer"
    if ! awk '
        /^preserve_hostname[[:space:]]*:/ {
            if (!seen++) print "preserve_hostname: true"
            next
        }
        /^[.][.][.][[:space:]]*$/ {
            if (!seen++) print "preserve_hostname: true"
        }
        {print}
        END {if (!seen) print "preserve_hostname: true"}
    ' "$cfg" >"$tmp"; then
        rm -f "$tmp"
        error "Cannot prepare early cloud-init hostname configuration"
    fi
    cat "$tmp" >"$cfg" || error "Cannot write target cloud.cfg"
    rm -f "$tmp"
    grep -Fxq 'preserve_hostname: true' "$cfg" || error "Early cloud-init hostname configuration not written"
    info "Prepared static hostname and early cloud-init configuration: $name"
}

linux_copy_recreate_and_copy() {
    local root="$INSTALL_TMPDIR/linux-target" src_boot_mnt="$INSTALL_TMPDIR/linux-src-boot" \
        src_efi_mnt="$INSTALL_TMPDIR/linux-src-efi" boot_dev= efi_dev src_boot_fs= root_available root_used
    LINUX_COPY_ROOT_MNT="$root"
    efi_dev=$(partition_device_for_number "$DISK" "$LINUX_COPY_EFI_PARTNUM")
    if [ -n "$LINUX_COPY_BOOT_PARTNUM" ]; then
        boot_dev=$(partition_device_for_number "$DISK" "$LINUX_COPY_BOOT_PARTNUM")
        src_boot_fs=$(blkid -s TYPE -o value "$LINUX_COPY_SRC_BOOT")
        { [ "$src_boot_fs" = xfs ] || [ "$src_boot_fs" = ext4 ]; } || error "Unsupported /boot source filesystem: $src_boot_fs"
    fi
    if [ "$LINUX_COPY_ROOT_TYPE" = btrfs ]; then
        local btrfs_label
        btrfs_label=$(blkid -s LABEL -o value "$LINUX_COPY_SRC_ROOT" 2>/dev/null || true)
        if [ -n "$btrfs_label" ]; then
            mkfs.btrfs -f -L "$btrfs_label" "$LINUX_COPY_ROOT_TARGET" >/dev/null || error "Cannot create target Btrfs filesystem"
        else
            mkfs.btrfs -f "$LINUX_COPY_ROOT_TARGET" >/dev/null || error "Cannot create target Btrfs filesystem"
        fi
    else
        linux_copy_format_ext4_or_xfs "$LINUX_COPY_ROOT_TARGET" "$LINUX_COPY_SRC_ROOT"
    fi
    [ -z "$boot_dev" ] || linux_copy_format_ext4_or_xfs "$boot_dev" "$LINUX_COPY_SRC_BOOT"
    local efi_label
    efi_label=$(blkid -s LABEL -o value "$LINUX_COPY_SRC_EFI" 2>/dev/null || true)
    set -- -F 32 -i "$(printf '%s' "$LINUX_COPY_EFI_UUID" | tr -d '-')"
    [ -z "$efi_label" ] || set -- "$@" -n "$efi_label"
    mkfs.vfat "$@" "$efi_dev" >/dev/null || error "Cannot format target EFI filesystem"

    root_available=$(blockdev --getsize64 "$LINUX_COPY_ROOT_TARGET")
    root_used="${LINUX_COPY_ROOT_USED:?missing validated source size}"
    [ "$(( root_used + 256 * 1024 * 1024 < root_available ))" -ne 0 ] || \
        error "Source root data ($root_used bytes) does not fit into staging-safe target root ($root_available bytes)"

    if [ "$LINUX_COPY_ROOT_TYPE" = btrfs ]; then
        linux_copy_btrfs_subvolumes "$root"
    else
        linux_copy_mount_target "$LINUX_COPY_ROOT_TARGET" "$root" "$LINUX_COPY_ROOT_TYPE"
        info "Copying Linux root filesystem, including hidden files, xattrs and ACLs"
        linux_copy_rsync "Linux root" -aHAXS --numeric-ids --one-file-system \
            "$LINUX_COPY_SRC_MNT/" "$root/" || error "Failed to copy Linux root filesystem"
    fi
    if [ -n "$boot_dev" ]; then
        linux_copy_source_mount "$LINUX_COPY_SRC_BOOT" "$src_boot_mnt" "$src_boot_fs"
        linux_copy_mount_target "$boot_dev" "$root/boot" "$src_boot_fs"
        info "Copying Linux /boot"
        linux_copy_rsync "Linux /boot" -aHAXS --numeric-ids --one-file-system \
            "$src_boot_mnt/" "$root/boot/" || error "Failed to copy Linux /boot"
    fi
    linux_copy_source_mount "$LINUX_COPY_SRC_EFI" "$src_efi_mnt" vfat
    mkdir -p "$root/boot/efi"
    mount -t vfat "$efi_dev" "$root/boot/efi" || error "Failed to mount target EFI partition"
    info "Copying EFI bootloader and metadata"
    linux_copy_rsync "EFI" -rt --modify-window=2 "$src_efi_mnt/" "$root/boot/efi/" || error "Failed to copy EFI files"
    [ -f "$root/etc/os-release" ] || error "Copied Linux root is missing /etc/os-release"
    { [ -e "$root/bin/sh" ] || [ -e "$root/usr/bin/sh" ]; } || error "Copied Linux root has no shell"
    linux_copy_repair_boot_configs
    linux_copy_set_hostname "$root" "$TARGET_OS"
    linux_copy_ensure_efi_fallback
    linux_copy_regenerate_lvm_initramfs
    sync

    umount "$root/boot/efi" || error "Failed to unmount target EFI"
    umount "$src_efi_mnt" || error "Failed to unmount source EFI"
    if [ -n "$boot_dev" ]; then
        umount "$root/boot" || error "Failed to unmount target /boot"
        umount "$src_boot_mnt" || error "Failed to unmount source /boot"
    fi
    local submount
    for submount in $LINUX_COPY_BTRFS_MOUNTS; do
        umount "$submount" || error "Could not unmount Btrfs subvolume $submount"
    done
    LINUX_COPY_BTRFS_MOUNTS=""
    umount "$root" || error "Failed to unmount target root"
    umount "$LINUX_COPY_SRC_MNT" || error "Failed to unmount source root"
}

# This runs only after all source and destination mounts have been released.
# Explicitly authorize the already-approved UUID rewrite, with no terminal
# input. Do not interrupt a metadata rewrite merely because it is quiet.
restore_btrfs_uuid() {
    local target="$1" wanted="$2" actual
    match_ere "$wanted" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ||
        error "Invalid source Btrfs UUID"
    [ -b "$target" ] || error "Invalid Btrfs target block device: $target"
    if findmnt -rn -S "$target" >/dev/null 2>&1; then
        error "Refusing UUID rewrite on mounted Btrfs target: $target"
    fi
    actual=$(blkid -p -s UUID -o value "$target") || error "Cannot read target Btrfs UUID"
    if [ "$(to_lower "$actual")" != "$(to_lower "$wanted")" ]; then
        info "Btrfs UUID: $actual -> $wanted (noninteractive metadata rewrite)"
        btrfstune -f -U "$wanted" "$target" </dev/null ||
            error "Cannot restore source Btrfs UUID; inspect the offline filesystem before attempting recovery"
    fi
    actual=$(blkid -p -s UUID -o value "$target") || error "Cannot verify restored Btrfs UUID"
    [ "$(to_lower "$actual")" = "$(to_lower "$wanted")" ] ||
        error "Btrfs UUID verification failed: expected $wanted, got $actual"
    info "Verified Btrfs UUID: $actual"
}

linux_copy_release_staging_and_grow() {
    local root="$LINUX_COPY_ROOT_MNT" target="$LINUX_COPY_ROOT_TARGET" vg
    # No mounted source devices may remain before NBD and staging are released.
    for vg in $LINUX_COPY_SOURCE_VGS; do
        vgchange -an "$vg" >/dev/null || error "Cannot deactivate source LVM group: $vg"
    done
    LINUX_COPY_SOURCE_VGS=""
    cleanup_qcow_nbd || error "Cannot disconnect validated source NBD"
    sync
    umount "$TEMP_STAGE_MNT" || error "Cannot unmount image staging partition"
    TEMP_STAGE_RELEASED=1
    sgdisk -d "$TEMP_STAGE_PART_NUM" "$DISK" >/dev/null || error "Cannot remove temporary staging GPT partition"
    sgdisk -e "$DISK" >/dev/null || error "Cannot normalize destination GPT after removing staging"
    reread_partition_table_strict
    grow_last_partition_reserving_cidata
    case "$LINUX_COPY_ROOT_TYPE" in
        xfs)
            linux_copy_mount_target "$target" "$root" xfs
            xfs_growfs "$root" >/dev/null || error "Cannot expand copied Linux XFS filesystem"
            umount "$root" || error "Cannot unmount expanded XFS filesystem" ;;
        ext4)
            e2fsck -pf "$target" || { rc=$?; [ "$(( rc <= 1 ))" -ne 0 ] || error "Target ext4 fsck failed: $rc"; }
            resize2fs "$target" >/dev/null || error "Cannot expand copied Linux ext4 filesystem" ;;
        btrfs)
            # Source NBD is gone and the destination is unmounted. Use the
            # full UUID rewrite rather than introducing metadata_uuid, which
            # could change the bootloader compatibility of the source image.
            info "Restoring source Btrfs UUID after disconnecting source image"
            restore_btrfs_uuid "$target" "$LINUX_COPY_ROOT_UUID"
            info "Expanding copied Btrfs filesystem"
            mount -t btrfs -o subvolid=5 "$target" "$root" || error "Cannot mount copied Btrfs for expansion"
            btrfs filesystem resize max "$root" >/dev/null || error "Cannot expand copied Btrfs"
            umount "$root" || error "Cannot unmount copied Btrfs" ;;
    esac
    TEMP_STAGE_PART=""
    info "Linux file-copy complete; temporary staging released and root filesystem expanded"
}

installer_write_image_linux_by_copy() {
    IMG_QCOW="$STAGED_IMAGE"

    linux_copy_create_partitions
    linux_copy_recreate_and_copy
    linux_copy_release_staging_and_grow
    QCOW_PARTITION_TABLE=gpt
}

installer_write_seed() {
    local part partuuid mnt="$INSTALL_TMPDIR/cidata"
    part=$(create_nocloud_cidata_partition)
    partuuid=$(lsblk -d -n -r -o PARTUUID "$part" 2>/dev/null | head -n1)
    if [ "$QCOW_PARTITION_TABLE" = dos ]; then
        match_ere "$partuuid" '^[[:xdigit:]]{8}-[[:xdigit:]]{2}$' || error "Invalid MBR CIDATA PARTUUID"
    else
        match_ere "$partuuid" '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ||             error "Failed to read newly created CIDATA PARTUUID"
    fi
    mkdir -p "$mnt"
    mount -t vfat "$part" "$mnt" || error "Failed to mount CIDATA partition $part"

    { [ -n "$FRPC_TOML" ] && [ -f "$FRPC_TOML" ]; } && FRPC_PRESENT=1 || FRPC_PRESENT=""
    write_nocloud_seed "$TARGET_OS" "$mnt/meta-data" "$mnt/user-data" "$partuuid"
    [ -s "$mnt/meta-data" ] && [ -s "$mnt/user-data" ] || error "Incomplete NoCloud seed"
    sync
    umount "$mnt" || error "Failed to unmount CIDATA"
    [ "$(blkid -p -s LABEL -o value "$part")" = CIDATA ] || error "NoCloud FAT volume label was not persisted"
    info "Verified on-disk NoCloud volume label and seed files"
}

print_install_summary() {
    local key
    echo
    echo "==================== Installation summary ===================="
    echo "Disk:       $DISK"
    echo "Target:     $TARGET_OS ${TARGET_VER:-}"
    echo "Hostname:   $(seed_hostname "$TARGET_OS")"
    echo "User:       root"
    echo "SSH port:   ${SSH_PORT:-22}"
    echo "Password:   $([ -n "$PASSWORD_HASH" ] && echo configured || echo 'SSH-key only')"
    echo "SSH keys:"
    if [ -n "$SSH_KEYS_ALL" ]; then
        while IFS= read -r key; do [ -z "$key" ] || echo "  $key"; done <<DDIFY_INPUT_22
$SSH_KEYS_ALL
DDIFY_INPUT_22
    else
        echo "  (none)"
    fi
    echo "=============================================================="
}

do_install() {
    info "Installing $TARGET_OS ${TARGET_VER:-} to $DISK"
    info "Image: $IMG_URL"
    info "[1/5] Prepare rescue workspace and verify image metadata"
    installer_workspace
    installer_stage_optional_inputs
    prepare_image_validation
    info "[2/5] Check disk staging prerequisites"
    warn "Disk staging erases the original system before the full image is downloaded and verified"
    info "[3/5] Commit disk and install operating system"
    commit_disk_and_prepare_source
    if image_is_freebsd_raw; then
        installer_write_freebsd_raw
    elif [ "$TARGET_OS" = freebsd ]; then
        installer_write_image
    else
        installer_write_image_linux_by_copy
    fi
    info "[4/5] Write NoCloud configuration"
    installer_write_seed
    info "[5/5] Final checks and cleanup"
    run_post_install_hook
    show_partition_info
    print_install_summary

    trap - EXIT
    cleanup_install_stage || error "Installation cleanup failed"
    info "Installation complete. Rescue runner will reboot automatically."
}

# ----------------- main -----------------

reset_config() {
    TARGET_OS="" TARGET_VER="" IMG_URL="" DISK=""
    PASSWORD="" PASSWORD_HASH="" PASSWORD_TO_DISPLAY="" AUTO_PASSWORD=0
    SSH_KEYS_ALL="" SSH_KEY_ARGS="" SSH_PORT="" WEB_PORT="" FRPC_TOML="" POST_INSTALL_HOOK="" FRPC_PRESENT=""
    AUTO_YES=0 IMAGE_BUILTIN=0
}

target_versions() {
    case "$1" in
        freebsd) echo "14 15" ;;
        rocky|almalinux) echo "10" ;;
        fedora) echo "44" ;;
        debian) echo "13" ;;
        redhat) echo "" ;;
        *) return 1 ;;
    esac
}

parse_target() {
    [ $# -gt 0 ] || error "Missing target OS"
    TARGET_OS=$(to_lower "$1"); shift
    target_versions "$TARGET_OS" >/dev/null || error "Unknown target OS: $TARGET_OS"

    [ "$TARGET_OS" != redhat ] || { PARSE_SHIFT=0; return; }
    { [ $# -gt 0 ] && { case "$1" in --*) false ;; *) true ;; esac; }; } || error "Missing version for $TARGET_OS"
    TARGET_VER="$1"
    [ -n "$TARGET_VER" ] && printf '%s\n' "$(target_versions "$TARGET_OS")" | tr ' ' '\n' | grep -Fxq -- "$TARGET_VER" || \
        error "Unsupported $TARGET_OS version: $TARGET_VER (supported: $(target_versions "$TARGET_OS"))"
    PARSE_SHIFT=1
}

append_ssh_key() {
    local key
    key=$(parse_ssh_key "$1")
    SSH_KEYS_ALL="${SSH_KEYS_ALL:+$SSH_KEYS_ALL$NL}$key"
}

parse_host_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage ;;
            --disk|--img|--password|--passwd|--ssh-key|--public-key|--ssh-port|--web-port|--frpc-toml|--post-install-hook)
                local opt="$1"; shift
                [ $# -gt 0 ] || error "Need value for $opt"
                case "$opt" in
                    --disk) DISK="$1" ;;
                    --img) IMG_URL="$1" ;;
                    --password|--passwd) PASSWORD="$1" ;;
                    --ssh-key|--public-key) SSH_KEY_ARGS="$SSH_KEY_ARGS $(printf '%s' "$1" | base64 | tr -d '\n')" ;;
                    --ssh-port) is_port_valid "$1" || error "Invalid SSH port: $1"; SSH_PORT="$1" ;;
                    --web-port) is_port_valid "$1" || error "Invalid web port: $1"; WEB_PORT="$1" ;;
                    --frpc-toml) FRPC_TOML="$1" ;;
                    --post-install-hook) POST_INSTALL_HOOK="$1" ;;
                esac
                ;;
            --*=*)
                local opt="${1%%=*}" value="${1#*=}"
                [ -n "$value" ] || error "Empty value: $opt"
                shift; set -- "$opt" "$value" "$@"
                continue ;;
            *) error "Unknown argument: $1" ;;
        esac
        shift
    done
}

ensure_supported_sector_size() {
    local sector
    if [ "$OS" = Linux ]; then
        sector=$(blockdev --getss "$DISK" 2>/dev/null || true)
    else
        sector=$(diskinfo -v "$DISK" 2>/dev/null | awk '/# sectorsize/ {print $1; exit}')
    fi
    [ "$sector" = 512 ] || error "Unsupported logical sector size (${sector:-unknown}) on $DISK; aborting before disk modification"
}

prepare_target_disk() {
    if [ -n "$DISK" ]; then
        { case "$DISK" in /dev/*) true ;; *) false ;; esac; } || DISK="/dev/$DISK"
    else
        auto_detect_disk
    fi
    validate_target_disk "$DISK"
    ensure_supported_sector_size
    capture_target_disk_identity "$DISK"
    resolve_target_disk_from_identity
}

prepare_credentials() {
    local a b
    { [ -n "$PASSWORD" ] || [ -n "$SSH_KEYS_ALL" ]; } || {
        echo "No --password or --ssh-key specified."
        a=$(prompt_secret "Root password (empty = random): ") || error "Cannot read root password"
        if [ -z "$a" ]; then
            PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
            [ -n "$PASSWORD" ] || error "Failed to generate random password"
            PASSWORD_TO_DISPLAY="$PASSWORD"; AUTO_PASSWORD=1
        else
            b=$(prompt_secret "Confirm root password: ") || error "Cannot read password confirmation"
            [ "$a" = "$b" ] || error "Passwords do not match"
            PASSWORD="$a"
        fi
    }

    [ -n "$PASSWORD" ] || return 0
    PASSWORD_HASH=$(hash_password "$PASSWORD")
    PASSWORD=""
}

print_host_summary() {
    echo
    echo "====================== Reinstall plan ======================"
    echo "Host:       $OS $ARCH"
    echo "Target:     $TARGET_OS ${TARGET_VER:-}"
    echo "Disk:       $DISK"
    echo "Image:      $IMG_URL"
    echo "Staging:    disk (erase before full image verification)"
    echo "Hostname:   $(seed_hostname "$TARGET_OS")"
    echo "SSH port:   ${SSH_PORT:-22}"
    [ "$DISK_AUTO_SELECTED" != 1 ] || echo "Disk reason: $AUTO_DETECT_REASON"
    if [ "$AUTO_PASSWORD" = 1 ]; then
        echo "Generated root password: $PASSWORD_TO_DISPLAY"
    else
        echo "Password:   $([ -n "$PASSWORD_HASH" ] && echo configured || echo 'SSH-key only')"
    fi
    echo "============================================================"
}

probe_remote_qcow_virtual_size() {
    local header size
    header=$(mktemp "${TMPDIR:-/tmp}/ddify-qcow.XXXXXX") || return 1
    if { case "$IMG_URL" in *.xz) true ;; *) false ;; esac; }; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 \
                --range 0-262143 "$IMG_URL" 2>/dev/null | xz -dc 2>/dev/null | head -c 72 >"$header" || true
        else
            wget --https-only -qO- --header='Range: bytes=0-262143' "$IMG_URL" 2>/dev/null | \
                xz -dc 2>/dev/null | head -c 72 >"$header" || true
        fi
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 \
            --range 0-71 "$IMG_URL" 2>/dev/null | head -c 72 >"$header" || true
    else
        wget --https-only -qO- --header='Range: bytes=0-71' "$IMG_URL" 2>/dev/null | \
            head -c 72 >"$header" || true
    fi
    if { [ $(wc -c <"$header") -ne 72 ] || [ "$(od -An -tx1 -N4 "$header" | tr -d '[:space:]')" != 514649fb ]; }; then
        rm -f "$header"
        return 1
    fi
    size=$(od -An -tu1 -j24 -N8 "$header" | awk '{for (i=1; i<=8; i++) n=n*256+$i; printf "%.0f\n", n}')
    rm -f "$header"
    { match_ere "$size" '^[0-9]+$' && [ "$size" -gt 0 ]; } || return 1
    printf '%s\n' "$size"
}

validate_target_capacity() {
    local disk_bytes
    disk_bytes=$(get_disk_size_bytes "$DISK") || error "Cannot read target capacity"
    { match_ere "$disk_bytes" '^[0-9]+$' && [ "$disk_bytes" -ge 9499999744 ]; } ||
        error "Minimum supported target disk size is 9.5 GB (rounded down to a 512-byte sector)"
}

preflight_target_image_on_host() {
    { case "$IMG_URL" in https://*) true ;; *) false ;; esac; } || error "Target image URL must use HTTPS"
    info "Checking image URL before rebooting the current OS"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSIL --connect-timeout 15 --max-time 60 --proto '=https' --proto-redir '=https' "$IMG_URL" >/dev/null || \
            error "Image URL preflight failed on host: $IMG_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --spider --tries=1 --timeout=20 "$IMG_URL" >/dev/null 2>&1 || \
            error "Image URL preflight failed on host: $IMG_URL"
    else
        error "No host downloader available for image URL preflight"
    fi
}

validate_supported_install_mode() {
    # Verify capabilities before scheduling a rescue boot, not after disk changes.
    case "$MACHINE_ARCH" in x86_64|aarch64) ;; *) error "Unsupported target architecture: $MACHINE_ARCH" ;; esac
    # No BIOS path has passed first-boot verification for the current backends.
    if { [ "$OS" = Linux ] && ! [ -d /sys/firmware/efi ]; }; then
        error "BIOS installation is not validated for these backends; UEFI is required"
    fi
    if [ "$OS" = FreeBSD ]; then
        # FreeBSD 15.1 exposes machdep.bootmethod only on x86.
        # AArch64 FreeBSD always boots via UEFI, but EFIRT is still required.
        if [ "$MACHINE_ARCH" = x86_64 ]; then
            [ "$(sysctl -n machdep.bootmethod 2>/dev/null || true)" = UEFI ] || \
                error "FreeBSD amd64 host needs UEFI; BIOS bootstrap is unsupported"
        fi
        [ -c /dev/efi ] || error "FreeBSD host lacks /dev/efi for EFI BootNext"
    fi
}

host_main() {
    reset_config
    { [ "${1:-}" != -h ] && [ "${1:-}" != --help ]; } || usage
    [ "$(id -u)" -eq 0 ] || error "Must run as root"
    { [ -f "$0" ] && [ -r "$0" ] && { case "$0" in /dev/fd/*) false ;; *) true ;; esac; } && { case "$0" in /proc/*/fd/*) false ;; *) true ;; esac; }; } ||
        error "Run from a local script file; piping or process substitution is unsupported"

    parse_target "$@"
    local skip=$((1 + PARSE_SHIFT))
    shift "$skip"
    parse_host_options "$@"

    { [ "$TARGET_OS" != redhat ] || [ -n "$IMG_URL" ]; } || error "redhat requires --img URL"
    { case "$IMG_URL" in http://*) false ;; *) true ;; esac; } || error "HTTP image URLs are not supported; use HTTPS"
    detect_os_arch
    validate_supported_install_mode
    ensure_dependencies
    local key
    for key in $SSH_KEY_ARGS; do append_ssh_key "$(printf '%s' "$key" | base64 -d)"; done
    prepare_target_disk
    check_secure_boot
    prepare_credentials
    if [ -z "$IMG_URL" ]; then
        IMG_URL=$(get_default_image_url "$TARGET_OS" "$TARGET_VER")
        IMAGE_BUILTIN=1
    fi
    if image_is_freebsd_raw && [ "$IMAGE_BUILTIN" != 1 ]; then
        error "Custom RAW images require a trusted checksum; use the built-in FreeBSD RAW URL or a QCOW2 override"
    fi
    preflight_target_image_on_host
    validate_target_capacity
    print_host_summary
    warn "Rescue boot currently uses DHCPv4; static IP, VLAN and bonding are not migrated. Verify DHCP access before reboot."
    warn "The apkovl contains password hash/configuration on the boot filesystem; FAT filesystems cannot enforce 0600 access."
    [ "$DISK_AUTO_SELECTED" != 1 ] || print_disk_candidates
    local answer choice=1 i
    if [ "$DISK_AUTO_SELECTED" = 1 ]; then
        choice=""
        i=0
        for candidate in $DISK_CANDIDATE_PATHS; do
            i=$((i + 1))
            if [ "$candidate" = "$DISK" ]; then choice=$i; break; fi
        done
        [ -n "$choice" ] || error "Selected disk is missing from candidate list"
    fi
    printf 'WARNING: all data on %s will be destroyed before the full image is downloaded and verified.\n' "$DISK" >&2
    printf "Select [%s] to confirm, [0] to cancel: " "$choice" >&2
    IFS= read -r answer || error "Confirmation required"
    [ "$answer" = "$choice" ] || error "Destructive operation cancelled (use --disk to choose another device)"

    PASSWORD_TO_DISPLAY=""
    prepare_and_boot_alpine_ram
}

parse_installer_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|--force) AUTO_YES=1 ;;
            *) error "Unknown installer argument: $1" ;;
        esac
        shift
    done
}

installer_main() {
    (set -o pipefail) 2>/dev/null || error "Rescue sh must support pipefail for verified writes"
    set -o pipefail
    reset_config
    parse_installer_options "$@"

    [ "$(id -u)" -eq 0 ] || error "Must run as root"
    detect_os_arch
    load_install_plan
    ensure_dependencies
    validate_supported_install_mode

    { [ -z "$DISK" ] || { case "$DISK" in /dev/*) true ;; *) false ;; esac; }; } || DISK="/dev/$DISK"
    [ -n "$DISK" ] || error "Install plan contains no target disk"
    resolve_target_disk_from_identity
    validate_target_disk "$DISK"
    ensure_supported_sector_size
    do_install
}

main() {
    case "${1:-}" in
        --phase)
            shift
            [ "${1:-}" = installer ] || error "Only --phase installer is supported"
            shift
            installer_main "$@"
            ;;
        *) host_main "$@" ;;
    esac
}

main "$@"
