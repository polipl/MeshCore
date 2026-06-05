#!/usr/bin/env bash
# build_firmware.sh – PoLi MeshCore firmware builder & deployer
#
# Usage:
#   ./build_firmware.sh [OPTIONS] [VERSION]
#
# VERSION format: vX.Y.Z.W  (e.g. v1.15.0.3)
#   Base X.Y.Z mirrors upstream MeshCore versioning.
#   Build number W is PoLi-specific; upstream builds are treated as W=0.
#
# Options:
#   --auto              Auto-increment W from poli_version.txt
#   --boards LIST       Comma-separated subset: heltec_v4,heltec_v3,xiao_s3_wio
#   --no-deploy         Build only – do not copy to website data/firmware/
#   --dry-run           Print what would happen, build & copy nothing
#   --keep-ini          Do not remove platformio.local.ini after build
#   -h, --help          Show this help
#
# Examples:
#   ./build_firmware.sh v1.15.0.1
#   ./build_firmware.sh --auto
#   ./build_firmware.sh --auto --boards heltec_v4
#   ./build_firmware.sh v1.15.0.2 --no-deploy
#   ./build_firmware.sh --dry-run --auto
#   ./build_firmware.sh --auto --boards heltec_v4,xiao_s3_wio

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
err()  { echo -e "${RED}✗${RESET} $*" >&2; }
info() { echo -e "${CYAN}→${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
hdr()  { echo -e "\n${BOLD}── $* ──${RESET}"; }
dim()  { echo -e "${DIM}$*${RESET}"; }

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSITE_DIR="${SCRIPT_DIR}/../meshcore.epila.pl/data/firmware"
BASE_URL="https://meshcore.epila.pl/firmware"
VERSION_FILE="${SCRIPT_DIR}/poli_version.txt"
LOCAL_INI="${SCRIPT_DIR}/platformio.local.ini"

# ─── Board definitions ────────────────────────────────────────────────────────
# Format: "BOARD_ID|PIO_ENV_NAME"
# BOARD_ID   – used as subdirectory in data/firmware/ and BOARD_ID define
# PIO_ENV    – exact env name (case-sensitive! matches .pio/build/<PIO_ENV>/)
declare -a BOARD_DEFS=(
    "heltec_v4|heltec_v4_repeater_cloud_ota"
    "heltec_v3|Heltec_v3_repeater_cloud_ota"
    "xiao_s3_wio|Xiao_S3_WIO_repeater_cloud_ota"
)

# ─── Argument parsing ─────────────────────────────────────────────────────────
VERSION=""
AUTO_INC=false
DRY_RUN=false
NO_DEPLOY=false
KEEP_INI=false
declare -a FILTER_BOARDS=()

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        v[0-9]*)    VERSION="$1"; shift ;;
        --auto)     AUTO_INC=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --no-deploy) NO_DEPLOY=true; shift ;;
        --keep-ini) KEEP_INI=true; shift ;;
        --boards)
            IFS=',' read -ra FILTER_BOARDS <<< "${2:-}"
            shift 2 ;;
        -h|--help)  usage ;;
        *)          err "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    esac
done

# ─── Version resolution ───────────────────────────────────────────────────────
resolve_version() {
    if [[ -n "$VERSION" && "$AUTO_INC" == "true" ]]; then
        err "Cannot use both VERSION and --auto at the same time."; exit 1
    fi

    if [[ "$AUTO_INC" == "true" ]]; then
        if [[ ! -f "$VERSION_FILE" ]]; then
            echo "v1.15.0.0" > "$VERSION_FILE"
        fi
        local stored; stored=$(tr -d '[:space:]' < "$VERSION_FILE")
        # strip leading v
        local plain="${stored#v}"
        local base; base=$(echo "$plain" | cut -d. -f1-3)
        local build; build=$(echo "$plain" | cut -d. -f4)
        # ensure build is numeric
        [[ "$build" =~ ^[0-9]+$ ]] || { err "poli_version.txt: invalid format '$stored'"; exit 1; }
        build=$(( build + 1 ))
        VERSION="v${base}.${build}"
        info "Auto-increment: ${stored} → ${VERSION}"
    fi

    if [[ -z "$VERSION" ]]; then
        err "No version specified. Pass VERSION (e.g. v1.15.0.1) or use --auto."
        exit 1
    fi

    # Validate: vX.Y.Z.W
    if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Invalid version: '${VERSION}'. Required format: vX.Y.Z.W (e.g. v1.15.0.1)"
        exit 1
    fi
}

# ─── Board filter ─────────────────────────────────────────────────────────────
# Populates global ACTIVE_BOARDS array (nameref not available in Bash < 4.3)
ACTIVE_BOARDS=()
filter_boards() {
    ACTIVE_BOARDS=()
    for def in "${BOARD_DEFS[@]}"; do
        local bid="${def%%|*}"
        if [[ ${#FILTER_BOARDS[@]} -eq 0 ]]; then
            ACTIVE_BOARDS+=("$def")
        else
            for sel in "${FILTER_BOARDS[@]}"; do
                if [[ "$sel" == "$bid" ]]; then
                    ACTIVE_BOARDS+=("$def"); break
                fi
            done
        fi
    done
}

# ─── platformio.local.ini writer ──────────────────────────────────────────────
write_local_ini() {
    local version="$1"
    local build_date; build_date=$(date "+%d %b %Y")
    # PlatformIO string macro: -D NAME='"value"'
    printf \
'; Generated by build_firmware.sh at %s\n; Remove or update before regular (non-PoLi) builds.\n[poli_build]\nbuild_flags =\n  -D FIRMWARE_VERSION='"'"'"%s"'"'"'\n  -D FIRMWARE_BUILD_DATE='"'"'"%s"'"'"'\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$version" "$build_date" \
        > "$LOCAL_INI"
    ok "platformio.local.ini → ${version} / ${build_date}"
}

# ─── Build one board ─────────────────────────────────────────────────────────
build_board() {
    local board_id="$1" pio_env="$2"
    local bin_path="${SCRIPT_DIR}/.pio/build/${pio_env}/firmware.bin"

    info "Compiling ${board_id} [env:${pio_env}]…"

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "  DRY-RUN: pio run -e ${pio_env}"
        return 0
    fi

    # Run PlatformIO; stream output; propagate exit code without triggering set -e
    if ! pio run -e "$pio_env"; then
        err "Build failed for ${board_id}"
        return 1
    fi

    if [[ ! -f "$bin_path" ]]; then
        err "firmware.bin not found after build: ${bin_path}"
        return 1
    fi

    local size; size=$(du -h "$bin_path" | cut -f1)
    ok "  ${bin_path} (${size})"
    return 0
}

# ─── Deploy one board ────────────────────────────────────────────────────────
deploy_board() {
    local board_id="$1" pio_env="$2" version="$3"
    local bin_src="${SCRIPT_DIR}/.pio/build/${pio_env}/firmware.bin"
    local dest_dir="${WEBSITE_DIR}/${board_id}"
    local bin_dst="${dest_dir}/firmware.bin"
    local manifest="${dest_dir}/manifest.json"
    local fw_url="${BASE_URL}/${board_id}/firmware.bin"

    if [[ "$NO_DEPLOY" == "true" ]]; then
        warn "  NO-DEPLOY: skipping ${board_id}"
        return 0
    fi

    if [[ ! -d "$dest_dir" ]]; then
        err "  Deploy dir missing: ${dest_dir}"
        err "  Create it manually or run: mkdir -p ${dest_dir}"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "  DRY-RUN: cp ${bin_src}"
        warn "         → ${bin_dst}"
        warn "  DRY-RUN: manifest.json ← {\"version\":\"${version}\",\"url\":\"${fw_url}\"}"
        return 0
    fi

    cp "$bin_src" "$bin_dst"
    ok "  firmware.bin → ${bin_dst}"

    printf '{"version":"%s","url":"%s"}\n' "$version" "$fw_url" > "$manifest"
    ok "  manifest.json ← version=${version}"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_ini() {
    if [[ "$KEEP_INI" == "true" || "$DRY_RUN" == "true" ]]; then
        dim "  platformio.local.ini kept"
        return
    fi
    if [[ -f "$LOCAL_INI" ]]; then
        rm "$LOCAL_INI"
        dim "  platformio.local.ini removed"
    fi
}

# ─── Save version ─────────────────────────────────────────────────────────────
save_version() {
    [[ "$DRY_RUN" == "true" ]] && { warn "DRY-RUN: poli_version.txt not updated"; return; }
    echo "$1" > "$VERSION_FILE"
    ok "poli_version.txt → $1"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   PoLi MeshCore Firmware Builder v2.0   ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
    [[ "$DRY_RUN"  == "true" ]] && warn "DRY-RUN mode – nothing will be built or deployed"

    # ── Resolve version ──
    resolve_version

    # ── Resolve boards ──
    filter_boards
    if [[ ${#ACTIVE_BOARDS[@]} -eq 0 ]]; then
        err "No boards matched. Available: heltec_v4, heltec_v3, xiao_s3_wio"
        exit 1
    fi

    # ── Print plan ──
    hdr "Build plan"
    info "Version   : ${VERSION}"
    info "Date      : $(date '+%d %b %Y')"
    if [[ "$NO_DEPLOY" == "true" ]]; then
        info "Deploy to : DISABLED (--no-deploy)"
    else
        info "Deploy to : ${WEBSITE_DIR}"
    fi
    echo ""
    for def in "${ACTIVE_BOARDS[@]}"; do
        local bid="${def%%|*}" env="${def##*|}"
        printf "  ${CYAN}%-14s${RESET} → env:%-40s\n" "$bid" "$env"
        printf "  ${DIM}%-14s   bin: .pio/build/%s/firmware.bin${RESET}\n" "" "$env"
        if [[ "$NO_DEPLOY" != "true" ]]; then
            printf "  ${DIM}%-14s   dst: %s/%s/${RESET}\n" "" "$WEBSITE_DIR" "$bid"
        fi
    done

    # ── Write platformio.local.ini ──
    hdr "Version config"
    if [[ "$DRY_RUN" != "true" ]]; then
        write_local_ini "$VERSION"
        dim "  Contents:"
        sed 's/^/    /' "$LOCAL_INI"
    else
        warn "DRY-RUN: would write platformio.local.ini"
    fi

    # ── Build & deploy ──
    declare -a success=() failed=()
    for def in "${ACTIVE_BOARDS[@]}"; do
        local board_id="${def%%|*}" pio_env="${def##*|}"
        hdr "Building: ${board_id}"
        if build_board "$board_id" "$pio_env"; then
            hdr "Deploying: ${board_id}"
            if deploy_board "$board_id" "$pio_env" "$VERSION"; then
                success+=("$board_id")
            else
                failed+=("$board_id")
            fi
        else
            failed+=("$board_id")
        fi
    done

    # ── Cleanup & persist version ──
    hdr "Finishing"
    cleanup_ini
    if [[ ${#success[@]} -gt 0 ]]; then
        save_version "$VERSION"
    fi

    # ── Summary ──
    hdr "Summary"
    info "Version   : ${VERSION}"
    [[ ${#success[@]} -gt 0 ]] && ok  "Built OK  : ${success[*]}"
    [[ ${#failed[@]}  -gt 0 ]] && err "Failed    : ${failed[*]}"

    if [[ "$NO_DEPLOY" != "true" && "$DRY_RUN" != "true" && ${#success[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Next – push to server:${RESET}"
        echo "  rsync -av --progress \\"
        echo "    ${WEBSITE_DIR}/ \\"
        echo "    user@server:/opt/meshcore-epila/data/firmware/"
        echo ""
        echo -e "${BOLD}Verify manifests:${RESET}"
        for def in "${ACTIVE_BOARDS[@]}"; do
            local bid="${def%%|*}"
            echo "  curl -s ${BASE_URL}/${bid}/manifest.json"
        done
    fi

    [[ ${#failed[@]} -gt 0 ]] && exit 1
    return 0
}

main "$@"
