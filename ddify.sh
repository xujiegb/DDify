#!/usr/bin/env bash

set -Eeuo pipefail
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
  --img URL              Override qcow2/qcow2.xz image URL
  --password PASSWORD    Root password
  --ssh-key KEY          Public key, file, URL, github:user or gitlab:user; repeatable
  --ssh-port PORT        SSH port (default 22)
  --web-port PORT        Write /etc/reinstall-web-port through NoCloud
  --frpc-toml PATH|URL   Embed/download FRPC config
  --post-install-hook P  Run hook after image/NoCloud write
  --hold 1               Validate only
  --hold 2               Install but do not reboot

If neither password nor SSH key is given, an empty password prompt generates a random password.
EOF
    exit 0
}

to_lower() {
    printf '%s' "${1:-}" | LC_ALL=C tr 'A-Z' 'a-z'
}

is_port_valid() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

http_download() {
    local url="$1" dst="$2" tmp
    tmp="${dst}.part.$$"
    [[ "$url" == https://* ]] || error "Downloads require HTTPS: $url"
    rm -f "$tmp"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL --proto '=https' --proto-redir '=https' -o "$tmp" "$url"; then
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
        curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$1"
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
    ' <<<"$line"
}

# ----------------- host preparation -----------------

hash_password() {
    local plain="$1"
    if command -v openssl >/dev/null 2>&1; then
        printf '%s\n' "$plain" | openssl passwd -6 -stdin
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import passlib.hash' 2>/dev/null; then
        printf '%s' "$plain" | python3 -c 'import sys; from passlib.hash import sha512_crypt; print(sha512_crypt.hash(sys.stdin.read()))'
    elif command -v perl >/dev/null 2>&1; then
        printf '%s\n' "$plain" | perl -e '
            chomp(my $pw = <STDIN>);
            my @chars = ("a".."z", "A".."Z", 0..9, ".", "/");
            my $salt = join "", map { $chars[int rand @chars] } 1..16;
            print crypt($pw, "\$6\$rounds=5000\$$salt\$") . "\n";
        '
    else
        error "Password hashing requires openssl, python3 with passlib, or perl"
    fi
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

    [[ "$OS" == "Linux" ]] || return 0

    if [[ -r /etc/os-release ]]; then
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
    local missing=()

    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v xz >/dev/null 2>&1 || missing+=("xz")
    command -v file >/dev/null 2>&1 || missing+=("file")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    have_any_downloader || missing+=("downloader")

    ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
}

missing_deps_freebsd_host() {
    local missing=()

    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    command -v xz >/dev/null 2>&1 || missing+=("xz")
    command -v file >/dev/null 2>&1 || missing+=("file")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=("downloader")
    command -v efibootmgr >/dev/null 2>&1 || missing+=("efibootmgr")

    ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
}

install_deps_redhat() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)   pkgs+=("qemu-img") ;;
            xz)         pkgs+=("xz") ;;
            file)       pkgs+=("file") ;;
            tar)        pkgs+=("tar") ;;
            downloader) pkgs+=("curl") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v dnf >/dev/null 2>&1 || error "Auto-install requires dnf on Red Hat family system"

    info "Installing missing dependencies with dnf: ${pkgs[*]}"
    dnf install -y "${pkgs[@]}"
}

install_deps_debian() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)   pkgs+=("qemu-utils") ;;
            xz)         pkgs+=("xz-utils") ;;
            file)       pkgs+=("file") ;;
            tar)        pkgs+=("tar") ;;
            downloader) pkgs+=("curl") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v apt >/dev/null 2>&1 || error "Auto-install requires apt on Debian system"

    info "Installing missing dependencies with apt: ${pkgs[*]}"
    apt-get update && apt-get install -y "${pkgs[@]}"
}

install_deps_freebsd_host() {
    local pkgs=()
    local item

    for item in "$@"; do
        case "$item" in
            qemu-img)          pkgs+=("qemu-tools") ;;
            xz)                pkgs+=("xz") ;;
            file)              pkgs+=("file") ;;
            tar)               : ;;
            downloader)        pkgs+=("curl") ;;
            efibootmgr)        pkgs+=("efibootmgr") ;;
        esac
    done

    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    command -v pkg >/dev/null 2>&1 || error "Auto-install requires pkg on FreeBSD"

    info "Installing missing dependencies with pkg: ${pkgs[*]}"
    ASSUME_ALWAYS_YES=yes pkg install "${pkgs[@]}"
}

ensure_dependencies() {
    local missing=()

    if [[ "$OS" == "Linux" ]]; then
        [[ -f /etc/alpine-release ]] && return 0
        detect_linux_family
        mapfile -t missing < <(missing_deps_linux_common)
        ((${#missing[@]})) || return 0
        case "$LINUX_FAMILY" in
            redhat)
                install_deps_redhat "${missing[@]}"
                ;;
            debian)
                install_deps_debian "${missing[@]}"
                ;;
            *)
                error "Unsupported Linux family for dependency auto-install. Missing: ${missing[*]}"
                ;;
        esac
        mapfile -t missing < <(missing_deps_linux_common)
        ((${#missing[@]} == 0)) || error "Failed to install Linux dependencies: ${missing[*]}"
        return 0
    fi

    mapfile -t missing < <(missing_deps_freebsd_host)
    ((${#missing[@]})) && install_deps_freebsd_host "${missing[@]}"
    mapfile -t missing < <(missing_deps_freebsd_host)
    ((${#missing[@]} == 0)) || error "Failed to install FreeBSD dependencies: ${missing[*]}"
}

AUTO_DETECTED_DISK=""
AUTO_DETECT_REASON=""
DISK_CANDIDATE_LINES=""
DISK_CANDIDATE_PATHS=()
DISK_AUTO_SELECTED=0
DISK_ID_WWN=""
DISK_ID_SERIAL=""
DISK_ID_SIZE=""
DISK_ID_MODEL=""
DISK_ID_PTUUID=""
DISK_ID_MBR_ID=""

validate_target_disk() {
    local disk="$1" typ d

    [[ -n "$disk" ]] || error "Target disk is empty"

    if [[ "$OS" == "Linux" ]]; then
        [[ -b "$disk" ]] || error "Target disk $disk is not a block device"
        command -v lsblk >/dev/null 2>&1 || error "lsblk is required to validate the target disk on Linux"
        typ=$(lsblk -ndo TYPE "$disk" 2>/dev/null | head -n1 || true)
        [[ "$typ" == "disk" ]] || error "Target $disk is not a whole disk (lsblk TYPE=${typ:-unknown})"
        return 0
    fi

    [[ -c "$disk" || -b "$disk" ]] || error "Target disk $disk does not exist"
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

capture_target_disk_identity() {
    local disk="$1" line d

    DISK_ID_WWN=""
    DISK_ID_SERIAL=""
    DISK_ID_SIZE=""
    DISK_ID_MODEL=""
    DISK_ID_PTUUID=""
    DISK_ID_MBR_ID=""

    if [[ "$OS" == "Linux" ]]; then
        line=$(lsblk -b -dn -P -o WWN,SERIAL,SIZE,MODEL "$disk" 2>/dev/null | head -n1 || true)
        [[ -n "$line" ]] || error "Failed to read target disk identity: $disk"
        DISK_ID_WWN=$(normalize_disk_wwn "$(lsblk_get_kv "$line" "WWN")")
        DISK_ID_SERIAL=$(lsblk_get_kv "$line" "SERIAL")
        DISK_ID_SIZE=$(lsblk_get_kv "$line" "SIZE")
        DISK_ID_MODEL=$(lsblk_get_kv "$line" "MODEL")
        if [[ "$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)" == gpt ]]; then
            DISK_ID_PTUUID=$(blkid -s PTUUID -o value "$disk" 2>/dev/null || true)
        elif [[ "$(blkid -s PTTYPE -o value "$disk" 2>/dev/null || true)" == dos ]]; then
            DISK_ID_MBR_ID=$(blkid -s PTUUID -o value "$disk" 2>/dev/null || true)
            [[ "$DISK_ID_MBR_ID" =~ ^[[:xdigit:]]{8}$ && "${DISK_ID_MBR_ID,,}" != 00000000 ]] || DISK_ID_MBR_ID=""
        fi
    else
        d="${disk#/dev/}"
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

    [[ "$DISK_ID_SIZE" =~ ^[0-9]+$ && "$DISK_ID_SIZE" -gt 0 ]] ||
        error "Unable to read target disk size"
    [[ -z "$DISK_ID_PTUUID" || "$DISK_ID_PTUUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        error "Target disk GPT GUID is invalid; refusing unattended reinstallation"
    [[ -n "$DISK_ID_SERIAL" || -n "$DISK_ID_WWN" || -n "$DISK_ID_PTUUID" || -n "$DISK_ID_MBR_ID" ]] || \
        error "Target disk lacks a usable WWN, serial, GPT GUID or MBR signature"

    if [[ -n "$DISK_ID_MBR_ID" && -z "$DISK_ID_WWN$DISK_ID_SERIAL" ]]; then
        warn "Using a 32-bit MBR disk signature as fallback identity; cloned disks must be disconnected"
    fi
    info "Target disk identity: serial=${DISK_ID_SERIAL:-unknown} wwn=${DISK_ID_WWN:-unknown} size=${DISK_ID_SIZE:-unknown}"
}

list_disk_identities() {
    local line path type wwn serial size model ptuuid="" mbr_id="" d

    if [[ "$OS" == Linux ]]; then
        while IFS= read -r line; do
            type=$(lsblk_get_kv "$line" TYPE)
            [[ "$type" == disk ]] || continue
            path=$(lsblk_get_kv "$line" PATH)
            wwn=$(normalize_disk_wwn "$(lsblk_get_kv "$line" WWN)")
            serial=$(lsblk_get_kv "$line" SERIAL)
            size=$(lsblk_get_kv "$line" SIZE)
            model=$(lsblk_get_kv "$line" MODEL)
            ptuuid=""; mbr_id=""
            if [[ "$(blkid -s PTTYPE -o value "$path" 2>/dev/null || true)" == gpt ]]; then
                ptuuid=$(blkid -s PTUUID -o value "$path" 2>/dev/null || true)
            elif [[ "$(blkid -s PTTYPE -o value "$path" 2>/dev/null || true)" == dos ]]; then
                mbr_id=$(blkid -s PTUUID -o value "$path" 2>/dev/null || true)
                [[ "$mbr_id" =~ ^[[:xdigit:]]{8}$ && "${mbr_id,,}" != 00000000 ]] || mbr_id=""
            fi
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$path" "$wwn" "$serial" "$size" "$model" "$ptuuid" "$mbr_id"
        done < <(lsblk -b -dn -P -o PATH,TYPE,WWN,SERIAL,SIZE,MODEL 2>/dev/null)
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

disk_identity_matches() {
    local wwn="$1" serial="$2" size="$3" model="$4" ptuuid="${5:-}" mbr_id="${6:-}" pair stored current hit=0
    [[ -n "${DISK_ID_SIZE:-}" && "$size" == "$DISK_ID_SIZE" ]] || return 1
    for pair in "${DISK_ID_WWN:-}|$wwn" "${DISK_ID_SERIAL:-}|$serial" "${DISK_ID_PTUUID,,}|${ptuuid,,}" "${DISK_ID_MBR_ID,,}|${mbr_id,,}"; do
        stored=${pair%%|*}; current=${pair#*|}
        [[ -n "$stored" && -n "$current" ]] || continue
        [[ "$stored" == "$current" ]] || return 1
        hit=1
    done
    ((hit))
}

resolve_target_disk_from_identity() {
    local path wwn serial size model ptuuid mbr_id
    local matches=()
    [[ -n "${DISK_ID_WWN:-}${DISK_ID_SERIAL:-}${DISK_ID_PTUUID:-}${DISK_ID_MBR_ID:-}" ]] || \
        error "No strong target disk identity recorded; refusing destructive write"
    while IFS='|' read -r path wwn serial size model ptuuid mbr_id; do
        disk_identity_matches "$wwn" "$serial" "$size" "$model" "$ptuuid" "$mbr_id" && matches+=("$path")
    done < <(list_disk_identities)

    ((${#matches[@]} == 1)) || error "Saved target identity matched ${#matches[@]} disks; refusing destructive write"
    [[ -z "${DISK:-}" || "$DISK" == "${matches[0]}" ]] || info "Target disk path changed: $DISK -> ${matches[0]}"
    DISK="${matches[0]}"
}

get_disk_size_bytes() {
    local disk="$1"
    if [[ "$OS" == "Linux" ]]; then
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --getsize64 "$disk" 2>/dev/null && return 0
        fi
        lsblk -b -dn -o SIZE "$disk" 2>/dev/null | head -n1
        return 0
    fi
    diskinfo "$disk" 2>/dev/null | awk 'NR==1 {print $3; exit}'
}

unmount_target_disk_filesystems() {
    local disk="$1" dev mnt d sysname holder_found holder

    cd /

    if [[ "$OS" == "Linux" ]]; then
        command -v lsblk >/dev/null 2>&1 || error "lsblk is required before destructive write"

        if command -v swapon >/dev/null 2>&1 && command -v swapoff >/dev/null 2>&1; then
            while IFS= read -r dev; do
                [[ -n "$dev" ]] || continue
                if lsblk -nrpo NAME "$disk" 2>/dev/null | grep -Fxq "$dev"; then
                    info "Disabling swap on target disk: $dev"
                    swapoff "$dev" || error "Failed to disable target-disk swap: $dev"
                fi
            done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
        fi

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            while IFS= read -r mnt; do
                [[ -n "$mnt" ]] || continue
                info "Unmounting target-disk filesystem: $dev from $mnt"
                if ! umount "$mnt"; then
                    warn "Failed to unmount $mnt; dumping mount/loop diagnostics before aborting."
                    findmnt -R "$mnt" 2>/dev/null || true
                    losetup -a 2>/dev/null || true
                    if command -v fuser >/dev/null 2>&1; then
                        fuser -vm "$mnt" 2>/dev/null || true
                    fi
                    error "Failed to unmount target-disk filesystem: $mnt"
                fi
            done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null | tac)

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            if findmnt -rn -S "$dev" >/dev/null 2>&1; then
                error "A target-disk filesystem is still mounted on $dev; refusing dd"
            fi
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null)

        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            sysname="${dev#/dev/}"
            sysname="${sysname//\//!}"
            holder_found=0
            if [[ -d "/sys/class/block/$sysname/holders" ]]; then
                for holder in "/sys/class/block/$sysname/holders/"*; do
                    [[ -e "$holder" ]] || continue
                    holder_found=1
                    break
                done
            fi
            [[ "$holder_found" -eq 0 ]] || error "Target-disk device $dev still has active block holders; refusing dd"
        done < <(lsblk -nrpo NAME "$disk" 2>/dev/null)
        return 0
    fi

    d="${disk#/dev/}"
    while read -r dev mnt _; do
        case "$dev" in
            /dev/${d}p*|/dev/${d}s*|/dev/${d})
                info "Unmounting target-disk filesystem: $dev from $mnt"
                umount "$mnt" || error "Failed to unmount target-disk filesystem: $mnt"
                ;;
        esac
    done < <(mount -p 2>/dev/null || true)
}

linux_source_to_disk() {
    local src="${1%%\[*}" name typ
    local disks=()
    [[ -b "$src" ]] || return 1
    while read -r name typ; do
        [[ "$typ" == disk ]] && disks+=("$name")
    done < <(lsblk -s -l -n -p -o NAME,TYPE "$src" 2>/dev/null | awk '!seen[$1]++')
    ((${#disks[@]} == 1)) || return 1
    printf '%s\n' "${disks[0]}"
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
    [[ -n "$src" ]] || return 1
    linux_source_to_disk "$src"
}

linux_current_boot_disk() {
    local src
    src=$(linux_find_mount_source "/boot")
    [[ -n "$src" ]] || return 1
    linux_source_to_disk "$src"
}

linux_current_efi_disk() {
    local src
    src=$(linux_find_mount_source "/boot/efi")
    [[ -n "$src" ]] || return 1
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

    [[ -n "$source" ]] || return 1
    provider="${source#/dev/}"
    disks=$(sysctl -n kern.disks 2>/dev/null || true)
    [[ -n "$disks" ]] || return 1

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
        if [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    fi

    return 1
}

print_disk_candidates() {
    [[ -n "$DISK_CANDIDATE_LINES" ]] || return 0
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
    [[ -z "$tags" ]] || line+=" markers:$tags"
    [[ -z "$note" ]] || line+=" ($note)"
    DISK_CANDIDATE_LINES+="${DISK_CANDIDATE_LINES:+$'\n'}$line"
    DISK_CANDIDATE_PATHS+=("$path")
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

    [[ -z "$root" ]] || info "Current /: $root"
    [[ -z "$boot" ]] || info "Current /boot: $boot"
    [[ -z "$efi" ]] || info "Current EFI: $efi"

    if [[ -n "$root" && "$root" == "$boot" && "$root" == "$efi" ]]; then
        preferred="$root"; reason="/, /boot and EFI resolve to this disk"
    elif [[ -n "$root" ]]; then
        preferred="$root"; reason="current / resolves to this disk"
    elif [[ -n "$boot" ]]; then
        preferred="$boot"; reason="current /boot resolves to this disk"
    else
        preferred="$efi"; reason="current EFI resolves to this disk"
    fi

    while read -r name type rm size; do
        [[ "$type" == disk && "$rm" == 0 ]] || continue
        path="/dev/$name"
        tags=""
        [[ "$path" != "$root" ]] || tags+=" root"
        [[ "$path" != "$boot" ]] || tags+=" boot"
        [[ "$path" != "$efi" ]] || tags+=" efi"
        [[ "$path" != "$preferred" ]] || tags+=" recommended"
        candidate_add "$path" "$size" "$tags" "$([[ "$path" == "$preferred" ]] && echo "$reason")"
    done < <(lsblk -b -ndo NAME,TYPE,RM,SIZE 2>/dev/null)

    [[ -n "$preferred" ]] || error "Unable to identify the current Linux system disk; use --disk"
    select_detected_disk "$preferred" "$reason"
}

auto_detect_freebsd_disk() {
    local disks root_source root_disk d size count=0 only="" tags note
    disks=$(sysctl -n kern.disks 2>/dev/null || true)
    [[ -n "$disks" ]] || error "kern.disks is empty; use --disk"

    root_source=$(freebsd_mount_source_for "/" || true)
    root_disk=$(freebsd_provider_to_disk "$root_source" || true)
    [[ -z "$root_source" ]] || info "Current /: $root_source"
    [[ -z "$root_disk" ]] || info "Current / through GEOM: $root_disk"

    for d in $disks; do
        case "$d" in cd*|md*|lo*|ram*) continue ;; esac
        size=$(diskinfo "/dev/$d" 2>/dev/null | awk 'NR==1 {print $3; exit}')
        size=${size:-0}
        count=$((count + 1)); only="/dev/$d"; tags=""; note=""
        if [[ "$only" == "$root_disk" ]]; then
            tags=" root recommended"
            note="current / resolves through GEOM to this disk"
        fi
        candidate_add "$only" "$size" "$tags" "$note"
    done

    if [[ -n "$root_disk" ]] && grep -qw "${root_disk#/dev/}" <<<"$disks"; then
        select_detected_disk "$root_disk" "current / resolves through FreeBSD GEOM to this disk"
        return
    fi
    [[ "$count" == 1 ]] && { select_detected_disk "$only" "only usable physical disk"; return; }
    error "Unable to identify the FreeBSD system disk confidently; use --disk"
}

auto_detect_disk() {
    info "Auto-detecting target disk..."
    DISK_CANDIDATE_LINES=""
    DISK_CANDIDATE_PATHS=()
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
    if [[ "$OS" == "Linux" ]]; then
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
    if [[ -z "${POST_INSTALL_HOOK:-}" ]]; then
        return 0
    fi

    if [[ ! -f "$POST_INSTALL_HOOK" ]]; then
        warn "Post-install hook not found: $POST_INSTALL_HOOK"
        return 0
    fi

    info "Running explicit post-install hook: $POST_INSTALL_HOOK"
    if ! bash "$POST_INSTALL_HOOK"; then
        error "Post-install hook failed: $POST_INSTALL_HOOK"
    fi
}

parse_ssh_key() {
    local val="$1" url="" text=""
    case "$(to_lower "$val")" in
        github:*|gitlab:*)
            local site user
            site="${val%%:*}"; user="${val#*:}"
            [[ "$user" =~ ^[A-Za-z0-9_-]+$ ]] || error "Invalid public-key username"
            url="https://${site,,}.com/${user}.keys" ;;
        https://*) url="$val" ;;
        http://*) error "SSH key URLs must use HTTPS" ;;
    esac
    if [[ -n "$url" ]]; then
        text=$(http_download_stdout "$url") || error "Unable to download public keys"
    elif [[ -f "$val" ]]; then
        text=$(cat -- "$val")
    else
        text="$val"
    fi
    local filtered
    filtered=$(printf '%s\n' "$text" | tr -d '\r' | grep -E '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com) [A-Za-z0-9+/=]+([[:space:]].*)?$' || true)
    [[ -n "$filtered" ]] || error "No supported SSH public key in input"
    printf '%s\n' "$filtered"
}

get_default_image_url() {
    local key="$1:$2:$MACHINE_ARCH"

    case "$key" in
        freebsd:14:x86_64)  echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/amd64/Latest/FreeBSD-14.5-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz" ;;
        freebsd:14:aarch64) echo "https://download.freebsd.org/releases/VM-IMAGES/14.5-RELEASE/aarch64/Latest/FreeBSD-14.5-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz" ;;
        freebsd:15:x86_64)  echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz" ;;
        freebsd:15:aarch64) echo "https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/aarch64/Latest/FreeBSD-15.1-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz" ;;
        rocky:10:x86_64)    echo "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-EC2-LVM.latest.x86_64.qcow2" ;;
        rocky:10:aarch64)   echo "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-EC2-LVM.latest.aarch64.qcow2" ;;
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
        [[ -n "$key" ]] || continue
        key=${key//\\/\\\\}
        key=${key//\"/\\\"}
        printf '%s- "%s"\n' "$indent" "$key"
    done <<<"$SSH_KEYS_ALL"
}

seed_account_freebsd() {
    echo "disable_root: false"
    echo "ssh_pwauth: $([[ -n "$PASSWORD_HASH" ]] && echo true || echo false)"

    if [[ -n "$SSH_KEYS_ALL" ]]; then
        echo "users:"
        echo "  - name: root"
        echo "    ssh_authorized_keys:"
        emit_ssh_keys "      "
    fi

    [[ -n "$PASSWORD_HASH" ]] || return 0
    cat <<EOF

chpasswd:
  expire: false
  users:
    - name: root
      password: "${PASSWORD_HASH}"
EOF
}

seed_account_linux() {
    cat <<'EOF'
preserve_hostname: false
hostname: localhost
prefer_fqdn_over_hostname: false
growpart:
  mode: auto
  devices: [/]
resize_rootfs: true
EOF

    [[ -n "$PASSWORD_HASH" || -n "$SSH_KEYS_ALL" ]] || return 0

    echo "ssh_pwauth: $([[ -n "$PASSWORD_HASH" ]] && echo true || echo false)"
    echo "disable_root: false"
    echo "users:"
    echo "  - name: root"

    if [[ -n "$PASSWORD_HASH" ]]; then
        echo "    lock_passwd: false"
        echo "    hashed_passwd: \"${PASSWORD_HASH}\""
    else
        echo "    lock_passwd: true"
    fi

    [[ -n "$SSH_KEYS_ALL" ]] || return 0
    echo "    ssh_authorized_keys:"
    emit_ssh_keys "      "
}

seed_write_files() {
    local os="$1" frpc_b64="$2" frpc_path="/etc/frp/frpc.toml" owner="root:root"
    if [[ "$os" == freebsd ]]; then
        frpc_path="/etc/frpc.toml"
        owner="root:wheel"
    fi
    [[ -n "$WEB_PORT" || -n "$frpc_b64" ]] || return 0

    echo
    echo "write_files:"

    [[ -z "$WEB_PORT" ]] || cat <<EOF
  - path: /etc/reinstall-web-port
    permissions: '0644'
    owner: ${owner}
    content: |
      $WEB_PORT
EOF

    [[ -z "$frpc_b64" ]] || cat <<EOF
  - path: ${frpc_path}
    permissions: '0600'
    owner: ${owner}
    encoding: b64
    content: $frpc_b64
EOF
}

seed_runcmd_ssh_port() {
    [[ "$1" == "freebsd" || -n "$PASSWORD_HASH" || -n "$SSH_KEYS_ALL" || -n "$SSH_PORT" ]] || return 0
    local permit="prohibit-password" auth="no" port="${SSH_PORT:-22}"
    [[ -z "$PASSWORD_HASH" ]] || { permit="yes"; auth="yes"; }
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
    if [[ "$1" == freebsd ]]; then
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
    [[ -n "$frpc_b64" ]] || return 0
    [[ "$os" != freebsd ]] || frpc_path="/etc/frpc.toml"
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
    [[ "$os" != "freebsd" ]] || { seed_runcmd_cleanup_cidata_freebsd "$partuuid"; return; }
    if [[ "$partuuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{2}$ ]]; then
        seed_runcmd_cleanup_cidata_mbr "$partuuid"
        return
    fi
    [[ "$partuuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || \
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
    seed_runcmd_ssh_port "$os"
    seed_runcmd_expand_root "$os"
    seed_runcmd_frpc "$os" "$frpc_b64"
    cat <<'EOF'
  - |
      [ "${ddify_ssh_failed:-0}" = 0 ] || {
          echo "DDify: SSH setup failed; CIDATA retained for recovery" >&2
          exit 1
      }
EOF
    seed_runcmd_cleanup_cidata "$os" "$cidata_partuuid"
}

write_nocloud_seed() {
    local os="$1" meta="$2" user="$3" cidata_partuuid="${4:-}" frpc_b64=""

    mkdir -p "$(dirname "$meta")"
    cat >"$meta" <<EOF
instance-id: iid-$(date +%s)
local-hostname: localhost
EOF

    [[ -z "${FRPC_PRESENT:-}" || -z "${FRPC_TOML:-}" || ! -f "$FRPC_TOML" ]] || \
        frpc_b64=$(base64 <"$FRPC_TOML" | tr -d '\n')

    {
        echo "#cloud-config"
        case "$os" in
            freebsd) seed_account_freebsd ;;
            *)       seed_account_linux ;;
        esac
        seed_write_files "$os" "$frpc_b64"
        seed_runcmd "$os" "$frpc_b64" "$cidata_partuuid"
    } >"$user"
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

find_efi_for_plan() {
    local os
    os=$(uname -s)
    if [[ "$os" == "Linux" ]]; then
        if command -v findmnt >/dev/null 2>&1; then
            local mounted_src
            mounted_src=$(findmnt -n -o SOURCE --mountpoint /boot/efi 2>/dev/null | head -n1 || true)
            if [[ -n "$mounted_src" && -b "$mounted_src" ]]; then
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

                [[ "$type" == "part" ]] || continue
                if [[ "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" && "$fstype" == "vfat" ]] && \
                   [[ "$(linux_source_to_disk "$path" || true)" == "$DISK" ]]; then
                    if [[ -n "$path" ]]; then
                        echo "$path"
                    else
                        echo "/dev/$name"
                    fi
                    return 0
                fi
            done < <(lsblk -P -o PATH,NAME,TYPE,PARTTYPE,FSTYPE,PARTLABEL,PARTFLAGS 2>/dev/null || true)
        fi
    elif [[ "$os" == "FreeBSD" ]]; then
        if command -v sysctl >/dev/null 2>&1 && command -v gpart >/dev/null 2>&1; then
            local d p preferred=""

            if [[ -n "${DISK:-}" ]]; then
                preferred="${DISK#/dev/}"
                p=$(gpart show -p "$preferred" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [[ -n "$p" ]]; then
                    echo "/dev/$p"
                    return 0
                fi
            fi

            for d in $(sysctl -n kern.disks 2>/dev/null || true); do
                [[ -n "$preferred" && "$d" == "$preferred" ]] && continue
                p=$(gpart show -p "$d" 2>/dev/null | awk '$4 == "efi" {print $3; exit}')
                if [[ -n "$p" ]]; then
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

    if [[ "$desc" =~ serial[[:space:]]number[[:space:]]0x([0-9A-Fa-f]{1,8}) ]]; then
        serial="${BASH_REMATCH[1]}"
    else
        return 0
    fi

    while ((${#serial} < 8)); do
        serial="0${serial}"
    done
    serial="${serial^^}"

    printf '%s-%s\n' "${serial:0:4}" "${serial:4:4}"
}

mount_efi_for_plan() {
    if [[ "$OS" == "Linux" ]]; then
        if [[ -d /boot/efi ]] && is_mountpoint /boot/efi; then
            EFI_MOUNT_POINT="/boot/efi"
            PLAN_STORAGE_MODE="efi"
            PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint /boot/efi 2>/dev/null | head -n1 || true)
        else
            local efi_part
            efi_part=$(find_efi_for_plan 2>/dev/null || true)
            if [[ -n "$efi_part" ]]; then
                EFI_MOUNT_POINT="/boot/efi"
                mkdir -p "$EFI_MOUNT_POINT"
                mount "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    mount -t vfat "$efi_part" "$EFI_MOUNT_POINT" 2>/dev/null || \
                    error "Failed to mount EFI partition $efi_part"
                PLAN_STORAGE_MODE="efi"
                PLAN_EFI_PART="$efi_part"
            else
                [[ -d /boot ]] || error "No EFI partition and no /boot fallback"
                EFI_MOUNT_POINT="/boot"
                PLAN_STORAGE_MODE="boot"
                if is_mountpoint /boot; then
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint /boot 2>/dev/null | head -n1 || true)
                else
                    PLAN_EFI_PART=$(findmnt -n -o SOURCE --mountpoint / 2>/dev/null | head -n1 || true)
                fi
            fi
        fi
        [[ -n "$PLAN_EFI_PART" ]] && PLAN_EFI_UUID=$(get_fs_uuid_linux "$PLAN_EFI_PART")
        return 0
    fi

    local mounted_src="" efi_part=""
    if [[ -d "$EFI_MOUNT_POINT" ]] && is_mountpoint "$EFI_MOUNT_POINT"; then
        mounted_src=$(freebsd_mount_source_for "$EFI_MOUNT_POINT" || true)
        efi_part=$(find_efi_for_plan 2>/dev/null || true)
        PLAN_EFI_PART="${efi_part:-$mounted_src}"
        [[ "$PLAN_EFI_PART" == /dev/*p[0-9]* ]] || error "Could not resolve the physical FreeBSD EFI partition"
        PLAN_EFI_UUID=$(get_fs_uuid_freebsd "$PLAN_EFI_PART")
        PLAN_STORAGE_MODE="efi"
        info "Using FreeBSD EFI: ${mounted_src:-$PLAN_EFI_PART} -> $PLAN_EFI_PART"
        return 0
    fi

    efi_part=$(find_efi_for_plan 2>/dev/null || true)
    [[ -n "$efi_part" ]] || error "Could not find FreeBSD EFI partition"
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

write_install_plan() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    {
        printf 'TARGET_OS=%q\n' "$TARGET_OS"
        printf 'TARGET_VER=%q\n' "$TARGET_VER"
        printf 'DISK=%q\n' "$DISK"
        printf 'DISK_ID_WWN=%q\n' "${DISK_ID_WWN:-}"
        printf 'DISK_ID_SERIAL=%q\n' "${DISK_ID_SERIAL:-}"
        printf 'DISK_ID_SIZE=%q\n' "${DISK_ID_SIZE:-}"
        printf 'DISK_ID_MODEL=%q\n' "${DISK_ID_MODEL:-}"
        printf 'DISK_ID_PTUUID=%q\n' "${DISK_ID_PTUUID:-}"
        printf 'DISK_ID_MBR_ID=%q\n' "${DISK_ID_MBR_ID:-}"
        printf 'IMG_URL=%q\n' "$IMG_URL"
        printf 'IMAGE_BUILTIN=%q\n' "${IMAGE_BUILTIN:-0}"
        printf 'PASSWORD_HASH=%q\n' "$PASSWORD_HASH"
        printf "SSH_KEYS_ALL='%s'\n" "${SSH_KEYS_ALL//\'/\'\\\'\'}"
        printf 'SSH_PORT=%q\n' "$SSH_PORT"
        printf 'WEB_PORT=%q\n' "$WEB_PORT"
        printf 'FRPC_TOML=%q\n' "$FRPC_TOML"
        printf 'POST_INSTALL_HOOK=%q\n' "$POST_INSTALL_HOOK"
        printf 'AUTO_PASSWORD=%q\n' "$AUTO_PASSWORD"
        printf 'HOLD=%q\n' "$HOLD"
        printf 'PLAN_EFI_UUID=%q\n' "$PLAN_EFI_UUID"
    } >"$path"
    chmod 0600 "$path" 2>/dev/null || true
}

load_install_plan() {
    local plan="/etc/reinstall/plan.env"
    [[ -f "$plan" ]] || error "Embedded install plan not found: $plan"
    # shellcheck disable=SC1090
    . "$plan"
    PASSWORD=""
    PASSWORD_HASH="${PASSWORD_HASH:-}"
    [[ ! -f /etc/reinstall/frpc.toml ]] || FRPC_TOML="/etc/reinstall/frpc.toml"
    [[ ! -f /etc/reinstall/post-install-hook.sh ]] || POST_INSTALL_HOOK="/etc/reinstall/post-install-hook.sh"
    info "Loaded embedded install plan"
}

# ----------------- Alpine RAM / boot bootstrap -----------------

detect_current_console_args() {
    CURRENT_CONSOLE_ARGS=""
    if [[ -r /proc/cmdline ]]; then
        local tok
        for tok in $(cat /proc/cmdline); do
            case "$tok" in
                console=*)
                    CURRENT_CONSOLE_ARGS+=" $tok"
                    ;;
            esac
        done
    fi

    if [[ -z "$CURRENT_CONSOLE_ARGS" ]]; then
        CURRENT_CONSOLE_ARGS=" console=ttyS0 console=tty0"
    fi
}

ensure_grub_tools() {
    [[ "$OS" == "Linux" ]] || error "GRUB bootstrap requires Linux host"

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

    [[ -d /etc/grub.d ]] || error "/etc/grub.d not found"
    GRUB_SCRIPT_PATH="/etc/grub.d/09_reinstall_alpine"

    if [[ -f /boot/grub2/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub2/grub.cfg"
    elif [[ -f /boot/grub/grub.cfg ]]; then
        GRUB_CFG_PATH="/boot/grub/grub.cfg"
    else
        error "GRUB config not found"
    fi
}

ensure_freebsd_boot_tools() {
    [[ "$OS" == "FreeBSD" ]] || error "Automatic FreeBSD BootNext bootstrap only supports FreeBSD host"
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

    [[ "$PLAN_STORAGE_MODE" != "efi" || -n "$PLAN_EFI_UUID" ]] || error "Bootstrap filesystem UUID unavailable"

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
    if [[ "$PLAN_STORAGE_MODE" == boot ]] && ! is_mountpoint /boot; then
        local root_fs root_source root_type
        root_fs=$(findmnt -n -o FSTYPE --mountpoint / 2>/dev/null || true)
        root_source=$(findmnt -n -o SOURCE --mountpoint / 2>/dev/null || true)
        root_source="${root_source%%\[*}"
        root_type=$(lsblk -dn -o TYPE "$root_source" 2>/dev/null || true)
        [[ "$root_fs" == ext2 || "$root_fs" == ext3 || "$root_fs" == ext4 ]] &&
        [[ "$root_type" == part || "$root_type" == disk ]] ||
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
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 22528 )); then
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
    [[ -f "$self" ]] || error "Cannot locate current script: $self"
    cp "$self" "$ovl_dir/usr/local/sbin/reinstall-installer.sh"
    chmod 0755 "$ovl_dir/usr/local/sbin/reinstall-installer.sh"

    if [[ -n "${FRPC_TOML:-}" && ! "$FRPC_TOML" =~ ^https?:// && -f "$FRPC_TOML" ]]; then
        cp "$FRPC_TOML" "$ovl_dir/etc/reinstall/frpc.toml"
        chmod 0600 "$ovl_dir/etc/reinstall/frpc.toml"
    fi
    if [[ -n "${POST_INSTALL_HOOK:-}" ]]; then
        [[ -f "$POST_INSTALL_HOOK" ]] || error "Post-install hook not found: $POST_INSTALL_HOOK"
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
if [ -w /dev/console ]; then
    exec >/dev/console 2>&1
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
        bash curl wget ca-certificates xz qemu-img util-linux blkid lsblk findmnt coreutils grep sed gawk findutils file tar \
        e2fsprogs e2fsprogs-extra dosfstools sgdisk kmod lvm2 xfsprogs xfsprogs-extra
    update-ca-certificates 2>/dev/null || true
    blkid -V 2>&1 | grep -qi util-linux || { echo "Full util-linux blkid is required" >&2; exit 1; }

    # Fail here with a precise message instead of reaching the destructive stage
    for cmd in sgdisk sfdisk mkfs.ext4 qemu-img qemu-nbd xz curl lsblk blkid mount umount blockdev mknod pvresize xfs_db dumpe2fs resize2fs e2fsck; do
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

    [ "$mem_kb" -ge 716800 ] || {
        echo "DDify requires a VPS with at least 768 MiB installed RAM (usable MemTotal=$mem_kb KiB)." >&2
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
    local mem_kb mem_bytes zram_bytes work_bytes reserve

    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    mem_bytes=$((mem_kb * 1024))
    zram_bytes="$(cat /run/reinstall-zram-bytes 2>/dev/null || echo 0)"
    reserve=201326592
    # zram is compressed swap, not physical RAM; bound tmpfs and watch MemAvailable.
    work_bytes=$((mem_bytes + zram_bytes / 2 - reserve))
    [ "$work_bytes" -gt 536870912 ] || work_bytes=536870912

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
    if bash "$RUN_SCRIPT" --phase installer --yes; then
        rc=0
    else
        rc=$?
    fi
    echo "Installer phase finished with rc=$rc"

    if [ "$rc" -eq 0 ]; then
        if grep -q '^HOLD=2$' "$PLAN_FILE" 2>/dev/null || grep -q "^HOLD='2'$" "$PLAN_FILE" 2>/dev/null; then
            echo "HOLD=2 detected, not rebooting."
            exit 0
        fi
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
echo "[init] entering normal Alpine init for troubleshooting/HOLD mode."
exec /sbin/init
EOF
    chmod 0755 "$initfile"

    # Alpine mkinitfs finds exactly one *.apkovl.tar.gz in the boot filesystem root.
    # Do not force an absolute apkovl= path: it resolves inside initramfs, not GRUB.
    local existing_apkovl
    for existing_apkovl in "$(dirname "$ALPINE_APKOVL_ABS")/"*.apkovl.tar.gz; do
        [[ ! -e "$existing_apkovl" || "$existing_apkovl" == "$ALPINE_APKOVL_ABS" ]] || \
            error "Another apkovl exists on the boot filesystem: $existing_apkovl"
    done
    tar -C "$ovl_dir" -czf "$ALPINE_APKOVL_ABS" .
    chmod 0644 "$ALPINE_APKOVL_ABS"
    rm -rf "$tmp"
    sync
    info "Built Alpine apkovl overlay: $ALPINE_APKOVL_ABS"
}

install_grub_entry_for_alpine() {
    ensure_grub_tools
    detect_current_console_args

    if [[ "$PLAN_STORAGE_MODE" == "efi" ]]; then
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    search --no-floppy --fs-uuid --set=reinstall_efi ${PLAN_EFI_UUID}
    linux (\$reinstall_efi)${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
    initrd (\$reinstall_efi)${ALPINE_INITRAMFS_REL}
}
EOF
    else
        local grub_boot_prefix="/boot"
        is_mountpoint /boot && grub_boot_prefix=""
        [[ -n "$PLAN_EFI_UUID" ]] || error "Cannot locate BIOS bootstrap filesystem UUID"
        cat >"$GRUB_SCRIPT_PATH" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '${ALPINE_ENTRY_TITLE}' {
    search --no-floppy --fs-uuid --set=root ${PLAN_EFI_UUID}
    linux ${grub_boot_prefix}${ALPINE_VMLINUZ_REL} modules=loop,squashfs ip=dhcp alpine_repo=${ALPINE_REPO_BASE}/main modloop=${ALPINE_MODLOOP_URL} modloop_verify=yes reinstall_alpine=1 init=/usr/local/sbin/reinstall-init.sh${CURRENT_CONSOLE_ARGS}
    initrd ${grub_boot_prefix}${ALPINE_INITRAMFS_REL}
}
EOF
    fi
    chmod 0755 "$GRUB_SCRIPT_PATH"

    info "Regenerating GRUB config..."
    "$GRUB_MKCONFIG_CMD" -o "$GRUB_CFG_PATH" >/dev/null

    info "Scheduling one-time GRUB boot into: ${ALPINE_ENTRY_TITLE}"
    "$GRUB_REBOOT_CMD" "${ALPINE_ENTRY_TITLE}"
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
            [[ "${normalized,,}" == "efi/boot/${FREEBSD_GRUB_EFI_NAME,,}" ]] || continue
            echo "$p"; break
        done < <(tar -tf "$iso" 2>/dev/null)
    )
    [[ -n "$member" ]] || error "${FREEBSD_GRUB_EFI_NAME} not found in Alpine ISO"
    mkdir -p "$(dirname "$ALPINE_FREEBSD_GRUB_EFI_ABS")"
    tar -xOf "$iso" "$member" >"$ALPINE_FREEBSD_GRUB_EFI_ABS" || error "Failed to extract Alpine GRUB EFI"
    [[ -s "$ALPINE_FREEBSD_GRUB_EFI_ABS" ]] || error "Extracted GRUB EFI is empty"
}

patch_alpine_grub_efi() {
    local tmp="$1" release="$2" volid marker offset old_cfg new_cfg old_len new_len patch
    volid="alpine-virt ${release} ${ALPINE_NETBOOT_ARCH}"
    printf -v old_cfg 'search --no-floppy --set=root --label "%s"\nset prefix=($root)/boot/grub\n' "$volid"
    printf -v new_cfg 'search --no-floppy --fs-uuid --set=root %s\nset prefix=($root)%s/grub\n' "$PLAN_EFI_UUID" "$ALPINE_BOOT_DIR_REL"
    old_len=${#old_cfg}; new_len=${#new_cfg}
    (( new_len <= old_len )) || error "Patched GRUB early config is too large"

    marker="search --no-floppy --set=root --label \"${volid}\""
    offset=$(LC_ALL=C grep -a -b -o -F "$marker" "$ALPINE_FREEBSD_GRUB_EFI_ABS" | head -n1 | cut -d: -f1) || true
    [[ "$offset" =~ ^[0-9]+$ ]] || error "Could not locate Alpine GRUB early config"

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
    [[ "$PLAN_STORAGE_MODE" == efi ]] || error "FreeBSD bootstrap requires EFI"
    [[ "$PLAN_EFI_UUID" =~ ^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$ ]] || error "Invalid ESP UUID: $PLAN_EFI_UUID"

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

efi_entry_numbers() {
    local title="${1:-}"
    efibootmgr -v 2>/dev/null | awk -v title="$title" '
        /^[[:space:]]*[+*]?Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {
            if (title == "" || index($0, title)) {
                match($0, /Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)
                print toupper(substr($0, RSTART + 4, 4))
            }
        }
    ' | sort -u
}

efi_bootnext_number() {
    efibootmgr 2>/dev/null | awk -F: '/^BootNext[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
}

efi_bootorder() {
    efibootmgr 2>/dev/null | awk -F: '/^BootOrder[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print toupper($2); exit}'
}

install_freebsd_bootnext_entry() {
    ensure_freebsd_boot_tools
    local before num order bootnext current

    # Do not delete old entries by label: they might be user-managed entries.
    [[ -z "$(efi_entry_numbers "$ALPINE_ENTRY_TITLE")" ]] || \
        error "An existing Alpine reinstall EFI entry needs manual removal"
    order=$(efi_bootorder)
    [[ "$order" =~ ^[0-9A-F]{4}(,[0-9A-F]{4})*$ ]] || \
        error "Could not safely capture the original UEFI BootOrder"

    before=$(efi_entry_numbers)
    efibootmgr -a -c -l "$ALPINE_FREEBSD_GRUB_EFI_ABS" -L "$ALPINE_ENTRY_TITLE" >/dev/null || \
        error "Failed to create UEFI boot entry"
    num=$(comm -13 <(printf '%s\n' "$before") <(efi_entry_numbers) | head -n1)
    [[ "$num" =~ ^[0-9A-F]{4}$ ]] || error "Could not uniquely determine new UEFI boot entry"

    # -c prepends the new entry to BootOrder; preserve the user's original order.
    if ! efibootmgr -o "$order" >/dev/null; then
        efibootmgr -B -b "$num" >/dev/null 2>&1 || true
        error "Failed to restore original UEFI BootOrder"
    fi
    current=$(efi_bootorder)
    [[ "$current" == "$order" ]] || error "UEFI BootOrder changed unexpectedly: $current"
    efibootmgr -n -b "$num" >/dev/null || error "Failed to set BootNext=$num"
    bootnext=$(efi_bootnext_number)
    [[ "$bootnext" == "$num" ]] || error "BootNext verification failed: $bootnext != $num"
    info "BootNext=$num ($ALPINE_ENTRY_TITLE); original BootOrder preserved"
}

check_secure_boot() {
    [[ "$OS" == Linux ]] || return 0
    local value="" status="" kernel_messages=""
    [[ -d /sys/firmware/efi ]] || return 0
    kernel_messages=$(dmesg 2>/dev/null || true)
    if grep -Fqi 'Secure boot enabled' <<<"$kernel_messages"; then
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
    if grep -Eiq '^(SecureBoot|Secure Boot)[[:space:]]+enabled([[:space:]]|$)' <<<"$status"; then
        value=1
    elif grep -Eiq '^(SecureBoot|Secure Boot)[[:space:]]+disabled([[:space:]]|$)' <<<"$status"; then
        value=0
        info "Secure Boot disabled (mokutil)"
    elif [[ "$status" == *"doesn't support Secure Boot"* || "$status" == *"SecureBoot not supported"* ]] &&
         grep -Fqi 'Secure boot disabled' <<<"$kernel_messages"; then
        value=0
        info "Secure Boot unsupported by firmware; kernel confirms disabled"
    fi
    case "$value" in
        0) return 0 ;;
        1) error "UEFI Secure Boot is enabled; unsigned Alpine bootstrap is unsupported" ;;
    esac
    if [[ "${DDIFY_ASSUME_SECURE_BOOT_DISABLED:-0}" == 1 ]]; then
        warn "Secure Boot status is unknown; proceeding only because DDIFY_ASSUME_SECURE_BOOT_DISABLED=1 was set"
        return 0
    fi
    error "Secure Boot status unknown. Verify 'mokutil --sb-state' (install mokutil if needed); if independently confirmed disabled, use DDIFY_ASSUME_SECURE_BOOT_DISABLED=1"
}

prepare_and_boot_alpine_ram() {
    check_secure_boot
    prepare_alpine_paths
    local boot_disk
    if [[ "$OS" == Linux ]]; then
        boot_disk=$(linux_source_to_disk "$PLAN_EFI_PART" || true)
    else
        boot_disk=$(freebsd_provider_to_disk "$PLAN_EFI_PART" || true)
    fi
    [[ -n "$boot_disk" && "$boot_disk" == "$DISK" ]] || \
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

    [[ "$reread_ok" -eq 1 ]] || {
        warn "Kernel could not reread the target partition table."
        lsblk -a -o NAME,PATH,TYPE,SIZE,PARTN,PARTLABEL "$DISK" >&2 2>/dev/null || true
        error "Failed to synchronize the target partition table with the kernel"
    }
}

create_mbr_cidata_partition() {
    local table line num type slot= last_end=0 start size sectors dev
    command -v sfdisk >/dev/null 2>&1 || error "sfdisk is required for MBR CIDATA"
    table=$(sfdisk -d "$DISK") || error "Cannot read target MBR for CIDATA"
    [[ "$table" == *"label: dos"* ]] || error "Target is not an MBR disk"
    if lsblk -nr -o LABEL "$DISK" | awk '$0 == "CIDATA" {found=1} END {exit !found}'; then
        error "Target MBR image already contains a CIDATA volume"
    fi

    local -A used=()
    while IFS= read -r line; do
        [[ "$line" == "$DISK"*' : '* || "$line" == "$DISK"*' :'* ]] || continue
        [[ "$line" =~ start=[[:space:]]*([0-9]+) ]] || error "Malformed MBR partition start"
        start="${BASH_REMATCH[1]}"
        [[ "$line" =~ size=[[:space:]]*([0-9]+) ]] || error "Malformed MBR partition size"
        size="${BASH_REMATCH[1]}"
        [[ "$line" =~ type=[[:space:]]*([[:xdigit:]]+) ]] || error "Malformed MBR partition type"
        type="${BASH_REMATCH[1]}"
        num="${line%%:*}"; num="${num%% *}"; num="${num#"$DISK"}"; num="${num#p}"
        [[ "$num" =~ ^[1-4]$ ]] || error "Extended/logical MBR partitions are unsupported"
        case "${type,,}" in 5|05|f|0f|85) error "Extended MBR partitions are unsupported" ;; esac
        used[$num]=1
        (( start + size - 1 > last_end )) && last_end=$((start + size - 1))
    done <<<"$table"
    for num in 1 2 3 4; do
        if [[ ! -v used[$num] ]]; then slot=$num; break; fi
    done
    [[ -n "$slot" ]] || error "No free MBR primary partition slot for CIDATA"
    start=$((((last_end + 2048) / 2048) * 2048))
    size=32768
    sectors=$(blockdev --getsz "$DISK")
    (( start >= 2048 && start + size + 2048 <= sectors )) ||         error "Not enough trailing MBR space for the 16 MiB CIDATA partition"

    printf 'start=%s, size=%s, type=e\n' "$start" "$size" |         sfdisk --no-reread --no-tell-kernel -N "$slot" "$DISK" >/dev/null ||         error "Could not create MBR CIDATA partition"
    reread_partition_table_strict
    dev=$(partition_device_for_number "$DISK" "$slot")
    ensure_linux_block_node_from_sysfs "$dev" || [[ -b "$dev" ]] || error "MBR CIDATA partition node missing"
    mkfs.vfat -F 16 -n CIDATA "$dev" >/dev/null || error "Cannot format MBR CIDATA"
    printf '%s\n' "$dev"
}

create_nocloud_cidata_partition() {
    [[ "$OS" == "Linux" ]] || error "Creating the standard NoCloud CIDATA partition requires the Linux/Alpine installer environment"
    command -v sgdisk >/dev/null 2>&1 || error "sgdisk is required to create a standard NoCloud CIDATA partition"
    command -v mkfs.vfat >/dev/null 2>&1 || error "mkfs.vfat is required to create a standard NoCloud CIDATA partition"

    if ! sgdisk -p "$DISK" >/dev/null 2>&1; then
        error "Target image does not expose a usable GPT; refusing non-standard EFI:/nocloud injection"
    fi

    if [[ "${QCOW_PARTITION_TABLE:-gpt}" == dos ]]; then
        create_mbr_cidata_partition
        return
    fi

    local existing_cidata seed_part seed_matches=()
    existing_cidata=$(lsblk -lnpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk '$2=="CIDATA" {print $1}')
    [[ -z "$existing_cidata" ]] || error "Image already contains a CIDATA partition; refusing to format an ambiguous seed: $existing_cidata"

    info "Creating temporary 16 MiB NoCloud CIDATA seed partition..."
    sgdisk -e "$DISK" >/dev/null || error "Failed to relocate GPT backup header on $DISK"
    sgdisk -n 0:0:+16M -t 0:0700 -c 0:CIDATA "$DISK" >/dev/null || \
        error "Failed to create CIDATA partition; target disk may not have enough unallocated GPT space"
    reread_partition_table_strict
    sleep 1

    mapfile -t seed_matches < <(lsblk -lnpo NAME,PARTLABEL "$DISK" 2>/dev/null | awk '$2=="CIDATA" {print $1}')
    ((${#seed_matches[@]} == 1)) || error "Expected exactly one newly created CIDATA partition; found ${#seed_matches[@]}"
    seed_part="${seed_matches[0]}"
    [[ -b "$seed_part" ]] || error "New CIDATA partition is not a block device: $seed_part"
    mkfs.vfat -F 16 -n CIDATA "$seed_part" >/dev/null || error "Failed to format CIDATA partition: $seed_part"
    printf '%s\n' "$seed_part"
}

TEMP_STAGE_SIZE_BYTES=$((3072 * 1024 * 1024))
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

    [[ -n "$devpath" ]] || return 1
    [[ -b "$devpath" ]] && return 0

    name="${devpath#/dev/}"
    sysdev="/sys/class/block/$name/dev"

    [[ -r "$sysdev" ]] || return 1

    IFS=: read -r maj min <"$sysdev"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1

    if [[ -e "$devpath" && ! -b "$devpath" ]]; then
        rm -f "$devpath"
    fi

    mknod "$devpath" b "$maj" "$min" || return 1
    chmod 0600 "$devpath" 2>/dev/null || true

    [[ -b "$devpath" ]]
}

reset_disk_for_staging() {
    [[ -z "${DISK_ID_PTUUID:-}" || "$DISK_ID_PTUUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
        error "Invalid saved GPT GUID; refusing destructive write"
    wipefs -a "$DISK" >/dev/null 2>&1 || true
    sgdisk -Z "$DISK" >/dev/null 2>&1 || true
    partx -d "$DISK" >/dev/null 2>&1 || true
    blockdev --rereadpt "$DISK" >/dev/null 2>&1 || true
    mdev -s 2>/dev/null || true

    sgdisk -o "$DISK" >/dev/null || error "Failed to create temporary GPT"
    if [[ -n "${DISK_ID_PTUUID:-}" ]]; then
        sgdisk -U "$DISK_ID_PTUUID" "$DISK" >/dev/null || error "Failed to preserve target GPT identity"
    fi
    sgdisk -n "${TEMP_STAGE_PART_NUM}:-3072M:0" -t "${TEMP_STAGE_PART_NUM}:8300" \
        -c "${TEMP_STAGE_PART_NUM}:${TEMP_STAGE_LABEL}" "$DISK" >/dev/null || error "Failed to create staging partition"
    reread_partition_table_strict
}

wait_for_stage_partition() {
    local i
    TEMP_STAGE_PART=$(partition_device_for_number "$DISK" "$TEMP_STAGE_PART_NUM")
    for i in 1 2 3 4 5 6 7 8; do
        [[ -b "$TEMP_STAGE_PART" ]] && return
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
    [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || error "Could not read staging geometry"

    TEMP_STAGE_START_SECTOR="$first"
    TEMP_STAGE_START_BYTES=$((first * TEMP_STAGE_SECTOR_SIZE))
    actual=$(((last - first + 1) * TEMP_STAGE_SECTOR_SIZE))
    (( actual >= TEMP_STAGE_SIZE_BYTES - 2 * 1024 * 1024 )) || error "Staging partition is smaller than 3 GiB"
    TEMP_STAGE_LAST_SECTOR="$last"
}

prepare_fixed_temp_staging_partition() {
    local disk_size min_remaining=$((2 * 1024 * 1024 * 1024))
    [[ "$OS" == Linux ]] || error "Staging requires Alpine/Linux"
    disk_size=$(get_disk_size_bytes "$DISK")
    (( disk_size > TEMP_STAGE_SIZE_BYTES + min_remaining )) || error "Target disk is too small for 3 GiB staging"

    info "Preparing 3 GiB staging partition at the end of $DISK"
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
    if [[ -n "${QCOW_NBD_DEV:-}" ]]; then
        qemu-nbd --disconnect "$QCOW_NBD_DEV" >/dev/null 2>&1 || true
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
        [[ -b "$dev" ]] || continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [[ "$size" == "0" ]] || continue
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
    [[ "$QCOW_VIRTUAL_SIZE" =~ ^[0-9]+$ && "$QCOW_VIRTUAL_SIZE" -gt 0 ]] || \
        error "Could not determine qcow2 virtual size"

    connect_qcow_readonly_nbd "$img"
    nbd="$QCOW_NBD_DEV"

    local nbd_virtual_size
    nbd_virtual_size=$(blockdev --getsize64 "$nbd" 2>/dev/null || true)
    [[ "$nbd_virtual_size" =~ ^[0-9]+$ && "$nbd_virtual_size" -gt 0 ]] ||         error "Could not determine qcow2 guest-visible size through qemu-nbd"
    if [[ "$QCOW_VIRTUAL_SIZE" != "$nbd_virtual_size" ]]; then
        warn "qemu-img reported ${QCOW_VIRTUAL_SIZE} bytes, but qemu-nbd exposes ${nbd_virtual_size} bytes; using qemu-nbd size."
    fi
    QCOW_VIRTUAL_SIZE="$nbd_virtual_size"

    QCOW_PARTITION_TABLE=$(blkid -p -s PTTYPE -o value "$nbd" 2>/dev/null || true)
    case "$QCOW_PARTITION_TABLE" in
        gpt) ;;
        dos)
            [[ "$TARGET_OS" != freebsd && ! -d /sys/firmware/efi ]] ||                 error "MBR images are supported for Linux BIOS boot only"
            local dump line num start size type count=0
            dump=$(sfdisk -d "$nbd") || error "Cannot inspect MBR image"
            [[ "$dump" == *"label: dos"* ]] || error "Malformed MBR image"
            QCOW_MBR_ID=$(sed -n 's/^label-id: //p' <<<"$dump" | head -n1)
            [[ "$QCOW_MBR_ID" =~ ^0x[[:xdigit:]]{8}$ ]] || error "Invalid MBR disk signature"
            max_end=0
            while IFS= read -r line; do
                [[ "$line" == "$nbd"*' : '* || "$line" == "$nbd"*' :'* ]] || continue
                [[ "$line" =~ start=[[:space:]]*([0-9]+) ]] || error "Invalid MBR start sector"
                start="${BASH_REMATCH[1]}"
                [[ "$line" =~ size=[[:space:]]*([0-9]+) ]] || error "Invalid MBR partition length"
                size="${BASH_REMATCH[1]}"
                [[ "$line" =~ type=[[:space:]]*([[:xdigit:]]+) ]] || error "Invalid MBR partition type"
                type="${BASH_REMATCH[1]}"
                num="${line%%:*}"; num="${num%% *}"; num="${num#"$nbd"}"; num="${num#p}"
                [[ "$num" =~ ^[1-4]$ ]] || error "MBR logical partitions are not supported"
                case "${type,,}" in 5|05|f|0f|85) error "MBR extended partitions are not supported" ;; esac
                (( ++count <= 3 )) || error "MBR image has no free primary slot for CIDATA"
                (( size > 0 && start >= 2048 && start + size <= QCOW_VIRTUAL_SIZE / 512 )) ||                     error "Invalid MBR partition boundaries"
                (( start + size - 1 > max_end )) && max_end=$((start + size - 1))
            done <<<"$dump"
            (( count > 0 )) || error "MBR image contains no primary partitions"
            sfdisk --verify "$nbd" >/dev/null || error "Inconsistent MBR partition layout"
            sector_size=$(blockdev --getss "$nbd")
            [[ "$sector_size" == 512 && "$sector_size" == "$(blockdev --getss "$DISK")" ]] ||                 error "MBR image requires matching 512-byte logical sectors"
            QCOW_MAX_PART_END_SECTOR="$max_end"
            QCOW_MAX_PART_END_BYTES=$(((max_end + 1) * sector_size))
            (( QCOW_MAX_PART_END_BYTES + 8 * 1024 * 1024 <= TEMP_STAGE_START_BYTES )) ||                 error "MBR image partitions cross the staging area; MBR shrinking is unsupported"
            cleanup_qcow_nbd
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

    QCOW_GPT_GUID=$(printf '%s\n' "$table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    [[ "$QCOW_GPT_GUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || \
        error "Target image has no valid GPT disk GUID"

    sector_size=$(blockdev --getss "$nbd" 2>/dev/null || true)
    [[ "$sector_size" =~ ^[0-9]+$ && "$sector_size" -gt 0 ]] || \
        error "Could not determine qcow2 logical sector size"
    [[ "$sector_size" == "$(blockdev --getss "$DISK")" ]] || error "Image/target logical sector-size mismatch"

    max_end=$(printf '%s\n' "$table" | awk '
        /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {
            if ($3 + 0 > max + 0) max=$3
        }
        END { if (max != "") print max }
    ')
    [[ "$max_end" =~ ^[0-9]+$ ]] || error "Could not determine the last partition sector inside qcow2"

    QCOW_MAX_PART_END_SECTOR="$max_end"
    QCOW_MAX_PART_END_BYTES=$(((max_end + 1) * sector_size))

    cleanup_qcow_nbd

    info "qcow2 virtual size:          ${QCOW_VIRTUAL_SIZE} bytes"
    info "qcow2 last partition end:    ${QCOW_MAX_PART_END_BYTES} bytes"
    info "temporary partition begins:  ${TEMP_STAGE_START_BYTES} bytes"

    QCOW_PARTITION_CROSSES_STAGE=0

    # A cloud image may deliberately describe a GPT/LVM layout much larger than
    # the qcow2 payload stored on disk. Do not reject it merely because the GPT
    # sparse-shadow path so the source is first copied into RAM/zram, resized
    if [[ "$QCOW_MAX_PART_END_BYTES" -gt $((TEMP_STAGE_START_BYTES - 8 * 1024 * 1024)) ]]; then
        QCOW_PARTITION_CROSSES_STAGE=1
        warn "qcow2 GPT layout reaches the mandatory 3 GiB staging area."
        warn "Using sparse RAM/zram shadow mode to avoid self-overwriting the live staging source."
    fi

    # device. If qemu-img reported otherwise, treat the GPT extent as the minimum
    if [[ "$QCOW_VIRTUAL_SIZE" -lt "$QCOW_MAX_PART_END_BYTES" ]]; then
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
    curl -fsSL --proto '=https' --proto-redir '=https' "$url" -o "$manifest" ||
        error "Could not retrieve official checksum manifest: $url"
    expected=$(awk -v file="$name" -v algorithm="$algo" '
        $1 == algorithm && $2 == "(" file ")" && $3 == "=" { print $4; exit }
        $2 == file || $2 == "*" file { print $1; exit }
    ' "$manifest")
    case "$algo:$expected" in
        SHA256:*) [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] ;;
        SHA512:*) [[ "$expected" =~ ^[[:xdigit:]]{128}$ ]] ;;
    esac || error "Official checksum manifest lacks a valid entry for $name"
    IMAGE_HASH_ALGO="${algo,,}"
    IMAGE_HASH_EXPECTED="${expected,,}"
}

preflight_target_image_in_alpine() {
    [[ "$IMG_URL" == https://* ]] || error "Target image must use HTTPS"
    if [[ "${IMAGE_BUILTIN:-0}" == 1 ]]; then
        image_checksum_from_official_manifest
    else
        IMAGE_HASH_EXPECTED="" IMAGE_HASH_ALGO=""
        warn "Custom --img has no publisher-verified checksum; partition layout will still be validated"
    fi
    info "Checking target image URL before modifying the disk"
    curl -fsSIL --connect-timeout 15 --max-time 60 --proto '=https' --proto-redir '=https' "$IMG_URL" >/dev/null || \
        error "Target image URL is not reachable before disk modification"
    local remote_size
    remote_size=$(http_content_length "$IMG_URL" || true)
    if [[ "$remote_size" =~ ^[0-9]+$ && "$remote_size" -gt $((1450 * 1024 * 1024)) ]]; then
        error "Image download size exceeds the staging policy before disk modification"
    fi
    preflight_image_geometry
}

download_target_image_in_alpine() {
    local dst="$1" tmp="${1}.part.$$" remote_size allocated digest= hash_pid= fifo=

    rm -f "$tmp"
    [[ "$IMG_URL" == https://* ]] || error "Target image must use HTTPS"
    [[ -n "${IMAGE_HASH_ALGO:-}" || -z "${IMAGE_HASH_EXPECTED:-}" ]] || error "Missing image checksum algorithm"
    info "Downloading target image onto the mandatory 3 GiB staging partition: $IMG_URL"

    remote_size=$(http_content_length "$IMG_URL" || true)
    if [[ "$remote_size" =~ ^[0-9]+$ && "$remote_size" -gt $((1450 * 1024 * 1024)) ]]; then
        error "Remote image payload is too large for the fixed 3 GiB staging partition: ${remote_size} bytes"
    fi

    if [[ "$IMG_URL" == *.xz ]]; then
        if [[ -n "$IMAGE_HASH_EXPECTED" ]]; then
            fifo="$INSTALL_TMPDIR/image-checksum.fifo"
            mkfifo "$fifo" || error "Could not create image checksum pipe"
            "${IMAGE_HASH_ALGO}sum" <"$fifo" >"$INSTALL_TMPDIR/image-hash" &
            hash_pid=$!
            if ! curl -fsSL --proto '=https' --proto-redir '=https' "$IMG_URL" |
                    tee "$fifo" | xz -dc >"$tmp"; then
                rm -f "$tmp" "$fifo"
                wait "$hash_pid" || true
                error "Failed to download/decompress target image"
            fi
            wait "$hash_pid" || error "Failed to calculate compressed image hash"
            rm -f "$fifo"
            digest=$(awk '{print $1; exit}' "$INSTALL_TMPDIR/image-hash")
        else
            curl -fsSL --proto '=https' --proto-redir '=https' "$IMG_URL" |
                xz -dc >"$tmp" || error "Failed to download/decompress target image"
        fi
    else
        curl -fsSL --proto '=https' --proto-redir '=https' "$IMG_URL" -o "$tmp" ||
            error "Failed to download target image"
        [[ -z "$IMAGE_HASH_EXPECTED" ]] ||
            digest=$("${IMAGE_HASH_ALGO}sum" "$tmp" | awk '{print $1}')
    fi
    if [[ -n "$IMAGE_HASH_EXPECTED" ]]; then
        [[ "${digest,,}" == "$IMAGE_HASH_EXPECTED" ]] || error "Official image checksum mismatch"
        info "Official ${IMAGE_HASH_ALGO^^} checksum verified (HTTPS manifest; signature not checked)"
    fi

    mv -f "$tmp" "$dst"
    sync
    allocated=$(du -B1 "$dst" 2>/dev/null | awk '{print $1; exit}' || true)
    info "Target qcow2 is ready on staging partition: $dst"
    [[ -n "$allocated" ]] && info "qcow2 allocated staging space: ${allocated} bytes"
    df -h "$TEMP_STAGE_MNT" || true
}

get_qcow_virtual_size_bytes() {
    local path="$1"

    qemu-img info --output=json "$path" 2>/dev/null | \
        sed -n 's/^[[:space:]]*"virtual-size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | \
        head -n1
}

connect_raw_rw_nbd() {
    local img="$1" n dev size

    command -v qemu-nbd >/dev/null 2>&1 || error "qemu-nbd is required for sparse-shadow preparation"
    modprobe nbd max_part=64 >/dev/null 2>&1 || error "Could not load nbd kernel module"
    mdev -s 2>/dev/null || true

    for n in $(seq 0 15); do
        dev="/dev/nbd$n"
        [[ -b "$dev" ]] || continue
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        [[ "$size" == "0" ]] || continue

        if qemu-nbd --connect="$dev" --format=raw "$img" >/dev/null 2>&1; then
            QCOW_NBD_DEV="$dev"
            sleep 1
            command -v partx >/dev/null 2>&1 && {
                partx -u "$dev" >/dev/null 2>&1 || partx -a "$dev" >/dev/null 2>&1 || true
            }
            mdev -s 2>/dev/null || true
            return 0
        fi
    done

    error "Could not allocate a free NBD device for sparse-shadow preparation"
}

shadow_last_partition() {
    local nbd="$1" line best_end=0 pnum pstart pend pcode
    SHADOW_PART_NUM="" SHADOW_PART_START="" SHADOW_PART_END="" SHADOW_PART_CODE=""

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([[:xdigit:]]{4})([[:space:]]|$) ]] || continue
        pnum="${BASH_REMATCH[1]}"
        pstart="${BASH_REMATCH[2]}"
        pend="${BASH_REMATCH[3]}"
        pcode="${BASH_REMATCH[4]^^}"
        (( pend > best_end )) || continue
        best_end="$pend"
        SHADOW_PART_NUM="$pnum"
        SHADOW_PART_START="$pstart"
        SHADOW_PART_END="$pend"
        SHADOW_PART_CODE="$pcode"
    done < <(sgdisk -p "$nbd" 2>/dev/null)

    [[ -n "$SHADOW_PART_NUM" ]] || error "Could not identify final GPT partition in sparse shadow"
    case "$SHADOW_PART_CODE" in
        EF00|EF02|8200|A502) error "Cannot shrink a trailing EFI/BIOS/swap partition" ;;
        FFFF) error "Cannot shrink a partition with an unknown GPT type" ;;
    esac
}
shadow_partition_node() {
    local nbd="$1" num="$2" dev i
    dev=$(partition_device_for_number "$nbd" "$num")

    for i in 1 2 3 4 5; do
        [[ -b "$dev" ]] && { echo "$dev"; return; }
        partx -u "$nbd" >/dev/null 2>&1 || true
        mdev -s 2>/dev/null || true
        ensure_linux_block_node_from_sysfs "$dev" && { echo "$dev"; return; }
        sleep 1
    done
    error "Could not create sparse-shadow partition node: $dev"
}

shadow_resize_lvm() {
    local dev="$1" bytes="$2"
    pvs --noheadings -o pv_name "$dev" 2>/dev/null | grep -Fq "$dev" || return 1
    info "Shrinking LVM PV to ${bytes} bytes"
    pvresize --yes --setphysicalvolumesize "${bytes}B" "$dev" || \
        error "LVM allocated extents do not fit on the target disk"
    return 0
}

shadow_resize_xfs() {
    local dev="$1" bytes="$2" block_size blocks fs_bytes
    block_size=$(xfs_db -r -c 'sb 0' -c 'p blocksize' "$dev" 2>/dev/null | awk -F'= *' '/blocksize =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
    blocks=$(xfs_db -r -c 'sb 0' -c 'p dblocks' "$dev" 2>/dev/null | awk -F'= *' '/dblocks =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')
    [[ "$block_size" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ ]] || error "Could not read XFS size on $dev"
    fs_bytes=$((block_size * blocks))
    (( fs_bytes <= bytes )) || error "XFS uses ${fs_bytes} bytes and cannot be shrunk to ${bytes} bytes"
    info "XFS already fits inside the new partition boundary"
}

shadow_resize_ext() {
    local dev="$1" bytes="$2" block_size blocks fs_bytes target_blocks rc=0
    block_size=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Block size:/ {print $2; exit}')
    blocks=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Block count:/ {print $2; exit}')
    [[ "$block_size" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ ]] || error "Could not read ext filesystem size on $dev"
    fs_bytes=$((block_size * blocks))
    (( fs_bytes > bytes )) || { info "ext filesystem already fits inside the new partition boundary"; return; }

    target_blocks=$((bytes / block_size - 256))
    (( target_blocks > 0 )) || error "Target partition is too small for ext filesystem"
    e2fsck -f -p "$dev" >/dev/null 2>&1 || rc=$?
    (( rc <= 1 )) || error "e2fsck failed before ext shrink (rc=$rc)"
    info "Shrinking ext filesystem to ${target_blocks} blocks"
    resize2fs "$dev" "$target_blocks" >/dev/null || error "resize2fs failed"
}

shadow_resize_payload() {
    local dev="$1" bytes="$2" type
    shadow_resize_lvm "$dev" "$bytes" && return

    type=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)
    info "Final partition content: ${type:-unknown} (GPT type $SHADOW_PART_CODE)"
    case "$type" in
        xfs)              shadow_resize_xfs "$dev" "$bytes" ;;
        ext2|ext3|ext4)   shadow_resize_ext "$dev" "$bytes" ;;
        *) error "Cannot safely shrink final partition content '${type:-unknown}'" ;;
    esac
}

shadow_resize_gpt() {
    local nbd="$1" num="$2" start="$3" end="$4" info_text type_guid unique_guid attrs name
    info_text=$(sgdisk -i "$num" "$nbd" 2>/dev/null) || error "Failed to inspect GPT partition $num"
    type_guid=$(awk '/Partition GUID code:/ {print $4; exit}' <<<"$info_text")
    unique_guid=$(awk '/Partition unique GUID:/ {print $4; exit}' <<<"$info_text")
    attrs=$(awk '/Attribute flags:/ {print $3; exit}' <<<"$info_text")
    name=$(sed -n "s/^Partition name: '\(.*\)'$/\1/p" <<<"$info_text" | head -n1)

    sgdisk -d "$num" "$nbd" >/dev/null || error "Failed to delete GPT partition $num"
    sgdisk -n "${num}:${start}:${end}" "$nbd" >/dev/null || error "Failed to recreate GPT partition $num"
    sgdisk -t "${num}:${type_guid}" "$nbd" >/dev/null || error "Failed to restore GPT type"
    [[ -z "$unique_guid" ]] || sgdisk -u "${num}:${unique_guid}" "$nbd" >/dev/null || error "Failed to restore PARTUUID"
    [[ -z "$name" ]] || sgdisk -c "${num}:${name}" "$nbd" >/dev/null || error "Failed to restore partition name"
    [[ -z "$attrs" || "$attrs" == 0000000000000000 ]] || sgdisk -A "${num}:=:${attrs}" "$nbd" >/dev/null || error "Failed to restore GPT attributes"
}

prepare_sparse_shadow_for_target() {
    local img="$1" shadow="$2" nbd sector target_sector disk_bytes total reserve target_end partdev part_bytes allocated

    rm -f "$shadow"
    local available_bytes tmpfs_free image_bytes
    available_bytes=$(awk '/^MemAvailable:/ {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo)
    tmpfs_free=$(df -B1 --output=avail /run/reinstall-work | awk 'NR==2 {print $1; exit}')
    image_bytes=$(du -B1 "$img" | awk '{print $1; exit}')
    [[ "$available_bytes" =~ ^[0-9]+$ && "$tmpfs_free" =~ ^[0-9]+$ && "$image_bytes" =~ ^[0-9]+$ ]] || \
        error "Could not evaluate available sparse-shadow memory"
    (( available_bytes >= 201326592 )) || \
        error "Less than 192 MiB MemAvailable before sparse-shadow conversion"
    (( tmpfs_free >= image_bytes + 134217728 )) || \
        error "Sparse-shadow tmpfs headroom is lower than the compressed QCOW2 allocation; refusing high-risk conversion"
    info "Creating bounded sparse RAM/zram shadow"
    qemu-img convert -p -S 4k -f qcow2 -O raw "$img" "$shadow" &
    local convert_pid=$! available_kb pressure=0 free_now
    while kill -0 "$convert_pid" 2>/dev/null; do
        available_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
        free_now=$(df -B1 --output=avail /run/reinstall-work | awk 'NR==2 {print $1; exit}')
        if [[ ! "$available_kb" =~ ^[0-9]+$ || ! "$free_now" =~ ^[0-9]+$ ]] || \
           (( available_kb < 98304 || free_now < 134217728 )); then
            pressure=1
            kill "$convert_pid" 2>/dev/null || true
            break
        fi
        sleep 1
    done
    if ! wait "$convert_pid" || (( pressure )); then
        error "Insufficient RAM/zram for sparse-shadow; refusing an unsafe partial write"
    fi
    allocated=$(du -B1 "$shadow" 2>/dev/null | awk '{print $1; exit}')
    [[ "$allocated" =~ ^[0-9]+$ ]] || error "Cannot verify completed sparse-shadow allocation"
    qemu-img compare -f qcow2 -F raw "$img" "$shadow" >/dev/null || \
        error "Sparse RAW shadow does not match source QCOW2; refusing write"
    info "Sparse shadow: logical=$(stat -c %s "$shadow") allocated=${allocated} bytes"

    connect_raw_rw_nbd "$shadow"
    nbd="$QCOW_NBD_DEV"
    sector=$(blockdev --getss "$nbd")
    target_sector=$(blockdev --getss "$DISK")
    [[ "$sector" == "$target_sector" ]] || error "Image/target sector-size mismatch"

    disk_bytes=$(get_disk_size_bytes "$DISK")
    total=$((disk_bytes / sector))
    reserve=$(((32 * 1024 * 1024 + sector - 1) / sector))
    local image_sectors last_usable gpt_tail
    image_sectors=$(($(blockdev --getsize64 "$nbd") / sector))
    last_usable=$(sgdisk -p "$nbd" | awk '/last usable sector is/ {print $NF; exit}')
    [[ "$last_usable" =~ ^[0-9]+$ ]] || error "Cannot determine GPT last usable sector"
    gpt_tail=$((image_sectors - last_usable))
    (( gpt_tail >= 2 && gpt_tail <= 1024 )) || error "Invalid source GPT tail geometry"
    target_end=$((total - gpt_tail - reserve))
    (( target_end > 2048 )) || error "Target disk is too small for GPT + CIDATA"

    shadow_last_partition "$nbd"
    (( SHADOW_PART_END > target_end )) || { cleanup_qcow_nbd; return; }

    info "Final partition: $SHADOW_PART_NUM sectors $SHADOW_PART_START..$SHADOW_PART_END -> $target_end"
    partdev=$(shadow_partition_node "$nbd" "$SHADOW_PART_NUM")
    part_bytes=$(((target_end - SHADOW_PART_START + 1) * sector))
    (( part_bytes > 0 )) || error "Target disk ends before the final image partition starts"

    shadow_resize_payload "$partdev" "$part_bytes"
    shadow_resize_gpt "$nbd" "$SHADOW_PART_NUM" "$SHADOW_PART_START" "$target_end"
    sync
    cleanup_qcow_nbd
    info "Sparse-shadow payload and GPT now fit the target disk"
}

write_sparse_shadow_to_target_after_releasing_stage() {
    local shadow="$1" disk_bytes

    disk_bytes=$(get_disk_size_bytes "$DISK" || true)
    [[ "$disk_bytes" =~ ^[0-9]+$ && "$disk_bytes" -gt 0 ]] || \
        error "Could not determine target disk size for sparse-shadow write"

    # A sparse file may legitimately contain holes, but must cover the entire disk.
    truncate -s "$disk_bytes" "$shadow" || error "Failed to size sparse shadow"
    [[ "$(stat -c %s "$shadow")" == "$disk_bytes" ]] || error "Sparse shadow is shorter than the target disk"

    release_temp_staging_partition
    TEMP_STAGE_RELEASED=1
    sync

    info "Writing sparse shadow to the target disk after releasing the 3 GiB staging partition..."
    info "Copy length: ${disk_bytes} bytes"

    # A sparse copy is safe only after the entire destination was zeroed.
    # BLKZEROOUT guarantees zeros; plain blkdiscard and dd conv=sparse do not.
    if command -v blkdiscard >/dev/null 2>&1 && blkdiscard --zeroout "$DISK"; then
        info "Destination zeroed; transferring sparse data extents"
        qemu-img convert -p -n --target-is-zero -S 4k -f raw -O raw "$shadow" "$DISK" || \
            error "Sparse conversion failed after target zeroing"
    else
        info "Zeroout unavailable; writing every byte to avoid stale target data"
        dd if="$shadow" of="$DISK" bs=16M iflag=count_bytes count="$disk_bytes" \
            status=progress conv=fsync || error "Failed to write sparse shadow to target disk"
    fi

    sync
    rm -f "$shadow"
}

write_qcow_without_overwriting_staging() {
    local img="$1" bs_arg count_arg shadow

    [[ -n "$TEMP_STAGE_START_BYTES" ]] || error "Temporary staging boundary is unknown"
    TEMP_STAGE_RELEASED=0

    if [[ "${QCOW_PARTITION_CROSSES_STAGE:-0}" == "1" ]]; then
        shadow="/run/reinstall-work/target-shadow.raw"
        prepare_sparse_shadow_for_target "$img" "$shadow"
        write_sparse_shadow_to_target_after_releasing_stage "$shadow"
        return 0
    fi

    if [[ "$QCOW_VIRTUAL_SIZE" -le "$TEMP_STAGE_START_BYTES" ]]; then
        info "qcow2 virtual disk ends before the staging partition; converting the whole image."
        qemu-img convert -p -n -S 0 -f qcow2 -O raw "$img" "$DISK" || \
            error "qemu-img failed while writing the target disk"
        return 0
    fi

    # The image virtual disk extends beyond the staging boundary, but its GPT
    # prefix; trailing free space and the source backup GPT are intentionally
    # omitted. The backup GPT is rebuilt after staging has been released.
    if (( TEMP_STAGE_START_BYTES % (4 * 1024 * 1024) == 0 )); then
        bs_arg="4M"
        count_arg=$((TEMP_STAGE_START_BYTES / (4 * 1024 * 1024)))
    elif (( TEMP_STAGE_START_BYTES % (1024 * 1024) == 0 )); then
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

    # The on-disk primary GPT has already been replaced by the target image, but
    # those stale mappings before manipulating the target GPT. This avoids
    if command -v partx >/dev/null 2>&1; then
        if ! partx -d "$DISK" >/dev/null 2>&1; then
            warn "Could not immediately delete stale staging partition mappings with partx; continuing with GPT repair."
        fi
    fi

    command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true

    if [[ -n "$old_stage" ]]; then
        info "Released temporary staging partition: $old_stage"
    fi

    TEMP_STAGE_PART=""
}

find_last_growable_gpt_partition() {
    local line num end code best_num="" best_code="" best_end=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([[:xdigit:]]{4})([[:space:]]|$) ]] || continue
        num="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[3]}"
        code="${BASH_REMATCH[4]^^}"
        if (( end > best_end )); then
            best_end="$end"
            best_num="$num"
            best_code="$code"
        fi
    done < <(sgdisk -p "$DISK" 2>/dev/null || true)

    [[ -n "$best_num" ]] || return 1
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
        [[ "$rc" == 2 ]] || error "Could not identify a safe final GPT data partition to expand"
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

    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && -n "$type_guid" ]] || \
        error "Could not preserve partition metadata while preparing expansion"

    sector_size=$(blockdev --getss "$DISK")
    reserve_bytes=$((32 * 1024 * 1024))
    reserve_sectors=$(((reserve_bytes + sector_size - 1) / sector_size))
    last_usable=$(sgdisk -p "$DISK" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p' | head -n1)
    [[ "$last_usable" =~ ^[0-9]+$ && "$last_usable" -gt "$end" ]] || \
        error "Could not identify safe trailing GPT space after the final data partition"
    new_end=$((last_usable - reserve_sectors))
    if [[ "$new_end" -eq "$end" ]]; then
        info "Target partition $partnum already ends at the CIDATA-safe boundary."
        return 0
    fi
    if [[ "$new_end" -lt "$end" ]]; then
        error "Target partition $partnum still extends beyond the CIDATA-safe boundary after image preparation; refusing an unsafe blind shrink"
    fi

    info "Expanding target GPT partition $partnum from end sector $end to $new_end; reserving temporary CIDATA alignment space."
    sgdisk -d "$partnum" "$DISK" >/dev/null || error "Failed to delete partition $partnum for boundary-only resize"
    sgdisk -n "${partnum}:${start}:${new_end}" "$DISK" >/dev/null || error "Failed to recreate expanded partition $partnum"
    sgdisk -t "${partnum}:${type_guid}" "$DISK" >/dev/null || error "Failed to restore GPT type for partition $partnum"
    [[ -z "$unique_guid" ]] || sgdisk -u "${partnum}:${unique_guid}" "$DISK" >/dev/null || error "Failed to restore PARTUUID for partition $partnum"
    [[ -z "$name" ]] || sgdisk -c "${partnum}:${name}" "$DISK" >/dev/null || error "Failed to restore GPT name for partition $partnum"
    if [[ -n "$attrs" && "$attrs" != "0000000000000000" ]]; then
        sgdisk -A "${partnum}:=:${attrs}" "$DISK" >/dev/null || \
            error "Failed to restore GPT attributes for partition $partnum"
    fi

    reread_partition_table_strict
    sleep 1
}

cleanup_install_stage() {
    cleanup_qcow_nbd
    is_mountpoint "$TEMP_STAGE_MNT" && umount "$TEMP_STAGE_MNT" 2>/dev/null || true
    [[ -z "${INSTALL_TMPDIR:-}" ]] || rm -rf "$INSTALL_TMPDIR" 2>/dev/null || true
}

installer_workspace() {
    is_mountpoint /run/reinstall-work || error "Alpine work tmpfs is not mounted"
    INSTALL_TMPDIR=$(mktemp -d /run/reinstall-work/install.XXXXXX)
    trap cleanup_install_stage EXIT
}

installer_stage_optional_inputs() {
    [[ -n "${FRPC_TOML:-}" && "$FRPC_TOML" =~ ^https?:// ]] || return 0
    local dst="$INSTALL_TMPDIR/frpc.toml"
    [[ "$FRPC_TOML" == https://* ]] || error "FRPC config URL must use HTTPS"
    info "Downloading FRPC config"
    http_download "$FRPC_TOML" "$dst" || error "Failed to download FRPC config"
    FRPC_TOML="$dst"
}

confirm_destructive_write() {
    echo
    echo "WARNING: $DISK will be repartitioned. ALL DATA WILL BE LOST."
    [[ "$AUTO_YES" == 1 ]] && [[ -n "${DISK_ID_WWN:-}${DISK_ID_SERIAL:-}${DISK_ID_PTUUID:-}${DISK_ID_MBR_ID:-}" ]] && return 0
    read -r -p "Type yes to continue: " ans
    case "$ans" in y|Y|yes|YES|Yes) return ;; *) error "Cancelled" ;; esac
}

installer_write_image() {
    unmount_target_disk_filesystems "$DISK"
    confirm_destructive_write
    prepare_fixed_temp_staging_partition

    IMG_QCOW="$TEMP_STAGE_MNT/image.qcow2"
    download_target_image_in_alpine "$IMG_QCOW"
    inspect_qcow_partition_layout "$IMG_QCOW"
    write_qcow_without_overwriting_staging "$IMG_QCOW"

    [[ "${TEMP_STAGE_RELEASED:-0}" == 1 ]] || release_temp_staging_partition
    sync
    if [[ "$QCOW_PARTITION_TABLE" == dos ]]; then
        local written_id
        local disk_sectors
        disk_sectors=$(blockdev --getsz "$DISK")
        (( disk_sectors > 2048 )) || error "Invalid target sector count"
        dd if=/dev/zero of="$DISK" bs=512 seek=$((disk_sectors - 2048)) count=2048             conv=notrunc,fsync status=none || error "Failed to clear obsolete backup GPT at disk tail"
        written_id=$(sfdisk --disk-id "$DISK" 2>/dev/null || true)
        [[ "${written_id,,}" == "${QCOW_MBR_ID,,}" ]] || error "Written MBR signature differs from source image"
        [[ "$(blkid -p -s PTTYPE -o value "$DISK" 2>/dev/null || true)" == dos ]] ||             error "Written target does not expose the expected MBR"
        sfdisk --verify "$DISK" >/dev/null || error "Written MBR partition layout is inconsistent"
        return 0
    fi
    local written_table written_guid
    written_table=$(sgdisk -p "$DISK" 2>&1) || error "Target GPT unreadable after image write: $written_table"
    written_guid=$(printf '%s\n' "$written_table" | awk '/^Disk identifier \(GUID\):/ {print $4; exit}')
    [[ "${written_guid,,}" == "${QCOW_GPT_GUID,,}" ]] || \
        error "Target GPT identity differs from verified image; refusing backup GPT repair"
    [[ "$written_table" != *REINSTALL_TMP* ]] || error "Staging GPT survived image write; refusing GPT repair"
    sgdisk -e "$DISK" >/dev/null || error "Failed to repair target GPT"
    grow_last_partition_reserving_cidata
}

installer_write_seed() {
    local part partuuid mnt="$INSTALL_TMPDIR/cidata"
    part=$(create_nocloud_cidata_partition)
    partuuid=$(lsblk -d -n -r -o PARTUUID "$part" 2>/dev/null | head -n1)
    if [[ "$QCOW_PARTITION_TABLE" == dos ]]; then
        [[ "$partuuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{2}$ ]] || error "Invalid MBR CIDATA PARTUUID"
    else
        [[ "$partuuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||             error "Failed to read newly created CIDATA PARTUUID"
    fi
    mkdir -p "$mnt"
    mount -t vfat "$part" "$mnt" || error "Failed to mount CIDATA partition $part"

    [[ -n "$FRPC_TOML" && -f "$FRPC_TOML" ]] && FRPC_PRESENT=1 || FRPC_PRESENT=""
    write_nocloud_seed "$TARGET_OS" "$mnt/meta-data" "$mnt/user-data" "$partuuid"
    sync
    umount "$mnt" || error "Failed to unmount CIDATA"
}

print_install_summary() {
    local key
    echo
    echo "==================== Installation summary ===================="
    echo "Disk:       $DISK"
    echo "Target:     $TARGET_OS ${TARGET_VER:-}"
    echo "Hostname:   localhost"
    echo "User:       root"
    echo "SSH port:   ${SSH_PORT:-22}"
    echo "Password:   $([[ -n "$PASSWORD_HASH" ]] && echo configured || echo 'SSH-key only')"
    echo "SSH keys:"
    if [[ -n "$SSH_KEYS_ALL" ]]; then
        while IFS= read -r key; do [[ -z "$key" ]] || echo "  $key"; done <<<"$SSH_KEYS_ALL"
    else
        echo "  (none)"
    fi
    echo "=============================================================="
}

do_install() {
    info "Installing $TARGET_OS ${TARGET_VER:-} to $DISK"
    info "Image: $IMG_URL"
    [[ "$HOLD" != 1 ]] || { info "--hold 1: validation only"; return; }

    installer_workspace
    installer_stage_optional_inputs
    preflight_target_image_in_alpine
    installer_write_image
    installer_write_seed
    run_post_install_hook
    show_partition_info
    print_install_summary

    trap - EXIT
    cleanup_install_stage
    [[ "$HOLD" != 2 ]] || { info "--hold 2: installation complete; not rebooting"; return; }
    info "Installation complete. Reboot when ready."
}

# ----------------- main -----------------

reset_config() {
    TARGET_OS="" TARGET_VER="" IMG_URL="" DISK=""
    PASSWORD="" PASSWORD_HASH="" PASSWORD_TO_DISPLAY="" AUTO_PASSWORD=0
    SSH_KEYS_ALL="" SSH_KEY_ARGS=() SSH_PORT="" WEB_PORT="" FRPC_TOML="" POST_INSTALL_HOOK="" FRPC_PRESENT=""
    HOLD=0 AUTO_YES=0 IMAGE_BUILTIN=0
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
    [[ $# -gt 0 ]] || error "Missing target OS"
    TARGET_OS=$(to_lower "$1"); shift
    target_versions "$TARGET_OS" >/dev/null || error "Unknown target OS: $TARGET_OS"

    [[ "$TARGET_OS" != redhat ]] || { PARSE_SHIFT=0; return; }
    [[ $# -gt 0 && "$1" != --* ]] || error "Missing version for $TARGET_OS"
    TARGET_VER="$1"
    [[ -n "$TARGET_VER" ]] && tr ' ' '\n' <<<"$(target_versions "$TARGET_OS")" | grep -Fxq -- "$TARGET_VER" || \
        error "Unsupported $TARGET_OS version: $TARGET_VER (supported: $(target_versions "$TARGET_OS"))"
    PARSE_SHIFT=1
}

append_ssh_key() {
    local key
    key=$(parse_ssh_key "$1")
    SSH_KEYS_ALL+="${SSH_KEYS_ALL:+$'\n'}$key"
}

parse_host_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --disk|--img|--password|--passwd|--ssh-key|--public-key|--ssh-port|--web-port|--frpc-toml|--post-install-hook|--hold)
                local opt="$1"; shift
                [[ $# -gt 0 ]] || error "Need value for $opt"
                case "$opt" in
                    --disk) DISK="$1" ;;
                    --img) IMG_URL="$1" ;;
                    --password|--passwd) PASSWORD="$1" ;;
                    --ssh-key|--public-key) SSH_KEY_ARGS+=("$1") ;;
                    --ssh-port) is_port_valid "$1" || error "Invalid SSH port: $1"; SSH_PORT="$1" ;;
                    --web-port) is_port_valid "$1" || error "Invalid web port: $1"; WEB_PORT="$1" ;;
                    --frpc-toml) FRPC_TOML="$1" ;;
                    --post-install-hook) POST_INSTALL_HOOK="$1" ;;
                    --hold) [[ "$1" == 1 || "$1" == 2 ]] || error "--hold must be 1 or 2"; HOLD="$1" ;;
                esac
                ;;
            --*=*)
                local opt="${1%%=*}" value="${1#*=}"
                [[ -n "$value" ]] || error "Empty value: $opt"
                set -- "$opt" "$value" "${@:2}"
                continue ;;
            *) error "Unknown argument: $1" ;;
        esac
        shift
    done
}

ensure_supported_sector_size() {
    local sector
    if [[ "$OS" == Linux ]]; then
        sector=$(blockdev --getss "$DISK" 2>/dev/null || true)
    else
        sector=$(diskinfo -v "$DISK" 2>/dev/null | awk '/# sectorsize/ {print $1; exit}')
    fi
    [[ "$sector" == 512 ]] || error "Unsupported logical sector size (${sector:-unknown}) on $DISK; aborting before disk modification"
}

prepare_target_disk() {
    if [[ -n "$DISK" ]]; then
        [[ "$DISK" == /dev/* ]] || DISK="/dev/$DISK"
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
    [[ -n "$PASSWORD" || -n "$SSH_KEYS_ALL" ]] || {
        echo "No --password or --ssh-key specified."
        read -r -s -p "Root password (empty = random): " a; echo
        if [[ -z "$a" ]]; then
            PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
            [[ -n "$PASSWORD" ]] || error "Failed to generate random password"
            PASSWORD_TO_DISPLAY="$PASSWORD"; AUTO_PASSWORD=1
        else
            read -r -s -p "Confirm root password: " b; echo
            [[ "$a" == "$b" ]] || error "Passwords do not match"
            PASSWORD="$a"
        fi
    }

    [[ -n "$PASSWORD" ]] || return 0
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
    echo "Hostname:   localhost"
    echo "SSH port:   ${SSH_PORT:-22}"
    [[ "$DISK_AUTO_SELECTED" != 1 ]] || echo "Disk reason: $AUTO_DETECT_REASON"
    if [[ "$AUTO_PASSWORD" == 1 ]]; then
        echo "Generated root password: $PASSWORD_TO_DISPLAY"
    else
        echo "Password:   $([[ -n "$PASSWORD_HASH" ]] && echo configured || echo 'SSH-key only')"
    fi
    echo "============================================================"
}

probe_remote_qcow_virtual_size() {
    local header size
    header=$(mktemp "${TMPDIR:-/tmp}/ddify-qcow.XXXXXX") || return 1
    if [[ "$IMG_URL" == *.xz ]]; then
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
    if [[ $(wc -c <"$header") -ne 72 || "$(od -An -tx1 -N4 "$header" | tr -d '[:space:]')" != 514649fb ]]; then
        rm -f "$header"
        return 1
    fi
    size=$(od -An -tu1 -j24 -N8 "$header" | awk '{for (i=1; i<=8; i++) n=n*256+$i; printf "%.0f\n", n}')
    rm -f "$header"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || return 1
    printf '%s\n' "$size"
}

preflight_image_geometry() {
    local disk_bytes image_bytes stage_safe
    disk_bytes=$(get_disk_size_bytes "$DISK")
    image_bytes=$(probe_remote_qcow_virtual_size) || \
        error "Cannot read remote QCOW2 header before disk modification"
    [[ "$disk_bytes" =~ ^[0-9]+$ && "$disk_bytes" -gt $((5 * 1024 * 1024 * 1024)) ]] || \
        error "Target disk is too small for 3 GiB staging"
    stage_safe=$((disk_bytes - 3072 * 1024 * 1024 - 64 * 1024 * 1024))
    if (( image_bytes > disk_bytes )); then
        warn "Image virtual size exceeds target disk; actual partition boundaries will be validated before writing"
    fi
    if (( image_bytes > stage_safe )); then
        warn "Image virtual size crosses the 3 GiB staging boundary; sparse-shadow safety is not guaranteed"
    fi
    info "Remote QCOW2 virtual size: $image_bytes bytes (disk: $disk_bytes bytes)"
}

preflight_target_image_on_host() {
    [[ "$IMG_URL" == https://* ]] || error "Target image URL must use HTTPS"
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

host_main() {
    reset_config
    [[ "${1:-}" != -h && "${1:-}" != --help ]] || usage
    (( EUID == 0 )) || error "Must run as root"
    [[ -f "$0" && -r "$0" && "$0" != /dev/fd/* && "$0" != /proc/*/fd/* ]] ||
        error "Run from a local script file; piping or process substitution is unsupported"

    parse_target "$@"
    local skip=$((1 + PARSE_SHIFT))
    shift "$skip"
    parse_host_options "$@"

    [[ "$TARGET_OS" != redhat || -n "$IMG_URL" ]] || error "redhat requires --img URL"
    [[ "$IMG_URL" != http://* ]] || error "HTTP image URLs are not supported; use HTTPS"
    detect_os_arch
    [[ "$HOLD" == 1 ]] || ensure_dependencies
    local key
    for key in "${SSH_KEY_ARGS[@]}"; do append_ssh_key "$key"; done
    prepare_target_disk
    [[ "$HOLD" == 1 ]] || check_secure_boot
    prepare_credentials
    if [[ -z "$IMG_URL" ]]; then
        IMG_URL=$(get_default_image_url "$TARGET_OS" "$TARGET_VER")
        IMAGE_BUILTIN=1
    fi
    if [[ "$HOLD" != 1 ]]; then
        preflight_target_image_on_host
        preflight_image_geometry
    fi
    print_host_summary
    [[ "$DISK_AUTO_SELECTED" != 1 ]] || print_disk_candidates
    if [[ "$HOLD" != 1 ]]; then
        local answer choice=1 i
        if [[ "$DISK_AUTO_SELECTED" == 1 ]]; then
            choice=""
            for i in "${!DISK_CANDIDATE_PATHS[@]}"; do
                [[ "${DISK_CANDIDATE_PATHS[i]}" != "$DISK" ]] || { choice=$((i + 1)); break; }
            done
            [[ -n "$choice" ]] || error "Selected disk is missing from candidate list"
        fi
        printf 'WARNING: all data on %s will be destroyed.\n' "$DISK" >&2
        read -r -p "Select [$choice] to confirm, [0] to cancel: " answer
        [[ "$answer" == "$choice" ]] || error "Destructive operation cancelled (use --disk to choose another device)"
    fi

    [[ "$HOLD" != 1 ]] || return 0
    PASSWORD_TO_DISPLAY=""
    prepare_and_boot_alpine_ram
}

parse_installer_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|--force) AUTO_YES=1 ;;
            --hold) shift; [[ "${1:-}" == 1 || "${1:-}" == 2 ]] || error "Invalid --hold"; HOLD="$1" ;;
            *) error "Unknown installer argument: $1" ;;
        esac
        shift
    done
}

installer_main() {
    reset_config
    parse_installer_options "$@"
    local hold_override="$HOLD"

    (( EUID == 0 )) || error "Must run as root"
    detect_os_arch
    load_install_plan
    [[ "$hold_override" == 0 ]] || HOLD="$hold_override"
    [[ "$HOLD" == 1 ]] || ensure_dependencies

    [[ -z "$DISK" || "$DISK" == /dev/* ]] || DISK="/dev/$DISK"
    [[ -n "$DISK" ]] || error "Install plan contains no target disk"
    resolve_target_disk_from_identity
    validate_target_disk "$DISK"
    ensure_supported_sector_size
    do_install
}

main() {
    case "${1:-}" in
        --phase)
            shift
            [[ "${1:-}" == installer ]] || error "Only --phase installer is supported"
            shift
            installer_main "$@"
            ;;
        *) host_main "$@" ;;
    esac
}

main "$@"
