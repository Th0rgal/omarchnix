#!/usr/bin/env bash
# orb-grant: mint a short-lived SSH certificate for agent sessions with one YubiKey touch.
#   orb-grant new <name> <principals> [hours]   e.g. orb-grant new leanci leanci-admin 24
#   orb-grant status                            active grants and time left
#   orb-grant revoke <name> [user@host ...]     revoke on those hosts (KRL), then delete the key
#   orb-grant bar                               one-line JSON for a status bar (Waybar custom module)
# The private key lives only in /run/user/$UID/agent-grants/<name>/ (tmpfs); the CA is the
# YubiKey admin key in yubikey-agent and never leaves it.
set -euo pipefail
ROOT=/run/user/$(id -u)/agent-grants
CA=${ORB_GRANT_CA:-$HOME/.ssh/thomas-yubikey-admin.pub}
AGENT=${ORB_GRANT_AGENT:-/run/user/$(id -u)/yubikey-agent/yubikey-agent.sock}
cmd=${1:-status}
case "$cmd" in
  new)
    name=$2; principals=$3; hours=${4:-24}
    [ "$hours" -ge 1 ] && [ "$hours" -le 24 ] || { echo "hours must be 1..24" >&2; exit 2; }
    d=$ROOT/$name; rm -rf "$d"; mkdir -p "$d"; chmod 700 "$ROOT" "$d"
    ssh-keygen -q -t ed25519 -N '' -C "agent-grant-$name" -f "$d/id_ed25519"
    id="agent-grant:$name:$(hostname):$(date -u +%Y%m%dT%H%MZ)"
    echo "Touch the YubiKey to sign a ${hours}h grant '$name' for: $principals"
    SSH_AUTH_SOCK=$AGENT ssh-keygen -q -U -s "$CA" -I "$id" -n "$principals" -V "-5m:+${hours}h" \
      -O clear -O permit-pty -O permit-port-forwarding "$d/id_ed25519.pub"
    ssh-keygen -Lf "$d/id_ed25519-cert.pub" | grep -E "Key ID|Valid|Principals" -A1 | sed 's/^ *//' | head -6
    ;;
  status)
    for c in "$ROOT"/*/id_ed25519-cert.pub; do
      [ -f "$c" ] || { echo "no grants"; exit 0; }
      to=$(ssh-keygen -Lf "$c" | sed -n 's/.*Valid: from .* to //p')
      left=$(( ($(date -d "$to" +%s) - $(date +%s)) / 60 ))
      echo "$(basename "$(dirname "$c")"): $( [ $left -gt 0 ] && echo "${left} min left" || echo expired ) (until $to)"
    done ;;
  revoke)
    name=$2; shift 2; d=$ROOT/$name; c=$d/id_ed25519-cert.pub
    state=${XDG_STATE_HOME:-$HOME/.local/state}/orb-grant; mkdir -p "$state"; krl=$state/revoked.krl
    if [ -f "$c" ]; then
      id=$(ssh-keygen -Lf "$c" | sed -n 's/.*Key ID: "\(.*\)"/\1/p')
      spec=$(mktemp); echo "id: $id" > "$spec"
      if [ -f "$krl" ]; then ssh-keygen -k -u -f "$krl" -s "$CA" "$spec"; else ssh-keygen -k -f "$krl" -s "$CA" "$spec"; fi
      rm -f "$spec"
      # Push with the grant itself while it still works; each host then refuses it.
      for target in "$@"; do
        ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -i "$d/id_ed25519" \
          -o CertificateFile="$c" "$target" 'cat > /tmp/agent-grant-revoked.krl && sudo install -m 0644 /tmp/agent-grant-revoked.krl /etc/ssh/agent-grant-revoked.krl' < "$krl" \
          && echo "revoked on $target" || echo "could not reach $target; push $krl there" >&2
      done
    fi
    rm -rf "${d:?}"; echo "grant $name deleted" ;;
  bar)
    n=0; tip=""
    for c in "$ROOT"/*/id_ed25519-cert.pub; do
      [ -f "$c" ] || continue
      to=$(ssh-keygen -Lf "$c" | sed -n 's/.*Valid: from .* to //p'); left=$(( ($(date -d "$to" +%s) - $(date +%s)) / 60 ))
      [ $left -gt 0 ] || continue
      n=$((n+1)); tip="$tip$(basename "$(dirname "$c")"): $((left/60))h$((left%60))m left\\n"
    done
    if [ $n -gt 0 ]; then printf '{"text":"AGENT %d","tooltip":"%s","class":"active"}\n' "$n" "$tip"
    else printf '{"text":"","tooltip":"no agent grants","class":"none"}\n'; fi ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
