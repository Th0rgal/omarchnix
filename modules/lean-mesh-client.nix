{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.omarchnix.mesh;

  defaultLeanMeshPkg =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? lean-mesh) then
      pkgs.omarchnix.lean-mesh
    else
      pkgs.sandboxed-sh or (
        if inputs ? orb then
          pkgs.callPackage ../pkgs/lean-mesh.nix {
            orbSrc = inputs.orb;
            turbo-lean = pkgs.turbo-lean or null;
          }
        else
          null
      );

  leanMeshPkg = if cfg.package != null then cfg.package else defaultLeanMeshPkg;

  roamingPeerModule = lib.types.submodule {
    options = {
      peerName = lib.mkOption {
        type = lib.types.str;
        description = "Peer name in `manifest.json` (e.g. `umbrel`).";
      };

      peerId = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 20;
        description = "Numeric peer ID passed to `lean-mesh roam-select`.";
      };

      lanHost = lib.mkOption {
        type = lib.types.str;
        example = "umbrel.local";
        description = "LAN mDNS/DNS hostname or IPv4 address for direct home Wi-Fi transport.";
      };

      lanFallbackHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "umbrel.home";
        description = "Optional secondary LAN router-DNS hostname checked if primary `lanHost` mDNS lookup times out.";
      };

      lanPort = lib.mkOption {
        type = lib.types.port;
        default = 51891;
        description = "Direct LAN WireGuard UDP port on the peer.";
      };

      wanHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "home.example.com";
        description = "Optional direct WAN hostname (DDNS) or IP for bypassing the `:51890` relay when off-LAN (falls back to `relayEndpoint` if unreachable).";
      };

      wanPort = lib.mkOption {
        type = lib.types.port;
        default = 51891;
        description = "Direct WAN WireGuard UDP port forwarded on the home router.";
      };

      p2pPunch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use the `:51890` relay for in-band `RNDZ` endpoint discovery and zero-open-port UDP hole-punching when off-LAN (falls back automatically to relay on symmetric NAT).";
      };

      relayEndpoint = lib.mkOption {
        type = lib.types.str;
        example = "65.109.98.246:51890";
        description = "Blind `orb-core` WireGuard UDP relay endpoint (`host:port`) used when off-LAN.";
      };

      maxDirectStaleSecs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 210;
        description = "Maximum WireGuard handshake age (seconds) before falling back to relay (must exceed WireGuard's 180s `REJECT_AFTER_TIME` + 25s keepalive).";
      };
    };
  };

  instanceModule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable this `lean-mesh` overlay instance.";
        };

        interface = lib.mkOption {
          type = lib.types.str;
          default = if name == "paloma" then "wg-leanmesh0" else "wg-${name}0";
          description = "Linux WireGuard interface name (1..15 chars).";
        };

        nftTable = lib.mkOption {
          type = lib.types.str;
          default =
            if name == "paloma" then "lean_mesh" else "${lib.replaceStrings [ "-" ] [ "_" ] name}_mesh";
          description = "Dedicated `nftables` `inet` table name isolated from other mesh planes.";
        };

        listenPort = lib.mkOption {
          type = lib.types.port;
          default = 51888;
          description = "Local UDP listen port for this WireGuard interface.";
        };

        openFirewallUdp = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open `listenPort` (UDP) in the host firewall so direct LAN peers can initiate handshakes.";
        };

        nodeName = lib.mkOption {
          type = lib.types.str;
          example = "macbook-air";
          description = "Local node name inside this plane's signed `manifest.json`.";
        };

        nodeId = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 10;
          description = "Local numeric peer ID used for roaming path selection.";
        };

        overlayAddress = lib.mkOption {
          type = lib.types.str;
          example = "10.88.0.100/32";
          description = "Overlay IPv4 CIDR assigned to `interface` (e.g. `10.88.0.100/32`).";
        };

        stateDir = lib.mkOption {
          type = lib.types.str;
          default = if name == "paloma" then "/etc/lean-mesh" else "/etc/lean-mesh-${name}";
          description = "Persistent directory containing `wg.key`, `manifest.json`, `coordinator.pub`, `ratchet-state.json`, and `psks/`.";
        };

        manifestUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional HTTPS/HTTP URL to fetch updated signed manifests (verified against pinned `coordinator.pub` + monotonic epoch ratchet before activation).";
        };

        denyTetherLateralGid = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Emit `meta skgid <denySkGid> counter drop` in `mesh_output` so confined tethered sessions cannot pivot onto this mesh.";
        };

        roamingPeers = lib.mkOption {
          type = lib.types.listOf roamingPeerModule;
          default = [ ];
          description = "Peers whose WireGuard endpoint switches automatically between `DirectLan` and `ControlPlaneRelay` via `lean-mesh roam-select`.";
        };
      };
    }
  );

  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  mkInstanceSyncScript =
    name: inst:
    let
      runDir = "/run/lean-mesh-${name}";
      denyArg =
        if inst.denyTetherLateralGid && cfg.denySkGid != null then
          "--deny-skgid ${toString cfg.denySkGid}"
        else
          "";
      roamPeersJson = pkgs.writeText "lean-mesh-${name}-roam.json" (builtins.toJSON inst.roamingPeers);
    in
    pkgs.writeShellApplication {
      name = "lean-mesh-${name}-sync";
      runtimeInputs = [
        leanMeshPkg
        pkgs.avahi
        pkgs.iproute2
        pkgs.wireguard-tools
        pkgs.nftables
        pkgs.coreutils
        pkgs.jq
        pkgs.curl
        pkgs.python3
      ];
      text = ''
        set -euo pipefail

        mode="''${1:-apply}"
        state_dir=${lib.escapeShellArg inst.stateDir}
        run_dir=${lib.escapeShellArg runDir}
        iface=${lib.escapeShellArg inst.interface}
        nft_tbl=${lib.escapeShellArg inst.nftTable}
        node_name=${lib.escapeShellArg inst.nodeName}
        overlay_cidr=${lib.escapeShellArg inst.overlayAddress}
        listen_port=${toString inst.listenPort}
        manifest_url=${lib.escapeShellArg (inst.manifestUrl or "")}

        install -d -m 0700 "$state_dir" "$state_dir/psks" "$run_dir"
        install -d -m 0755 "/run/lean-mesh-$iface"

        if [ ! -s "$state_dir/wg.key" ]; then
          umask 077
          wg genkey > "$state_dir/wg.key"
          chmod 0600 "$state_dir/wg.key"
        fi
        wg pubkey < "$state_dir/wg.key" > "$state_dir/wg.pub"
        chmod 0644 "$state_dir/wg.pub"

        cur_epoch=0
        cur_panic=0
        if [ -s "$state_dir/ratchet-state.json" ]; then
          cur_epoch="$(jq -r '.epoch // 0' "$state_dir/ratchet-state.json" 2>/dev/null || echo 0)"
          cur_panic="$(jq -r '.panic_seq // 0' "$state_dir/ratchet-state.json" 2>/dev/null || echo 0)"
        fi

        if [ -n "$manifest_url" ] && [ -s "$state_dir/coordinator.pub" ]; then
          tmp_mf="$run_dir/manifest.fetch.json"
          if curl -fsSL --max-time 8 "$manifest_url" -o "$tmp_mf" 2>/dev/null; then
            coord_hex="$(tr -d ' \t\r\n' < "$state_dir/coordinator.pub" | tr '[:upper:]' '[:lower:]')"
            cand_coord="$(jq -r '.coordinator_pubkey_hex // ""' "$tmp_mf" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
            if [ -n "$coord_hex" ] && [ "$cand_coord" = "$coord_hex" ] && \
              lean-mesh verify-manifest \
                --manifest "$tmp_mf" \
                --current-epoch "$cur_epoch" \
                --current-panic-seq "$cur_panic" >/dev/null 2>&1; then
              install -m 0600 "$tmp_mf" "$state_dir/manifest.json"
              cur_epoch="$(jq -r '.epoch // 0' "$state_dir/manifest.json")"
              cur_panic="$(jq -r '.panic_seq // 0' "$state_dir/manifest.json")"
              jq -n --argjson e "$cur_epoch" --argjson p "$cur_panic" '{epoch: $e, panic_seq: $p}' > "$state_dir/ratchet-state.json.tmp"
              chmod 0600 "$state_dir/ratchet-state.json.tmp"
              mv -f "$state_dir/ratchet-state.json.tmp" "$state_dir/ratchet-state.json"
            fi
          fi
          rm -f "$tmp_mf"
        fi

        if [ ! -s "$state_dir/manifest.json" ]; then
          echo "lean-mesh($iface): $state_dir/manifest.json not yet provisioned; standing by (pubkey: $(cat "$state_dir/wg.pub"))"
          exit 0
        fi

        if [ -s "$state_dir/coordinator.pub" ]; then
          coord_hex="$(tr -d ' \t\r\n' < "$state_dir/coordinator.pub" | tr '[:upper:]' '[:lower:]')"
          mf_coord="$(jq -r '.coordinator_pubkey_hex // ""' "$state_dir/manifest.json" | tr '[:upper:]' '[:lower:]')"
          if [ "$mf_coord" != "$coord_hex" ]; then
            echo "lean-mesh($iface): coordinator_pubkey_hex mismatch against pinned coordinator.pub!" >&2
            exit 1
          fi
        fi

        mf_epoch="$(jq -r '.epoch // 0' "$state_dir/manifest.json")"
        mf_panic="$(jq -r '.panic_seq // 0' "$state_dir/manifest.json")"
        if [ "$mf_epoch" -lt "$cur_epoch" ]; then
          echo "lean-mesh($iface): manifest epoch rollback rejected ($mf_epoch < $cur_epoch)" >&2
          exit 1
        fi
        lean-mesh verify-manifest --manifest "$state_dir/manifest.json" --current-epoch 0 >/dev/null
        if [ "$mf_epoch" -gt "$cur_epoch" ] || [ ! -s "$state_dir/ratchet-state.json" ]; then
          jq -n --argjson e "$mf_epoch" --argjson p "$mf_panic" '{epoch: $e, panic_seq: $p}' > "$state_dir/ratchet-state.json.tmp"
          chmod 0600 "$state_dir/ratchet-state.json.tmp"
          mv -f "$state_dir/ratchet-state.json.tmp" "$state_dir/ratchet-state.json"
        fi

        if [ "$mode" = "apply" ]; then
          umask 077
          lean-mesh render-wg \
            --manifest "$state_dir/manifest.json" \
            --node "$node_name" \
            --private-key-file "$state_dir/wg.key" \
            --interface "$iface" \
            --listen-port "$listen_port" \
            --psk-dir "$state_dir/psks" > "$run_dir/wg.conf"

          lean-mesh render-nft \
            --manifest "$state_dir/manifest.json" \
            --node "$node_name" \
            --interface "$iface" \
            --nft-table "$nft_tbl" \
            ${denyArg} > "$run_dir/nft.conf"

          if ! ip link show dev "$iface" >/dev/null 2>&1; then
            ip link add dev "$iface" type wireguard
          fi
          ip -4 addr flush dev "$iface" 2>/dev/null || true
          ip -4 addr add "$overlay_cidr" dev "$iface"
          wg setconf "$iface" "$run_dir/wg.conf"
          ip link set mtu 1420 up dev "$iface"

          nft delete table inet "$nft_tbl" 2>/dev/null || true
          nft -f "$run_dir/nft.conf"
        fi

        if ip link show dev "$iface" >/dev/null 2>&1; then
          # Self-heal overlay IP if NetworkManager or a link bounce ever strips it.
          if ! ip -4 addr show dev "$iface" | grep -qF "inet ''${overlay_cidr%/*}"; then
            ip -4 addr replace "$overlay_cidr" dev "$iface"
            ip link set mtu 1420 up dev "$iface"
          fi
          for peer_cidr in $(jq -r --arg self "$node_name" '.peers[] | select(.name != $self and (.revoked | not)) | "\(.overlay_ip)/\(.prefix_len)"' "$state_dir/manifest.json"); do
            ip -4 route replace "$peer_cidr" dev "$iface"
          done
        fi

        # Roaming endpoint reconciliation (`DirectLan` -> `DirectWan` -> `DirectP2P` -> `ControlPlaneRelay`)
        if [ -s ${lib.escapeShellArg roamPeersJson} ] && ip link show dev "$iface" >/dev/null 2>&1; then
          python3 - "$state_dir/manifest.json" ${lib.escapeShellArg roamPeersJson} "$iface" "${toString inst.nodeId}" "$state_dir/wg.pub" <<'PY'
        import base64, hashlib, json, os, socket, struct, subprocess, sys, time

        manifest_path, roam_path, iface, self_id_s, self_pub_path = sys.argv[1:6]
        manifest = json.loads(open(manifest_path, "r", encoding="utf-8").read())
        roam_peers = json.loads(open(roam_path, "r", encoding="utf-8").read())
        if not roam_peers:
            sys.exit(0)

        try:
            self_pub_b64 = open(self_pub_path, "r", encoding="utf-8").read().strip()
            self_pub32 = base64.b64decode(self_pub_b64)
            if len(self_pub32) != 32:
                self_pub32 = b""
        except Exception:
            self_pub32 = b""

        def query_relay_p2p_endpoint(relay_ep, self_p32, peer_p32):
            """Query `orb-core:51890` with an authenticated 84-byte `RNDZ` packet for the peer's observed NAT ip:port."""
            if len(self_p32) != 32 or len(peer_p32) != 32 or ":" not in relay_ep:
                return None
            host, port_s = relay_ep.rsplit(":", 1)
            try:
                port = int(port_s)
            except ValueError:
                return None
            prefix = b"RNDZ" + self_p32 + peer_p32
            mac_key = hashlib.blake2s(b"mac1----" + peer_p32, digest_size=32).digest()
            mac1 = hashlib.blake2s(prefix, key=mac_key, digest_size=16).digest()
            req = prefix + mac1
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(1.0)
            try:
                sock.sendto(req, (host, port))
                resp, _ = sock.recvfrom(64)
                if len(resp) == 16 and resp[:4] == b"RNDR":
                    ip_u32, peer_port, flags, age_s = struct.unpack("!IHHI", resp[4:16])
                    if flags in (1, 2) and ip_u32 != 0 and peer_port != 0 and age_s <= 120:
                        ip_str = socket.inet_ntoa(struct.pack("!I", ip_u32))
                        if not ip_str.startswith("127."):
                            return f"{ip_str}:{peer_port}"
            except Exception:
                return None
            finally:
                sock.close()
            return None

        status_file = f"/run/lean-mesh-{iface}/roam-status.json"
        prev_summary = {}
        try:
            with open(status_file, "r", encoding="utf-8") as fh:
                prev_summary = json.load(fh)
        except Exception:
            prev_summary = {}

        peers_by_name = {p["name"]: p for p in manifest.get("peers", [])}
        dump_out = subprocess.run(["wg", "show", iface, "dump"], capture_output=True, text=True)
        wg_state = {}
        if dump_out.returncode == 0:
            for idx, line in enumerate(dump_out.stdout.splitlines()):
                cols = line.split("\t")
                if idx > 0 and len(cols) >= 8:
                    wg_state[cols[0]] = {
                        "endpoint": cols[2] if cols[2] != "(none)" else "",
                        "handshake": int(cols[4] or "0"),
                        "keepalive": cols[7],
                    }

        now = int(time.time())
        status_summary = {}
        for rp in roam_peers:
            pname = rp["peerName"]
            peer = peers_by_name.get(pname)
            if not peer or peer.get("revoked"):
                continue
            pk = peer["wg_pubkey"]
            cur = wg_state.get(pk, {"endpoint": "", "handshake": 0, "keepalive": "off"})
            max_stale = int(rp["maxDirectStaleSecs"])
            prev = prev_summary.get(pname, {}) if isinstance(prev_summary.get(pname), dict) else {}

            # 1. DirectLan: prefer fast unicast router DNS (`lanFallbackHost`, e.g. `.home`)
            #    before multicast mDNS (`lanHost`, `.local`) which drops packets on busy Wi-Fi.
            lan_ip = None
            candidate_hosts = []
            if rp.get("lanFallbackHost"):
                candidate_hosts.append(rp["lanFallbackHost"])
            candidate_hosts.append(rp["lanHost"])
            for cand_host in candidate_hosts:
                if lan_ip:
                    break
                try:
                    infos = socket.getaddrinfo(cand_host, rp["lanPort"], socket.AF_INET, socket.SOCK_DGRAM)
                    if infos:
                        cand = infos[0][4][0]
                        if not cand.startswith("127."):
                            lan_ip = cand
                            break
                except Exception:
                    pass
                if cand_host.endswith(".local"):
                    try:
                        av = subprocess.run(
                            ["avahi-resolve", "-4", "-n", cand_host],
                            capture_output=True,
                            text=True,
                            timeout=3,
                        )
                        if av.returncode == 0 and av.stdout.strip():
                            parts = av.stdout.strip().split()
                            if len(parts) >= 2 and not parts[1].startswith("127."):
                                lan_ip = parts[1]
                                break
                    except Exception:
                        pass

            # Sticky LAN: if a transient DNS/mDNS lookup misses while WireGuard already has
            # a fresh handshake on the previous LAN IP, stay on LAN instead of flapping to relay.
            if not lan_ip and prev.get("lan_ip"):
                prev_lan_ep = f"{prev['lan_ip']}:{rp['lanPort']}"
                if cur["endpoint"] == prev_lan_ep and cur["handshake"] > 0 and (now - cur["handshake"]) <= max_stale:
                    lan_ip = prev["lan_ip"]

            direct_mode = "lan" if lan_ip else None
            direct_ep = f"{lan_ip}:{rp['lanPort']}" if lan_ip else None

            # 2. DirectWan (optional static/DDNS endpoint if configured).
            wan_ip = None
            if not direct_ep and rp.get("wanHost"):
                wan_port = int(rp.get("wanPort") or rp["lanPort"])
                for fam in (socket.AF_INET, socket.AF_INET6):
                    try:
                        infos = socket.getaddrinfo(rp["wanHost"], wan_port, fam, socket.SOCK_DGRAM)
                        if infos:
                            cand = infos[0][4][0]
                            if not cand.startswith("127.") and cand != "::1":
                                wan_ip = cand
                                direct_mode = "wan"
                                direct_ep = f"[{cand}]:{wan_port}" if ":" in cand else f"{cand}:{wan_port}"
                                break
                    except Exception:
                        pass

            relay_ep = rp["relayEndpoint"]

            # 3. DirectP2P (zero-open-port UDP hole-punching via `:51890` `RNDZ` rendezvous).
            p2p_ep = None
            if not direct_ep and rp.get("p2pPunch", True):
                try:
                    peer_pub32 = base64.b64decode(pk)
                except Exception:
                    peer_pub32 = b""
                p2p_ep = query_relay_p2p_endpoint(relay_ep, self_pub32, peer_pub32)
                if not p2p_ep and prev.get("p2p_ep"):
                    # Keep active P2P endpoint while handshake is fresh (peer is no longer hitting relay).
                    if cur["endpoint"] == prev["p2p_ep"] and cur["handshake"] > 0 and (now - cur["handshake"]) <= max_stale:
                        p2p_ep = prev["p2p_ep"]
                if p2p_ep:
                    direct_mode = "p2p"
                    direct_ep = p2p_ep

            lan_ep = direct_ep or f"0.0.0.0:{rp['lanPort']}"

            lan_probe_at = int(prev.get("lan_probe_at") or 0)
            lan_backoff_until = int(prev.get("lan_backoff_until") or 0)
            last_direct_hs = int(prev.get("last_direct_hs") or 0)
            prev_direct_ep = prev.get("direct_ep") or (f"{prev.get('lan_ip')}:{rp['lanPort']}" if prev.get("lan_ip") else None)
            if direct_ep != prev_direct_ep:
                lan_probe_at = 0
                lan_backoff_until = 0
                last_direct_hs = 0

            lan_candidate_ok = False
            effective_direct_hs = 0
            if direct_ep:
                if cur["endpoint"] == lan_ep:
                    fresh_boot = lan_probe_at == 0
                    if fresh_boot:
                        lan_probe_at = now
                    if cur["handshake"] >= lan_probe_at or (
                        fresh_boot
                        and last_direct_hs == 0
                        and cur["handshake"] > 0
                        and (now - cur["handshake"]) <= max_stale
                    ):
                        last_direct_hs = max(last_direct_hs, cur["handshake"])
                        lan_backoff_until = 0
                    if last_direct_hs > 0:
                        effective_direct_hs = last_direct_hs
                        if (now - last_direct_hs) <= max_stale:
                            lan_candidate_ok = True
                        else:
                            lan_backoff_until = now + 120
                    elif (now - lan_probe_at) <= 30:
                        # Allow 30s initial probe grace after switching to DirectLan/DirectWan.
                        effective_direct_hs = now
                        lan_candidate_ok = True
                    else:
                        lan_backoff_until = now + 120
                elif now >= lan_backoff_until:
                    # Probe DirectLan/DirectWan immediately upon joining or after backoff.
                    lan_probe_at = now
                    last_direct_hs = 0
                    effective_direct_hs = now
                    lan_candidate_ok = True
            else:
                lan_probe_at = 0
                last_direct_hs = 0

            roam_cmd = [
                "lean-mesh", "roam-select",
                *(["--lan-ok"] if lan_candidate_ok else []),
                "--relay-ok",
                "--src-id", self_id_s,
                "--dst-id", str(rp["peerId"]),
                "--relay-id", "1",
                "--active-relays", "0",
                "--max-relays", "64",
                "--now", str(now),
                "--direct-handshake-at", str(effective_direct_hs),
                "--max-stale-secs", str(max_stale),
                "--lan-endpoint", lan_ep,
                "--relay-endpoint", relay_ep,
            ]
            sel = subprocess.run(
                roam_cmd,
                capture_output=True,
                text=True,
                check=True,
            )
            decision = json.loads(sel.stdout)
            target_ep = decision.get("selected_endpoint") or ""
            kind = decision.get("path_kind") or "unknown"
            if kind == "direct_lan" and direct_mode == "wan":
                kind = "direct_wan"
            elif kind == "direct_lan" and direct_mode == "p2p":
                kind = "direct_p2p"
            if target_ep and not target_ep.startswith("0.0.0.0:"):
                if target_ep != cur["endpoint"]:
                    # Toggle persistent-keepalive 0 -> 25 so kernel WireGuard immediately
                    # initiates an authenticated handshake on the newly selected endpoint.
                    subprocess.run(
                        ["wg", "set", iface, "peer", pk, "persistent-keepalive", "0"],
                        check=False,
                    )
                    subprocess.run(
                        ["wg", "set", iface, "peer", pk, "endpoint", target_ep, "persistent-keepalive", "25"],
                        check=False,
                    )
                elif cur["keepalive"] != "25":
                    subprocess.run(
                        ["wg", "set", iface, "peer", pk, "persistent-keepalive", "25"],
                        check=False,
                    )
            status_summary[pname] = {
                "path_kind": kind,
                "endpoint": target_ep or cur["endpoint"],
                "last_handshake": cur["handshake"],
                "last_direct_hs": last_direct_hs,
                "lan_probe_at": lan_probe_at,
                "lan_backoff_until": lan_backoff_until,
                "lan_ip": lan_ip,
                "wan_ip": wan_ip,
                "p2p_ep": p2p_ep,
                "direct_ep": direct_ep,
                "updated_at": now,
            }

        tmp_status = f"{status_file}.tmp"
        with open(tmp_status, "w", encoding="utf-8") as fh:
            json.dump(status_summary, fh)
        os.chmod(tmp_status, 0o644)
        os.replace(tmp_status, status_file)
        PY
        fi
      '';
    };

  mkInstanceStopScript =
    name: inst:
    pkgs.writeShellApplication {
      name = "lean-mesh-${name}-stop";
      runtimeInputs = [
        pkgs.iproute2
        pkgs.nftables
      ];
      text = ''
        set -euo pipefail
        nft delete table inet ${lib.escapeShellArg inst.nftTable} 2>/dev/null || true
        ip link del dev ${lib.escapeShellArg inst.interface} 2>/dev/null || true
      '';
    };
in
{
  options.omarchnix.mesh = {
    enable = lib.mkEnableOption "declarative multi-plane `lean-mesh` WireGuard & `nftables` client";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Override package providing `/bin/lean-mesh` (defaults to `pkgs.omarchnix.lean-mesh`).";
    };

    denySkGid = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = 991;
      description = "Supplementary/primary GID blocked via `meta skgid <gid> counter drop` on non-tether mesh egress (`wg-leanmesh0`, `wg-homemesh0`).";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceModule;
      default = { };
      description = "Configured `lean-mesh` planes (e.g. `paloma` on `wg-leanmesh0` and `personal` on `wg-homemesh0`).";
    };
  };

  config = lib.mkIf (config.omarchnix.enable && cfg.enable && enabledInstances != { }) {
    assertions = [
      {
        assertion = leanMeshPkg != null;
        message = "omarchnix.mesh.enable requires `lean-mesh` package (`pkgs.omarchnix.lean-mesh` or `omarchnix.mesh.package`).";
      }
    ];

    environment.systemPackages = [
      leanMeshPkg
      pkgs.wireguard-tools
    ];

    networking.networkmanager.unmanaged = lib.mapAttrsToList (
      _: inst: "interface-name:${inst.interface}"
    ) enabledInstances;

    environment.etc."NetworkManager/conf.d/98-lean-mesh-unmanaged.conf".text = ''
      [keyfile]
      unmanaged-devices=${
        lib.concatStringsSep ";" (
          lib.mapAttrsToList (_: inst: "interface-name:${inst.interface}") enabledInstances
        )
      }
    '';

    networking.firewall.allowedUDPPorts = lib.concatLists (
      lib.mapAttrsToList (_: inst: lib.optional inst.openFirewallUdp inst.listenPort) enabledInstances
    );

    systemd.tmpfiles.rules = lib.concatLists (
      lib.mapAttrsToList (_name: inst: [
        "d ${inst.stateDir} 0700 root root -"
        "d ${inst.stateDir}/psks 0700 root root -"
        "d /run/lean-mesh-${inst.interface} 0755 root root -"
      ]) enabledInstances
    );

    systemd.services =
      (lib.mapAttrs' (
        name: inst:
        let
          syncScript = mkInstanceSyncScript name inst;
          stopScript = mkInstanceStopScript name inst;
        in
        lib.nameValuePair "lean-mesh-${name}" {
          description = "Lean-Mesh WireGuard & nftables plane (${name} / ${inst.interface})";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${syncScript}/bin/lean-mesh-${name}-sync apply";
            ExecReload = "${syncScript}/bin/lean-mesh-${name}-sync apply";
            ExecStop = "${stopScript}/bin/lean-mesh-${name}-stop";
          };
        }
      ) enabledInstances)
      // (lib.mapAttrs' (
        name: inst:
        let
          syncScript = mkInstanceSyncScript name inst;
        in
        lib.nameValuePair "lean-mesh-${name}-roam" {
          description = "Lean-Mesh roaming reconciler (${name} / ${inst.interface})";
          after = [ "lean-mesh-${name}.service" ];
          requires = [ "lean-mesh-${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${syncScript}/bin/lean-mesh-${name}-sync roam";
          };
        }
      ) (lib.filterAttrs (_: inst: inst.roamingPeers != [ ]) enabledInstances));

    systemd.timers = lib.mapAttrs' (
      name: _inst:
      lib.nameValuePair "lean-mesh-${name}-roam" {
        description = "Periodic roaming endpoint check for Lean-Mesh (${name})";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15s";
          OnUnitActiveSec = "15s";
          AccuracySec = "3s";
        };
      }
    ) (lib.filterAttrs (_: inst: inst.roamingPeers != [ ]) enabledInstances);
  };
}
