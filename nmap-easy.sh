#!/usr/bin/env bash
#
# nmap-easy.sh - a friendly wrapper around nmap.
#
# Run with no arguments for an interactive menu, or pass flags for a
# one-line scan (see -h). Works with the stock macOS bash 3.2 and Linux.
#
# Only scan hosts and networks you own or have written permission to test.

set -o pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"
readonly UPDATE_URL="https://raw.githubusercontent.com/itsmrroot/Nmap-Script/main/nmap-easy.sh"
readonly PROFILES="discover quick standard full udp os vuln aggressive custom"

# ---------- colours (disabled when output is not a terminal) ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi

info() { printf '%s[*]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ---------- defaults ----------
TARGETS=()        # targets given on the command line / prompt
TARGET_FILE=""    # or a file with one target per line (nmap -iL)
PROFILE=""
PORTS=""
TIMING=4
OUTDIR="./scans"
NAME=""
EXTRA_ARGS=()
ASSUME_YES=0
SUDO=()

usage() {
  cat <<EOF
${BOLD}$SCRIPT_NAME $VERSION${RESET} - make nmap easy

Usage:
  $SCRIPT_NAME                      interactive mode (asks everything)
  $SCRIPT_NAME -t TARGET [options]  one-line mode

Options:
  -t TARGET   Target(s): IP, range (192.168.1.1-254), CIDR (10.0.0.0/24)
              or hostname. Quote several: -t "10.0.0.1 10.0.0.5"
  -i FILE     Read targets from FILE (one per line)
  -s PROFILE  Scan profile (default: standard). See -l
  -p PORTS    Ports, e.g. 22,80,443 or 1-1024 or - (all)
  -T 0-5      Speed: 0 paranoid ... 3 normal, 4 fast (default), 5 insane
  -o DIR      Output directory (default: ./scans)
  -n NAME     Base name for result files (default: from the target)
  -x "FLAGS"  Extra raw nmap flags, e.g. -x "--script http-title -Pn"
  -y          Don't ask for confirmation
  -l          List scan profiles
  -u          Update this script to the latest version from GitHub
  -v          Show version
  -h          Show this help

Examples:
  $SCRIPT_NAME -t 192.168.1.1-254 -s discover
  $SCRIPT_NAME -t scanme.nmap.org -s quick -p 22,80,443
  sudo $SCRIPT_NAME -t 10.0.0.0/24 -s full -y
EOF
}

profile_desc() {
  case $1 in
    discover)   echo "Find live hosts only (ping sweep, no port scan)" ;;
    quick)      echo "Top 100 TCP ports - fast first look" ;;
    standard)   echo "Top 1000 TCP ports + service versions + default scripts" ;;
    full)       echo "All 65535 TCP ports, then deep scan of the open ones" ;;
    udp)        echo "Top 100 UDP ports + versions (needs root, slow)" ;;
    os)         echo "OS detection + service versions (needs root)" ;;
    vuln)       echo "Service versions + NSE 'vuln' scripts (slow, intrusive)" ;;
    aggressive) echo "OS, versions, scripts and traceroute (-A, needs root)" ;;
    custom)     echo "Your own nmap flags" ;;
    *)          return 1 ;;
  esac
}

needs_root() {
  case $1 in udp|os|aggressive) return 0 ;; esac
  return 1
}

list_profiles() {
  local i=1 p
  for p in $PROFILES; do
    printf '  %s%d)%s %-11s %s\n' "$GREEN" "$i" "$RESET" "$p" "$(profile_desc "$p")"
    i=$((i + 1))
  done
}

# ---------- input validation ----------
valid_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
}

valid_target() {
  local base n
  if [[ $1 =~ ^(.+)/([0-9]{1,2})$ ]]; then             # CIDR: 10.0.0.0/24
    base=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}
    valid_ipv4 "$base" && (( 10#$n <= 32 ))
  elif [[ $1 =~ ^([0-9.]+)-([0-9]{1,3})$ ]]; then      # range: 192.168.1.10-50
    base=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}
    valid_ipv4 "$base" && (( 10#$n <= 255 && 10#$n >= 10#${base##*.} ))
  elif [[ $1 =~ ^[0-9.]+$ ]]; then                     # single IPv4
    valid_ipv4 "$1"
  else                                                 # hostname
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
  fi
}

valid_ports() {
  local part lo hi parts
  [[ $1 == "-" ]] && return 0
  [[ $1 =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
  IFS=, read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    lo=${part%-*}; hi=${part#*-}
    (( 10#$lo >= 1 && 10#$hi <= 65535 && 10#$lo <= 10#$hi )) || return 1
  done
}

# hint "text"  - grey example line shown above a prompt
hint() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET" >&2; }

# ask VAR "Question" [default]  - prompt with an optional default value
ask() {
  local __var=$1 __q=$2 __def=${3-} __ans
  if [[ -n $__def ]]; then
    read -erp "$__q [$__def]: " __ans || exit 1
  else
    read -erp "$__q: " __ans || exit 1
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

confirm() {
  local ans
  (( ASSUME_YES )) && return 0
  read -rp "$1 [Y/n]: " ans || exit 1
  [[ -z $ans || $ans == [Yy]* ]]
}

# ---------- interactive prompts ----------
prompt_targets() {
  local input t bad
  while :; do
    hint "IP, range (192.168.1.1-254), CIDR (10.0.0.0/24), hostname or a file; space-separated"
    ask input "Target(s)"
    input=${input/#\~/$HOME}
    if [[ -f $input ]]; then
      TARGET_FILE=$input; return
    fi
    read -ra TARGETS <<< "$input"
    bad=""
    for t in "${TARGETS[@]}"; do valid_target "$t" || bad="$bad $t"; done
    if (( ${#TARGETS[@]} > 0 )) && [[ -z $bad ]]; then return; fi
    warn "Invalid target(s):${bad:- (empty)}"
  done
}

prompt_profile() {
  local choice
  printf '\n%sScan profiles%s\n' "$BOLD" "$RESET"
  list_profiles
  while :; do
    ask choice "Choose a profile (number or name)" 3
    if [[ $choice =~ ^[0-9]+$ ]]; then
      # shellcheck disable=SC2086  # split the profile list on purpose
      set -- $PROFILES
      if (( choice >= 1 && choice <= $# )); then PROFILE=${!choice}; return; fi
    elif profile_desc "$choice" >/dev/null; then
      PROFILE=$choice; return
    fi
    warn "Invalid choice: $choice"
  done
}

prompt_rest() {
  local flags
  if [[ $PROFILE == custom ]]; then
    hint "e.g. -sV --script http-title"
    ask flags "nmap flags"
    read -ra EXTRA_ARGS <<< "$flags"
  fi
  if [[ $PROFILE != discover ]]; then
    while :; do
      hint "e.g. 22,80,443 or 1-1024 or - for all; Enter = profile default"
      ask PORTS "Ports"
      [[ -z $PORTS ]] || valid_ports "$PORTS" && break
      warn "Invalid port list: $PORTS"
    done
  fi
  while :; do
    hint "0 paranoid, 1 sneaky, 2 polite, 3 normal, 4 fast, 5 insane"
    ask TIMING "Speed" "$TIMING"
    [[ $TIMING =~ ^[0-5]$ ]] && break
    warn "Speed must be a number from 0 to 5"
  done
  ask OUTDIR "Save results in" "$OUTDIR"
  ask NAME "Name of the result files" "$(default_name)"
}

default_name() {
  local n
  if [[ -n $TARGET_FILE ]]; then n=${TARGET_FILE##*/}; n=${n%.*}; else n=${TARGETS[0]}; fi
  printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------- scanning ----------
run_nmap() {
  # Show the exact command so it can be learned / copied (quote only when needed)
  local a
  printf '%s$ %s' "$BOLD" "${SUDO[*]}${SUDO[*]:+ }nmap"
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:,=+-]+$ ]]; then printf ' %s' "$a"; else printf ' %q' "$a"; fi
  done
  printf '%s\n\n' "$RESET"
  "${SUDO[@]}" nmap "$@"
}

# Comma-separated list of every open port in a .gnmap file
open_ports() {
  grep -oE '[0-9]+/open/' "$1" | cut -d/ -f1 | sort -un | paste -sd, -
}

summary() {
  local gnmap=$1
  [[ -f $gnmap ]] || return
  printf '\n%s========== Summary ==========%s\n' "$BOLD" "$RESET"
  printf 'Hosts up: %s\n' "$(grep -c 'Status: Up' "$gnmap")"
  if [[ $PROFILE == discover ]]; then
    awk '/Status: Up/ { print "  " $2, ($3 == "()" ? "" : $3) }' "$gnmap"
    return
  fi
  printf '  %s%-18s %11s  %-15s %s%s\n' "$BOLD" "HOST" "PORT" "SERVICE" "VERSION" "$RESET"
  awk -F'\t' '
    /Ports: / {
      split($1, h, " "); host = h[2]
      for (i = 2; i <= NF; i++) if ($i ~ /^Ports: /) { list = substr($i, 8); break }
      n = split(list, p, ", ")
      for (j = 1; j <= n; j++) {
        split(p[j], f, "/")
        if (f[2] == "open") {
          printf "  %-18s %6s/%-4s  %-15s %s\n", host, f[1], f[3], f[5], f[7]
          found++
        }
      }
    }
    END { if (!found) print "  No open ports found." }
  ' "$gnmap"
}

# Fills SCAN_ARGS with the nmap flags for $PROFILE (phase 1 only for "full")
build_args() {
  local tcp=-sT
  (( EUID == 0 || ${#SUDO[@]} )) && tcp=-sS     # SYN scan is faster but needs root
  SCAN_ARGS=(-T"$TIMING")

  add_ports() { if [[ -n $PORTS ]]; then SCAN_ARGS+=(-p "$PORTS"); else SCAN_ARGS+=("$@"); fi; }

  case $PROFILE in
    discover)   SCAN_ARGS+=(-sn) ;;
    quick)      SCAN_ARGS+=("$tcp" --open); add_ports --top-ports 100 ;;
    standard)   SCAN_ARGS+=("$tcp" -sV -sC --open); add_ports ;;
    full)       SCAN_ARGS+=("$tcp" --open --min-rate 1000); add_ports -p- ;;
    udp)        SCAN_ARGS+=(-sU -sV --version-intensity 0 --open); add_ports --top-ports 100 ;;
    os)         SCAN_ARGS+=("$tcp" -O --osscan-guess -sV --open); add_ports ;;
    vuln)       SCAN_ARGS+=("$tcp" -sV --script vuln --open); add_ports ;;
    aggressive) SCAN_ARGS+=(-A --open); add_ports ;;
    custom)     add_ports ;;
  esac
  SCAN_ARGS+=("${EXTRA_ARGS[@]}")
}

# ---------- self update ----------
# version_gt A B  - true when version A is newer than B (e.g. 1.10.0 > 1.9.2)
version_gt() {
  local IFS=. i a b
  read -ra a <<< "$1"; read -ra b <<< "$2"
  for i in 0 1 2; do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 1
}

self_update() {
  local self dir tmp latest
  self=$0
  [[ $self == */* ]] || self=$(command -v -- "$0")
  dir=$(cd "$(dirname "$self")" && pwd) || die "Cannot find where $SCRIPT_NAME is installed"
  self="$dir/${self##*/}"
  [[ -w $dir && -w $self ]] || die "No write permission for $self - try: sudo $SCRIPT_NAME -u"

  tmp=$(mktemp "$dir/.${SCRIPT_NAME}.XXXXXX") || die "Cannot create a temporary file in $dir"
  trap 'rm -f "$tmp"' EXIT

  info "Checking $UPDATE_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$UPDATE_URL" -o "$tmp" || die "Download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 30 "$UPDATE_URL" -O "$tmp" || die "Download failed"
  else
    die "Updating needs curl or wget"
  fi

  # Never replace a working script with an error page or a broken file
  latest=$(sed -n 's/^readonly VERSION="\([0-9.]*\)"$/\1/p' "$tmp")
  if [[ -z $latest ]] || ! bash -n "$tmp" 2>/dev/null; then
    die "Downloaded file is not a valid $SCRIPT_NAME - not updating"
  fi

  if ! version_gt "$latest" "$VERSION"; then
    ok "You already have the latest version ($VERSION)."
    return 0
  fi
  chmod 755 "$tmp" || die "Could not set permissions on the new version"
  mv -f "$tmp" "$self" || die "Could not replace $self"
  ok "Updated $SCRIPT_NAME: $VERSION -> $latest"
}

# ---------- main ----------
main() {
  local opt
  [[ $1 == "--help" ]] && { usage; exit 0; }
  while getopts ":t:i:s:p:T:o:n:x:yluvh" opt; do
    # "-t -y" means the value was forgotten (-p and -x may legitimately start with "-")
    if [[ $opt == [tisTon] && $OPTARG == -* ]]; then
      die "Option -$opt needs a value (see -h)"
    fi
    case $opt in
      t) read -ra TARGETS <<< "$OPTARG" ;;
      i) TARGET_FILE=$OPTARG ;;
      s) PROFILE=$OPTARG ;;
      p) PORTS=$OPTARG ;;
      T) TIMING=$OPTARG ;;
      o) OUTDIR=$OPTARG ;;
      n) NAME=$OPTARG ;;
      x) read -ra EXTRA_ARGS <<< "$OPTARG" ;;
      y) ASSUME_YES=1 ;;
      l) list_profiles; exit 0 ;;
      u) self_update; exit $? ;;
      v) echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
      h) usage; exit 0 ;;
      :) die "Option -$OPTARG needs a value (see -h)" ;;
      *) die "Unknown option -$OPTARG (see -h)" ;;
    esac
  done

  command -v nmap >/dev/null 2>&1 ||
    die "nmap is not installed. Install it with 'brew install nmap' (macOS) or 'sudo apt install nmap' (Debian/Ubuntu/Kali)."

  printf '%s%s %s%s - only scan networks you own or are allowed to test.\n' \
    "$BOLD" "$SCRIPT_NAME" "$VERSION" "$RESET"

  if (( ${#TARGETS[@]} == 0 )) && [[ -z $TARGET_FILE ]]; then
    [[ -t 0 ]] || die "No target given (use -t or -i, see -h)"
    echo
    prompt_targets
    prompt_profile
    prompt_rest
  fi

  # Validate everything, whether it came from flags or prompts
  local t
  if [[ -n $TARGET_FILE ]]; then
    [[ -r $TARGET_FILE ]] || die "Cannot read target file: $TARGET_FILE"
  else
    for t in "${TARGETS[@]}"; do valid_target "$t" || die "Invalid target: $t"; done
  fi
  PROFILE=${PROFILE:-standard}
  profile_desc "$PROFILE" >/dev/null || die "Unknown profile '$PROFILE'. Available: $PROFILES"
  [[ -z $PORTS ]] || valid_ports "$PORTS" || die "Invalid port list: $PORTS"
  [[ $TIMING =~ ^[0-5]$ ]] || die "Speed (-T) must be 0-5"
  if [[ $PROFILE == custom ]] && (( ${#EXTRA_ARGS[@]} == 0 )) && [[ -z $PORTS ]]; then
    die "The custom profile needs flags (-x) or ports (-p)"
  fi

  if needs_root "$PROFILE" && (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "The '$PROFILE' profile needs root. Re-run as root."
    warn "The '$PROFILE' profile needs root - nmap will run with sudo (you may be asked for your password)."
    SUDO=(sudo)
  fi

  OUTDIR=${OUTDIR/#\~/$HOME}
  OUTDIR=${OUTDIR%/}
  NAME=${NAME:-$(default_name)}
  mkdir -p "$OUTDIR" || die "Cannot create output directory: $OUTDIR"
  BASE="$OUTDIR/${NAME}_$(date +%Y%m%d_%H%M%S)"

  local target_args=("${TARGETS[@]}")
  [[ -n $TARGET_FILE ]] && target_args=(-iL "$TARGET_FILE")

  build_args

  printf '\n%sProfile:%s %s - %s\n' "$BOLD" "$RESET" "$PROFILE" "$(profile_desc "$PROFILE")"
  printf '%sTargets:%s %s\n' "$BOLD" "$RESET" "${TARGET_FILE:-${TARGETS[*]}}"
  printf '%sResults:%s %s.{nmap,gnmap,xml}\n\n' "$BOLD" "$RESET" "$BASE"
  confirm "Start the scan?" || { info "Cancelled."; exit 0; }

  trap 'echo; warn "Interrupted. Partial results (if any): $BASE.*"; exit 130' INT
  SECONDS=0
  local final="$BASE"

  if [[ $PROFILE == full ]]; then
    info "Phase 1/2: looking for open ports..."
    run_nmap "${SCAN_ARGS[@]}" -oA "$BASE.ports" "${target_args[@]}" || die "nmap failed"
    local open
    open=$(open_ports "$BASE.ports.gnmap")
    if [[ -z $open ]]; then
      final="$BASE.ports"
    else
      ok "Open ports: $open"
      info "Phase 2/2: service versions + default scripts on the open ports..."
      local tcp=-sT
      (( EUID == 0 || ${#SUDO[@]} )) && tcp=-sS
      run_nmap "$tcp" -sV -sC --open -T"$TIMING" -p "$open" "${EXTRA_ARGS[@]}" \
        -oA "$BASE" "${target_args[@]}" || die "nmap failed"
    fi
  else
    run_nmap "${SCAN_ARGS[@]}" -oA "$BASE" "${target_args[@]}" || die "nmap failed"
  fi

  # Files written through sudo belong to root - hand them back to the user
  (( ${#SUDO[@]} )) && sudo chown "$(id -u):$(id -g)" "$BASE".* 2>/dev/null

  summary "$final.gnmap"
  echo
  ok "Scan complete in $((SECONDS / 60))m $((SECONDS % 60))s."
  ok "Results saved to: $BASE.*  (.nmap = readable, .gnmap = grep-able, .xml = for tools)"
}

main "$@"
