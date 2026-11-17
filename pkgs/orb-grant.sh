#!/usr/bin/env bash
# orb-grant: short-lived SSH certificates for agent sessions, signed with one YubiKey touch.
#
#   orb-grant new <name> <principals> [hours] [--hosts "<dest>[,<dest>...]"]
#       Mint a grant (1..24 h). <principals> is comma-separated (e.g. leanci-admin).
#       --hosts records where the grant is used, so `revoke` can push the KRL there.
#       A destination is what you would pass to ssh, e.g. "ubuntu@5.39.72.91" or
#       "-J ubuntu@5.39.72.91 ubuntu@10.88.100.11".
#   orb-grant renew <name> [hours]   mint a fresh grant with the same principals and hosts
#   orb-grant revoke <name>          push a KRL to the grant's hosts, then delete the key
#   orb-grant status                 human-readable list
#   orb-grant json                   machine-readable list (omarchy-shell agent-grants plugin)
#
# The private key lives only in /run/user/$UID/agent-grants/<name>/ (tmpfs). The CA is the
# YubiKey admin key in yubikey-agent and never leaves the key. Hosts trust it through the
# sshd drop-in in lean.ci `infra/ssh`.
set -euo pipefail

ROOT=/run/user/$(id -u)/agent-grants
CA=${ORB_GRANT_CA:-$HOME/.ssh/thomas-yubikey-admin.pub}
AGENT=${ORB_GRANT_AGENT:-/run/user/$(id -u)/yubikey-agent/yubikey-agent.sock}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/orb-grant
KRL=$STATE/revoked.krl

die() { echo "orb-grant: $*" >&2; exit 2; }

valid_to() { # cert -> epoch seconds of expiry
  local to
  to=$(ssh-keygen -Lf "$1" | sed -n 's/.*Valid: from .* to //p')
  date -d "$to" +%s
}

key_id() { ssh-keygen -Lf "$1" | sed -n 's/.*Key ID: "\(.*\)"/\1/p'; }

ssh_with_grant() { # dir dest... -- command
  local d=$1; shift
  local -a dest=()
  read -r -a dest <<<"$1"; shift
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -o IdentityAgent=none \
    -i "$d/id_ed25519" -o CertificateFile="$d/id_ed25519-cert.pub" "${dest[@]}" "$@"
}

mint() { # name principals hours hosts
  local name=$1 principals=$2 hours=$3 hosts=$4
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "grant name must be lowercase letters, digits, dashes"
  if ! [[ $hours =~ ^[0-9]+$ ]] || ((hours < 1 || hours > 24)); then die "hours must be 1..24"; fi
  [[ $principals =~ ^[a-z0-9,_-]+$ ]] || die "principals must be comma-separated names"
  [ -S "$AGENT" ] || die "YubiKey agent socket missing: $AGENT"
  local d=$ROOT/$name tmp
  mkdir -p "$ROOT"; chmod 700 "$ROOT"
  tmp=$(mktemp -d "$ROOT/.new-$name.XXXXXX")
  ssh-keygen -q -t ed25519 -N '' -C "agent-grant-$name" -f "$tmp/id_ed25519"
  local id
  id="agent-grant:$name:$(hostname):$(date -u +%Y%m%dT%H%MZ)"
  echo "Touch the YubiKey to sign a ${hours}h grant '$name' for: $principals" >&2
  if ! SSH_AUTH_SOCK=$AGENT ssh-keygen -q -U -s "$CA" -I "$id" -n "$principals" -V "-5m:+${hours}h" \
    -O clear -O permit-pty -O permit-port-forwarding "$tmp/id_ed25519.pub"; then
    rm -rf "$tmp"; die "signing failed (no touch?)"
  fi
  printf '%s\n' "$principals" >"$tmp/principals"
  printf '%s\n' "$hosts" >"$tmp/hosts"
  rm -rf "$d"; mv "$tmp" "$d"
  echo "grant $name valid until $(date -d "@$(valid_to "$d/id_ed25519-cert.pub")" '+%a %H:%M')" >&2
}

cmd=${1:-status}; shift || true
case "$cmd" in
  new)
    [ $# -ge 2 ] || die "usage: orb-grant new <name> <principals> [hours] [--hosts LIST]"
    name=$1 principals=$2; shift 2
    hours=24; hosts=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --hosts) hosts=$2; shift 2 ;;
        *) hours=$1; shift ;;
      esac
    done
    mint "$name" "$principals" "$hours" "$hosts"
    ;;
  renew)
    [ $# -ge 1 ] || die "usage: orb-grant renew <name> [hours]"
    d=$ROOT/$1
    [ -f "$d/principals" ] || die "no grant named $1"
    mint "$1" "$(cat "$d/principals")" "${2:-24}" "$(cat "$d/hosts" 2>/dev/null || true)"
    ;;
  revoke)
    [ $# -ge 1 ] || die "usage: orb-grant revoke <name>"
    name=$1; d=$ROOT/$name; c=$d/id_ed25519-cert.pub
    [ -d "$d" ] || die "no grant named $name"
    if [ -f "$c" ]; then
      mkdir -p "$STATE"
      spec=$(mktemp); echo "id: $(key_id "$c")" >"$spec"
      if [ -f "$KRL" ]; then ssh-keygen -q -k -u -f "$KRL" -s "$CA" "$spec"; else ssh-keygen -q -k -f "$KRL" -s "$CA" "$spec"; fi
      rm -f "$spec"
      # Push with the grant itself while it still works; each host then refuses it.
      IFS=, read -r -a targets <<<"$(cat "$d/hosts" 2>/dev/null || true)"
      for t in "${targets[@]}"; do
        [ -n "$t" ] || continue
        if ssh_with_grant "$d" "$t" 'cat >/tmp/agent-grant-revoked.krl && sudo install -m 0644 /tmp/agent-grant-revoked.krl /etc/ssh/agent-grant-revoked.krl' <"$KRL"; then
          echo "revoked on $t" >&2
        else
          echo "could not reach $t; copy $KRL to its /etc/ssh/agent-grant-revoked.krl" >&2
        fi
      done
    fi
    rm -rf "${d:?}"; echo "grant $name deleted" >&2
    ;;
  json)
    now=$(date +%s); first=1; printf '{"now":%s,"grants":[' "$now"
    for c in "$ROOT"/*/id_ed25519-cert.pub; do
      [ -f "$c" ] || continue
      d=$(dirname "$c"); exp=$(valid_to "$c")
      [ $first = 1 ] || printf ','; first=0
      printf '{"name":"%s","key_id":"%s","principals":"%s","hosts":"%s","expires_at":%s,"active":%s}' \
        "$(basename "$d")" "$(key_id "$c")" "$(cat "$d/principals" 2>/dev/null || true)" \
        "$(sed 's/["\\]//g' "$d/hosts" 2>/dev/null || true)" "$exp" "$([ "$exp" -gt "$now" ] && echo true || echo false)"
    done
    printf ']}\n'
    ;;
  status)
    found=0
    for c in "$ROOT"/*/id_ed25519-cert.pub; do
      [ -f "$c" ] || continue
      found=1; left=$((($(valid_to "$c") - $(date +%s)) / 60))
      if [ $left -gt 0 ]; then state="$((left / 60))h$((left % 60))m left"; else state=expired; fi
      echo "$(basename "$(dirname "$c")"): $state ($(cat "$(dirname "$c")/principals" 2>/dev/null || echo '?'))"
    done
    [ $found = 1 ] || echo "no grants"
    ;;
  -h | --help | help) sed -n '2,17p' "$0" ;;
  *) die "unknown command $cmd (try: orb-grant help)" ;;
esac
