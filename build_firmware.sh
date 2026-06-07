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

# ─── PlatformIO binary ────────────────────────────────────────────────────────
PIO_BIN=""
for _candidate in \
    "$(which pio 2>/dev/null)" \
    "${HOME}/.platformio/penv/bin/pio" \
    "${HOME}/.local/bin/pio"; do
  if [[ -x "$_candidate" ]]; then
    PIO_BIN="$_candidate"
    break
  fi
done
if [[ -z "$PIO_BIN" ]]; then
  err "PlatformIO (pio) not found. Install from https://platformio.org or run:"
  err "  pip install platformio"
  exit 1
fi

# ─── Build definitions ────────────────────────────────────────────────────────
# Format: "DEVICE_TYPE|BOARD_ID|VARIANT|PIO_ENV_NAME"
#   DEVICE_TYPE – "repeater" or "companion"; top-level subdir in data/firmware/
#   BOARD_ID    – BOARD_ID define; subdirectory under DEVICE_TYPE
#   VARIANT     – companion connectivity variant (usb/ble/wifi); empty for repeater.
#                 Adds an extra path level: data/firmware/companion/<board>/<variant>/
#   PIO_ENV     – exact env name (case-sensitive! matches .pio/build/<PIO_ENV>/)
declare -a BUILD_DEFS=(
    "repeater|heltec_v4||heltec_v4_repeater_cloud_ota"
    "repeater|heltec_v3||Heltec_v3_repeater_cloud_ota"
    "repeater|xiao_s3_wio||Xiao_S3_WIO_repeater_cloud_ota"
    "companion|heltec_v4|usb|heltec_v4_companion_radio_usb_cloud_ota"
    "companion|heltec_v4|ble|heltec_v4_companion_radio_ble_cloud_ota"
    "companion|heltec_v4|wifi|heltec_v4_companion_radio_wifi_cloud_ota"
    "companion|heltec_v3|usb|Heltec_v3_companion_radio_usb_cloud_ota"
    "companion|heltec_v3|ble|Heltec_v3_companion_radio_ble_cloud_ota"
    "companion|heltec_v3|wifi|Heltec_v3_companion_radio_wifi_cloud_ota"
    "companion|xiao_s3_wio|usb|Xiao_S3_WIO_companion_radio_usb_cloud_ota"
    "companion|xiao_s3_wio|ble|Xiao_S3_WIO_companion_radio_ble_cloud_ota"
    "companion|xiao_s3_wio|wifi|Xiao_S3_WIO_companion_radio_wifi_cloud_ota"
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
# Filters BUILD_DEFS by BOARD_ID (matches across both repeater and companion
# entries — e.g. --boards heltec_v4 builds the repeater plus all companion
# usb/ble/wifi variants for that board).
# Populates global ACTIVE_BUILDS array (nameref not available in Bash < 4.3)
ACTIVE_BUILDS=()
filter_boards() {
    ACTIVE_BUILDS=()
    for def in "${BUILD_DEFS[@]}"; do
        IFS='|' read -r _dtype bid _variant _penv <<< "$def"
        if [[ ${#FILTER_BOARDS[@]} -eq 0 ]]; then
            ACTIVE_BUILDS+=("$def")
        else
            for sel in "${FILTER_BOARDS[@]}"; do
                if [[ "$sel" == "$bid" ]]; then
                    ACTIVE_BUILDS+=("$def"); break
                fi
            done
        fi
    done
}

# ─── platformio.local.ini writer ──────────────────────────────────────────────
write_local_ini() {
    local version="$1"
    local build_date; build_date=$(date "+%d %b %Y")

    # Preserve WIFI_SSID_N / WIFI_PWD_N lines from existing file
    local wifi_lines=""
    if [[ -f "$LOCAL_INI" ]]; then
        wifi_lines=$(grep -E "^\s+-D (WIFI_(SSID|PWD)_[0-9]+|OTA_TOKEN)" "$LOCAL_INI" || true)
    fi

    {
        printf '; Generated by build_firmware.sh at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '; WiFi credentials (WIFI_SSID_N/WIFI_PWD_N) are preserved across runs.\n'
        printf '[poli_build]\nbuild_flags =\n'
        printf "  -D FIRMWARE_VERSION='\"${version}\"'\n"
        printf "  -D FIRMWARE_BUILD_DATE='\"${build_date}\"'\n"
        if [[ -n "$wifi_lines" ]]; then
            printf '%s\n' "$wifi_lines"
        else
            printf '; No WiFi credentials found — add them manually:\n'
            printf ';   -D WIFI_SSID_1='"'"'"YourSSID"'"'"'\n'
            printf ';   -D WIFI_PWD_1='"'"'"YourPassword"'"'"'\n'
        fi
    } > "$LOCAL_INI"

    ok "platformio.local.ini → ${version} / ${build_date}"
    if [[ -n "$wifi_lines" ]]; then
        ok "  WiFi credentials preserved"
    else
        warn "  No WiFi credentials — add WIFI_SSID_N/WIFI_PWD_N to platformio.local.ini"
    fi
}

# ─── Build one env ───────────────────────────────────────────────────────────
build_board() {
    local label="$1" pio_env="$2"
    local bin_path="${SCRIPT_DIR}/.pio/build/${pio_env}/firmware.bin"

    info "Compiling ${label} [env:${pio_env}]…"

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "  DRY-RUN: pio run -e ${pio_env}"
        return 0
    fi

    # Run PlatformIO; stream output; propagate exit code without triggering set -e
    if ! "$PIO_BIN" run -e "$pio_env"; then
        err "Build failed for ${label}"
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

# ─── Deploy one build ────────────────────────────────────────────────────────
# rel_path layout:
#   repeater  → repeater/<board_id>/
#   companion → companion/<board_id>/<variant>/   (variant: usb/ble/wifi)
deploy_board() {
    local device_type="$1" board_id="$2" variant="$3" pio_env="$4" version="$5"
    local rel_path="${device_type}/${board_id}${variant:+/${variant}}"
    local bin_src="${SCRIPT_DIR}/.pio/build/${pio_env}/firmware.bin"
    local dest_dir="${WEBSITE_DIR}/${rel_path}"
    local bin_dst="${dest_dir}/firmware.bin"
    local manifest="${dest_dir}/manifest.json"
    local fw_url="${BASE_URL}/${rel_path}/firmware.bin"

    if [[ "$NO_DEPLOY" == "true" ]]; then
        warn "  NO-DEPLOY: skipping ${rel_path}"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "  DRY-RUN: cp ${bin_src}"
        warn "         → ${bin_dst}"
        warn "  DRY-RUN: manifest.json ← {\"version\":\"${version}\",\"url\":\"${fw_url}\"}"
        return 0
    fi

    if [[ ! -d "$dest_dir" ]]; then
        mkdir -p "$dest_dir"
        ok "  Created: ${dest_dir}"
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
    # Never remove if WiFi credentials are present
    if [[ -f "$LOCAL_INI" ]] && grep -qE "WIFI_(SSID|PWD)_[0-9]+|OTA_TOKEN" "$LOCAL_INI" 2>/dev/null; then
        dim "  platformio.local.ini kept (contains WiFi credentials)"
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
    if [[ ${#ACTIVE_BUILDS[@]} -eq 0 ]]; then
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
    for def in "${ACTIVE_BUILDS[@]}"; do
        IFS='|' read -r dtype bid variant env <<< "$def"
        local rel_path="${dtype}/${bid}${variant:+/${variant}}"
        printf "  ${CYAN}%-28s${RESET} → env:%-40s\n" "$rel_path" "$env"
        printf "  ${DIM}%-28s   bin: .pio/build/%s/firmware.bin${RESET}\n" "" "$env"
        if [[ "$NO_DEPLOY" != "true" ]]; then
            printf "  ${DIM}%-28s   dst: %s/%s/${RESET}\n" "" "$WEBSITE_DIR" "$rel_path"
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
    for def in "${ACTIVE_BUILDS[@]}"; do
        IFS='|' read -r dtype board_id variant pio_env <<< "$def"
        local rel_path="${dtype}/${board_id}${variant:+/${variant}}"
        hdr "Building: ${rel_path}"
        if build_board "$rel_path" "$pio_env"; then
            hdr "Deploying: ${rel_path}"
            if deploy_board "$dtype" "$board_id" "$variant" "$pio_env" "$VERSION"; then
                success+=("$rel_path")
            else
                failed+=("$rel_path")
            fi
        else
            failed+=("$rel_path")
        fi
    done

    # ── Cleanup & persist version ──
    hdr "Finishing"
    cleanup_ini
    if [[ ${#success[@]} -gt 0 ]]; then
        save_version "$VERSION"
    fi

    # ── Git commit & push website ──
    if [[ "$NO_DEPLOY" != "true" && "$DRY_RUN" != "true" && ${#success[@]} -gt 0 ]]; then
        local website_git; website_git="$(dirname "$WEBSITE_DIR")"
        website_git="$(dirname "$website_git")"  # up from data/firmware → repo root
        if [[ -d "${website_git}/.git" ]]; then
            hdr "Publishing website"
            git -C "$website_git" add data/firmware/
            if git -C "$website_git" diff --cached --quiet; then
                dim "  No changes to commit in website repo"
            else
                git -C "$website_git" commit -m "chore: firmware ${VERSION} for ${success[*]}"
                if git -C "$website_git" push; then
                    ok "  Pushed meshcore.epila.pl → origin"
                else
                    warn "  Push failed — commit is local, push manually"
                fi
            fi
        else
            warn "  Website dir is not a git repo: ${website_git}"
        fi
    fi

    # ── Summary ──
    hdr "Summary"
    info "Version   : ${VERSION}"
    if [[ ${#success[@]} -gt 0 ]]; then ok  "Built OK  : ${success[*]}"; fi
    if [[ ${#failed[@]}  -gt 0 ]]; then err "Failed    : ${failed[*]}"; fi

    if [[ "$NO_DEPLOY" != "true" && "$DRY_RUN" != "true" && ${#success[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Verify manifests:${RESET}"
        for def in "${ACTIVE_BUILDS[@]}"; do
            IFS='|' read -r dtype bid variant _penv <<< "$def"
            local rel_path="${dtype}/${bid}${variant:+/${variant}}"
            echo "  curl -s \"${BASE_URL}/${rel_path}/manifest.json?token=\$(grep OTA_TOKEN ${LOCAL_INI} 2>/dev/null | grep -o '\"[^\"]*\"' | tail -1 | tr -d '\"')\""
        done
    fi

    [[ ${#failed[@]} -gt 0 ]] && exit 1
    return 0
}

main "$@"
