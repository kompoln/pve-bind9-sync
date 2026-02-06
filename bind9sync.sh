#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/bind9sync.env"

# ---- defaults (can be overridden by env file) ----
BIND_SERVER="${BIND_SERVER:-}"
BIND_PORT="${BIND_PORT:-53}"
BIND_ZONE="${BIND_ZONE:-rpz.local.}"
BIND_TSIG_KEYFILE_B64="${BIND_TSIG_KEYFILE_B64:-}"

NETWORK="${NETWORK:-}"
TTL="${TTL:-60}"
DRY_RUN="${DRY_RUN:-false}"
DELETE_STOPPED="${DELETE_STOPPED:-false}"   # optional safety switch
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ---- logging ----
lvl_to_num() {
  case "${1^^}" in
    ERROR) echo 0 ;;
    WARN)  echo 1 ;;
    INFO)  echo 2 ;;
    DEBUG) echo 3 ;;
    *)     echo 2 ;;
  esac
}
LOG_N="$(lvl_to_num "$LOG_LEVEL")"
log() {
  local level="${1^^}"; shift
  local n; n="$(lvl_to_num "$level")"
  (( n <= LOG_N )) || return 0
  echo "[$level] bind9sync: $*"
}
die() { log ERROR "$*"; exit 1; }

# ---- helpers ----
need_bin() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

ipv4_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a>=0 && a<=255 && b>=0 && b<=255 && c>=0 && c<=255 && d>=0 && d<=255)) || return 1
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

cidr_contains() {
  local ip="$1" cidr="$2" net prefix
  net="${cidr%/*}"; prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  ((prefix>=0 && prefix<=32)) || return 1

  local ip_i net_i mask
  ip_i="$(ipv4_to_int "$ip")" || return 1
  net_i="$(ipv4_to_int "$net")" || return 1

  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
  fi

  (( (ip_i & mask) == (net_i & mask) ))
}

normalize_zone() {
  local z="$1"
  z="${z## }"; z="${z%% }"
  [[ -n "$z" ]] || die "BIND_ZONE is empty"
  [[ "$z" == *"." ]] || z="${z}."
  echo "$z"
}

dns_sanitize_label() {
  local s="$1"
  s="${s,,}"                       # lowercase
  s="${s//_/-}"                    # underscore -> hyphen
  s="$(echo "$s" | tr -cd 'a-z0-9-')"  # keep only safe chars
  s="$(echo "$s" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')" # trim/reduce
  [[ -n "$s" ]] || return 1
  # max label length 63
  echo "${s:0:63}"
}

get_vm_ip_in_network() {
  local vmid="$1"
  local json
  json="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null)" || return 1
  # pick first IPv4 in NETWORK; exclude loopback implicitly by cidr check
  local ips ip
  ips="$(echo "$json" | jq -r '.[]? | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null)" || return 1
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if cidr_contains "$ip" "$NETWORK"; then
      echo "$ip"
      return 0
    fi
  done <<<"$ips"
  return 1
}

dig_current_a() {
  local fqdn="$1"
  dig +time=2 +tries=1 +short @"$BIND_SERVER" -p "$BIND_PORT" "$fqdn" A 2>/dev/null | head -n1 || true
}

nsupdate_apply() {
  local fqdn="$1" ip="$2" keyfile="$3"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
server ${BIND_SERVER} ${BIND_PORT}
zone ${BIND_ZONE}
update delete ${fqdn} A
update add ${fqdn} ${TTL} A ${ip}
send
EOF
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    log INFO "DRY_RUN: would nsupdate ${fqdn} -> ${ip}"
    log DEBUG "DRY_RUN script: $(tr '\n' ';' <"$tmp")"
    rm -f "$tmp"
    return 0
  fi
  nsupdate -k "$keyfile" "$tmp"
  rm -f "$tmp"
}

nsupdate_delete() {
  local fqdn="$1" keyfile="$2"
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
server ${BIND_SERVER} ${BIND_PORT}
zone ${BIND_ZONE}
update delete ${fqdn} A
send
EOF
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    log INFO "DRY_RUN: would delete A ${fqdn}"
    rm -f "$tmp"
    return 0
  fi
  nsupdate -k "$keyfile" "$tmp"
  rm -f "$tmp"
}

# ---- load env ----
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---- validate & deps ----
need_bin qm
need_bin jq
need_bin dig
need_bin nsupdate
need_bin base64

BIND_ZONE="$(normalize_zone "$BIND_ZONE")"
[[ -n "$BIND_TSIG_KEYFILE_B64" ]] || die "BIND_TSIG_KEYFILE_B64 is empty"
[[ "$NETWORK" == */* ]] || die "NETWORK must be CIDR, e.g. 192.168.90.0/24"

# ---- lock ----
LOCK_FILE="/run/bind9sync.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || die "another instance is running (lock: $LOCK_FILE)"
else
  # best-effort without flock
  log WARN "flock not found; concurrency protection is weaker"
fi

# ---- keyfile ----
KEYDIR="$(mktemp -d)"
KEYFILE="${KEYDIR}/tsig.key"
cleanup() { rm -rf "$KEYDIR"; }
trap cleanup EXIT

echo "$BIND_TSIG_KEYFILE_B64" | base64 -d >"$KEYFILE" || die "failed to decode BIND_TSIG_KEYFILE_B64"
chmod 600 "$KEYFILE"

log INFO "sync start: zone=${BIND_ZONE} server=${BIND_SERVER}:${BIND_PORT} network=${NETWORK} dry_run=${DRY_RUN}"

failed=0
changed=0
skipped=0

# ---- iterate VMs ----
# format: VMID NAME STATUS ...
while read -r vmid name status; do
  [[ -n "${vmid:-}" && -n "${name:-}" && -n "${status:-}" ]] || continue

  safe_name="$(dns_sanitize_label "$name" 2>/dev/null || true)"
  if [[ -z "$safe_name" ]]; then
    log WARN "vmid=${vmid} name=${name}: cannot sanitize to DNS label, skip"
    ((++skipped))
    continue
  fi

  fqdn="${safe_name}.${BIND_ZONE}"

  if [[ "${status}" != "running" ]]; then
    log DEBUG "vmid=${vmid} name=${name}: status=${status} (not running)"
    if [[ "${DELETE_STOPPED,,}" == "true" ]]; then
      log INFO "vmid=${vmid} name=${name}: deleting A ${fqdn} (DELETE_STOPPED=true)"
      if ! nsupdate_delete "$fqdn" "$KEYFILE"; then
        log ERROR "delete failed: ${fqdn}"
        failed=1
      else
        ((++changed))
      fi
    else
      ((++skipped))
    fi
    continue
  fi

  ip="$(get_vm_ip_in_network "$vmid" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    log WARN "vmid=${vmid} name=${name}: no guest-agent IPv4 in ${NETWORK}, skip"
    ((++skipped))
    continue
  fi

  current="$(dig_current_a "$fqdn")"
  if [[ "$current" == "$ip" ]]; then
    log INFO "ok: ${fqdn} already ${ip}"
    ((++skipped))
    continue
  fi

  log INFO "update: ${fqdn} ${current:-<none>} -> ${ip}"
  if ! nsupdate_apply "$fqdn" "$ip" "$KEYFILE"; then
    log ERROR "nsupdate failed: ${fqdn} -> ${ip}"
    failed=1
    continue
  fi
  ((++changed))
done < <(qm list | awk 'NR>1 {print $1,$2,$3}')

log INFO "sync done: changed=${changed} skipped=${skipped} failed=${failed}"
exit "$failed"
