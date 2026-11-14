{
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:
let
  cfg = config.omarchnix.macTether;
  desktopUser =
    if cfg.user != null then
      cfg.user
    else if config.omarchnix.desktop.user != null then
      config.omarchnix.desktop.user
    else
      "thomas";
  desktopUid = config.users.users.${desktopUser}.uid or 1000;
  desktopHome = config.users.users.${desktopUser}.home or "/home/${desktopUser}";

  defaultLeanMeshPkg =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? lean-mesh) then
      pkgs.omarchnix.lean-mesh
    else if config.omarchnix.mesh.package != null then
      config.omarchnix.mesh.package
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

  leanMeshPkg = if cfg.leanMeshPackage != null then cfg.leanMeshPackage else defaultLeanMeshPkg;

  omarchyShellPkg =
    if (pkgs ? omarchnix) && (pkgs.omarchnix ? omarchy-shell) then
      pkgs.omarchnix.omarchy-shell
    else
      null;

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.cryptography
  ]);

  tetherDispatchSrc = pkgs.writeText "orb-tether-dispatch.c" ''
    #define _GNU_SOURCE
    #include <errno.h>
    #include <fcntl.h>
    #include <grp.h>
    #include <limits.h>
    #include <sched.h>
    #include <stdbool.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/mount.h>
    #include <sys/prctl.h>
    #include <sys/stat.h>
    #include <sys/types.h>
    #include <time.h>
    #include <unistd.h>

    #ifndef MS_NOSYMFOLLOW
    #define MS_NOSYMFOLLOW 256
    #endif

    static bool valid_lease_id(const char *s) {
      if (!s || !*s) return false;
      size_t n = 0;
      for (; s[n]; n++) {
        char c = s[n];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '-';
        if (!ok || n >= 64) return false;
      }
      return n >= 4;
    }

    static void trim_eol(char *s) {
      size_t n = strlen(s);
      while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ')) {
        s[--n] = '\0';
      }
    }

    static bool copy_str(char *dst, size_t dst_sz, const char *src) {
      if (!dst || dst_sz == 0 || !src) return false;
      size_t len = strlen(src);
      if (len >= dst_sz) return false;
      memcpy(dst, src, len + 1);
      return true;
    }

    static int mkdir_p_mode(const char *path, mode_t mode) {
      char tmp[PATH_MAX];
      if (!copy_str(tmp, sizeof(tmp), path)) return -1;
      for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
          *p = '\0';
          if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
          *p = '/';
        }
      }
      if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
      return 0;
    }

    static int join_lease_cgroup(const char *lease_id) {
      char cg_dir[PATH_MAX - 32];
      char procs_path[PATH_MAX];
      int cn = snprintf(cg_dir, sizeof(cg_dir),
                        "/sys/fs/cgroup/orb-tether.slice/lease-%s/sess-%d",
                        lease_id, (int)getpid());
      if (cn < 0 || (size_t)cn >= sizeof(cg_dir)) {
        return -1;
      }
      if (mkdir_p_mode(cg_dir, 0755) != 0) {
        return -1;
      }
      int pn = snprintf(procs_path, sizeof(procs_path), "%s/cgroup.procs", cg_dir);
      if (pn < 0 || (size_t)pn >= sizeof(procs_path)) {
        return -1;
      }
      int fd = open(procs_path, O_WRONLY | O_CLOEXEC);
      if (fd < 0) return -1;
      char pid_buf[32];
      int len = snprintf(pid_buf, sizeof(pid_buf), "%d\n", (int)getpid());
      ssize_t w = write(fd, pid_buf, (size_t)len);
      close(fd);
      return (w == len) ? 0 : -1;
    }

    static int mask_sensitive_path(const char *target) {
      struct stat st;
      if (lstat(target, &st) != 0) {
        if (errno == ENOENT) return 0;
        return -1;
      }
      if (S_ISLNK(st.st_mode)) {
        return 0;
      }
      if (S_ISDIR(st.st_mode)) {
        if (mount("tmpfs", target, "tmpfs",
                  MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_NOSYMFOLLOW,
                  "size=4k,mode=0500,uid=${toString desktopUid},gid=${toString cfg.denyGid}") != 0) {
          return -1;
        }
        if (mount(NULL, target, NULL,
                  MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC,
                  "size=4k,mode=0500,uid=${toString desktopUid},gid=${toString cfg.denyGid}") != 0) {
          return -1;
        }
        return 0;
      }
      if (mount("/dev/null", target, NULL, MS_BIND, NULL) != 0) {
        return -1;
      }
      return 0;
    }

    int main(int argc, char **argv) {
      if (argc != 2 || !valid_lease_id(argv[1])) {
        fprintf(stderr, "orb-tether-dispatch: invalid lease id\n");
        return 126;
      }
      const char *lease_id = argv[1];

      char lease_path[PATH_MAX];
      if (snprintf(lease_path, sizeof(lease_path), "/run/mac-mesh/leases/%s.env", lease_id) >= (int)sizeof(lease_path)) {
        return 126;
      }

      int lfd = open(lease_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
      if (lfd < 0) {
        fprintf(stderr, "orb-tether-dispatch: lease is inactive or revoked\n");
        return 126;
      }
      struct stat lst;
      if (fstat(lfd, &lst) != 0 || !S_ISREG(lst.st_mode) || lst.st_uid != 0) {
        close(lfd);
        fprintf(stderr, "orb-tether-dispatch: invalid lease ownership\n");
        return 126;
      }
      FILE *fp = fdopen(lfd, "r");
      if (!fp) {
        close(lfd);
        return 126;
      }

      char target[32] = {0};
      char overlay_ip[64] = {0};
      long long expires_at = 0;
      char line[512];
      while (fgets(line, sizeof(line), fp)) {
        trim_eol(line);
        if (strncmp(line, "TARGET=", 7) == 0) {
          if (!copy_str(target, sizeof(target), line + 7)) {
            fclose(fp);
            return 126;
          }
        } else if (strncmp(line, "OVERLAY_IP=", 11) == 0) {
          if (!copy_str(overlay_ip, sizeof(overlay_ip), line + 11)) {
            fclose(fp);
            return 126;
          }
        } else if (strncmp(line, "EXPIRES_AT=", 11) == 0) {
          expires_at = atoll(line + 11);
        }
      }
      fclose(fp);

      long long now = (long long)time(NULL);
      if (expires_at <= now || overlay_ip[0] == '\0') {
        fprintf(stderr, "orb-tether-dispatch: lease expired\n");
        return 126;
      }

      const char *ssh_conn = getenv("SSH_CONNECTION");
      if (!ssh_conn) {
        fprintf(stderr, "orb-tether-dispatch: missing SSH_CONNECTION\n");
        return 126;
      }
      size_t ip_len = strlen(overlay_ip);
      if (strncmp(ssh_conn, overlay_ip, ip_len) != 0 || ssh_conn[ip_len] != ' ') {
        fprintf(stderr, "orb-tether-dispatch: source IP mismatch against lease overlay IP\n");
        return 126;
      }

      if (join_lease_cgroup(lease_id) != 0) {
        fprintf(stderr, "orb-tether-dispatch: failed joining lease cgroup\n");
        return 126;
      }

      const char *orig_cmd = getenv("SSH_ORIGINAL_COMMAND");
      const char *ssh_tty = getenv("SSH_TTY");
      const char *term_val = getenv("TERM");
      char saved_cmd[8192] = {0};
      char saved_term[64] = "xterm-256color";
      bool has_cmd = false;
      if (orig_cmd && *orig_cmd) {
        if (!copy_str(saved_cmd, sizeof(saved_cmd), orig_cmd)) {
          fprintf(stderr, "orb-tether-dispatch: command too long\n");
          return 126;
        }
        has_cmd = true;
      }
      if (term_val && *term_val) {
        if (!copy_str(saved_term, sizeof(saved_term), term_val)) {
          copy_str(saved_term, sizeof(saved_term), "xterm-256color");
        }
      }

      if (strcmp(target, "sandbox") == 0) {
        if (setresgid(0, 0, 0) != 0 || setresuid(0, 0, 0) != 0) return 126;
        char *clean_env[] = {
          "PATH=/run/current-system/sw/bin:/usr/bin:/bin",
          "LANG=en_US.UTF-8",
          NULL
        };
        if (has_cmd) {
          char *args[] = {
            "${pkgs.systemd}/bin/systemd-run",
            "--quiet",
            "--pipe",
            "--wait",
            "-M", "orb-sandbox",
            "--uid=dev",
            "--working-directory=/workspace",
            "--setenv=HOME=/home/dev",
            "--setenv=PATH=/run/current-system/sw/bin:/usr/bin:/bin",
            "/bin/sh", "-lc", saved_cmd,
            NULL
          };
          execve(args[0], args, clean_env);
        } else {
          char *args[] = {
            "${pkgs.systemd}/bin/systemd-run",
            "--quiet",
            ssh_tty ? "--pty" : "--pipe",
            "--wait",
            "-M", "orb-sandbox",
            "--uid=dev",
            "--working-directory=/workspace",
            "--setenv=HOME=/home/dev",
            "--setenv=PATH=/run/current-system/sw/bin:/usr/bin:/bin",
            "/bin/sh", "-l",
            NULL
          };
          execve(args[0], args, clean_env);
        }
        perror("execve(systemd-run orb-sandbox)");
        return 127;
      }

      if (strcmp(target, "thomas") == 0) {
        if (unshare(CLONE_NEWNS) != 0) {
          perror("unshare(CLONE_NEWNS)");
          return 126;
        }
        if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
          perror("mount(MS_PRIVATE)");
          return 126;
        }

        const char *masked_paths[] = {
          "${desktopHome}/.ssh",
          "${desktopHome}/.orb",
          "${desktopHome}/.gnupg",
          "${desktopHome}/.config/Bitwarden",
          "${desktopHome}/.config/Signal",
          "/run/user/${toString desktopUid}/yubikey-agent",
          "/run/user/${toString desktopUid}/keyring",
          "/run/mac-mesh",
          NULL
        };
        for (int i = 0; masked_paths[i] != NULL; i++) {
          if (mask_sensitive_path(masked_paths[i]) != 0) {
            fprintf(stderr, "orb-tether-dispatch: failed masking %s\n", masked_paths[i]);
            return 126;
          }
        }

        gid_t supp_gids[2] = { 100, ${toString cfg.denyGid} };
        if (setgroups(2, supp_gids) != 0) {
          perror("setgroups");
          return 126;
        }
        if (setresgid(${toString cfg.denyGid}, ${toString cfg.denyGid}, ${toString cfg.denyGid}) != 0) {
          perror("setresgid");
          return 126;
        }
        if (setresuid(${toString desktopUid}, ${toString desktopUid}, ${toString desktopUid}) != 0) {
          perror("setresuid");
          return 126;
        }
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
          perror("prctl(NO_NEW_PRIVS)");
          return 126;
        }
        if (chdir("${desktopHome}") != 0) {
          if (chdir("/tmp") != 0) return 126;
        }

        char env_term[96];
        snprintf(env_term, sizeof(env_term), "TERM=%s", saved_term);
        char *user_env[] = {
          "HOME=${desktopHome}",
          "USER=${desktopUser}",
          "LOGNAME=${desktopUser}",
          "PATH=/etc/profiles/per-user/${desktopUser}/bin:/run/current-system/sw/bin:/usr/bin:/bin",
          "LANG=en_US.UTF-8",
          env_term,
          "ORB_MAC_TETHER_CONFINED=1",
          NULL
        };
        if (has_cmd) {
          char *args[] = { "${pkgs.bash}/bin/bash", "-lc", saved_cmd, NULL };
          execve(args[0], args, user_env);
        } else {
          char *args[] = { "${pkgs.zsh}/bin/zsh", "-l", NULL };
          execve(args[0], args, user_env);
        }
        perror("execve(confined shell)");
        return 127;
      }

      fprintf(stderr, "orb-tether-dispatch: unsupported target\n");
      return 126;
    }
  '';

  tetherDispatchPkg = pkgs.runCommandCC "orb-tether-dispatch" { } ''
    mkdir -p "$out/bin"
    $CC -O2 -Wall -Wextra -Werror ${tetherDispatchSrc} -o "$out/bin/orb-tether-dispatch"
  '';

  macMeshDaemonPy = pkgs.writeText "mac-meshd.py" (
    builtins.replaceStrings
      [
        "@macTether_0@"
        "@macTether_1@"
        "@macTether_2@"
        "@macTether_3@"
        "@macTether_4@"
        "@macTether_5@"
        "@macTether_6@"
        "@macTether_7@"
        "@macTether_8@"
      ]
      [
        "${toString cfg.listenPort}"
        "${builtins.toJSON desktopUser}"
        "${toString desktopUid}"
        "${builtins.toJSON desktopHome}"
        "${builtins.toJSON (if cfg.coreUrl != null then cfg.coreUrl else "")}"
        "${builtins.toJSON (
          if cfg.tokenFile != null then cfg.tokenFile else "/var/lib/mac-mesh/core.token"
        )}"
        "${toString cfg.sshPort}"
        "${toString cfg.sshPort}"
        "${toString cfg.sshPort}"
      ]
      (builtins.readFile ./mac-tether/mac-meshd.py)
  );

  macMeshCtlPkg = pkgs.writeShellApplication {
    name = "mac-meshctl";
    runtimeInputs = [ pythonEnv ];
    text = ''
      exec ${pythonEnv}/bin/python3 - "$@" <<'PY'
      import json, socket, sys

      SOCK = "/run/mac-mesh/ui.sock"
      args = sys.argv[1:]
      cmd = args[0] if args else "status"

      def send_once(payload):
          s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
          s.settimeout(45.0)
          s.connect(SOCK)
          s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
          buf = b""
          while not buf.endswith(b"\n"):
              chunk = s.recv(65536)
              if not chunk:
                  break
              buf += chunk
          s.close()
          sys.stdout.write(buf.decode("utf-8", errors="replace"))
          sys.stdout.flush()
          obj = json.loads(buf.decode("utf-8") or "{}")
          if obj.get("ok") is False:
              sys.exit(1)

      if cmd == "watch":
          import time
          while True:
              try:
                  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                  s.connect(SOCK)
                  s.sendall(b'{"op":"watch"}\n')
                  f = s.makefile("r", encoding="utf-8")
                  for line in f:
                      sys.stdout.write(line)
                      sys.stdout.flush()
              except Exception as exc:
                  sys.stdout.write(json.dumps({"version": 1, "daemon_offline": True, "error": str(exc)}) + "\n")
                  sys.stdout.flush()
                  time.sleep(2.0)
      elif cmd == "status":
          send_once({"op": "status"})
      elif cmd == "approve":
          req_id = args[1]
          target = "sandbox"
          ttl = 60
          sess = True
          i = 2
          while i < len(args):
              if args[i] == "--target" and i + 1 < len(args):
                  target = args[i + 1]; i += 2
              elif args[i] == "--ttl" and i + 1 < len(args):
                  ttl = int(args[i + 1]); i += 2
              elif args[i] == "--session-scoped" and i + 1 < len(args):
                  sess = args[i + 1].lower() in ("1", "true", "yes"); i += 2
              else:
                  i += 1
          send_once({"op": "approve", "id": req_id, "target": target, "ttl_minutes": ttl, "session_scoped": sess})
      elif cmd == "deny":
          send_once({"op": "deny", "id": args[1]})
      elif cmd == "revoke":
          send_once({"op": "revoke", "id": args[1]})
      elif cmd == "revoke-all":
          send_once({"op": "revoke_all"})
      elif cmd == "lock-event":
          send_once({"op": "lock_event", "trigger": args[1] if len(args) > 1 else "screen lock"})
      elif cmd == "unlock-event":
          send_once({"op": "unlock_event"})
      else:
          sys.stderr.write(f"Unknown command: {cmd}\n")
          sys.exit(2)
      PY
    '';
  };

  macMeshDaemonScript = pkgs.writeShellApplication {
    name = "mac-meshd";
    runtimeInputs = [
      pythonEnv
      leanMeshPkg
      pkgs.iproute2
      pkgs.iputils
      pkgs.wireguard-tools
      pkgs.nftables
      pkgs.util-linux
      pkgs.procps
      pkgs.systemd
      pkgs.libnotify
      pkgs.fprintd
      pkgs.coreutils
    ]
    ++ lib.optional (omarchyShellPkg != null) omarchyShellPkg;
    text = ''
      exec ${pythonEnv}/bin/python3 ${macMeshDaemonPy} "$@"
    '';
  };

  sshdTetherConfig = pkgs.writeText "sshd_tether_config" ''
    Port ${toString cfg.sshPort}
    ListenAddress 10.88.200.1
    HostKey /var/lib/mac-mesh/ssh_host_ed25519_key
    PidFile /run/sshd-tether.pid
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile /run/mac-mesh/authorized_keys
    AllowUsers orb-tether
    UsePAM no
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    AllowTcpForwarding local
    PermitTunnel no
    ClientAliveInterval 20
    ClientAliveCountMax 3
    MaxAuthTries 2
    LogLevel VERBOSE
  '';
in
{
  options.omarchnix.macTether = {
    enable = lib.mkEnableOption "sovereign Touch ID-gated MacBook tether mesh (`wg-macmesh0`), `orb-sandbox` container, confined host SSH, and local Next.js preview bridge";

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Local desktop operator user (defaults to `omarchnix.desktop.user` or `thomas`).";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51889;
      description = "Direct LAN WireGuard UDP port for `wg-macmesh0`.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2224;
      description = "Dedicated `sshd-tether` TCP port bound strictly to `10.88.200.1`.";
    };

    denyGid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 991;
      description = "GID assigned to confined host-SSH tether sessions and dropped on `lean_mesh` / `home_mesh` egress.";
    };

    coreUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional explicit `orb-core` base URL (auto-discovered from `~/.orb/connection.json` when null).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional bearer token file override (auto-discovered from `~/.orb/connection.json` when null).";
    };

    leanMeshPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Override package providing `lean-mesh`.";
    };
  };

  config = lib.mkIf (config.omarchnix.enable && cfg.enable) {
    assertions = [
      {
        assertion = leanMeshPkg != null;
        message = "omarchnix.macTether.enable requires `lean-mesh` package.";
      }
    ];

    users.groups.orb-tether-deny.gid = cfg.denyGid;
    users.groups.orb-tether.gid = 992;

    users.users.orb-tether = {
      uid = 992;
      group = "orb-tether";
      isSystemUser = true;
      home = "/var/empty";
      shell = "${pkgs.bash}/bin/bash";
      description = "Dedicated unprivileged SSH gate user for Touch ID MacBook tether leases";
    };

    security.wrappers.orb-tether-dispatch = {
      source = "${tetherDispatchPkg}/bin/orb-tether-dispatch";
      owner = "root";
      group = "orb-tether";
      permissions = "u+rx,g+x";
      setuid = true;
    };

    environment.systemPackages = [
      macMeshCtlPkg
      leanMeshPkg
    ];

    networking.networkmanager.unmanaged = [
      "interface-name:wg-macmesh0"
      "interface-name:ve-orb-sandbox"
    ];

    environment.etc."NetworkManager/conf.d/98-mac-tether-unmanaged.conf".text = ''
      [keyfile]
      unmanaged-devices=interface-name:wg-macmesh0;interface-name:ve-orb-sandbox
    '';

    networking.firewall = {
      allowedUDPPorts = [ cfg.listenPort ];
      interfaces."wg-macmesh0".allowedTCPPorts = [ cfg.sshPort ];
    };

    # Isolated `systemd-nspawn` sandbox container for default untrusted mission SSH tethers
    containers.orb-sandbox = {
      autoStart = true;
      privateNetwork = true;
      hostAddress = "10.233.2.1";
      localAddress = "10.233.2.2";
      config =
        { pkgs, ... }:
        {
          system.stateVersion = "25.05";
          networking.useHostResolvConf = false;
          services.resolved.enable = true;
          networking.firewall.enable = true;

          users.users.dev = {
            isNormalUser = true;
            uid = 1000;
            home = "/home/dev";
            extraGroups = [ "wheel" ];
          };

          systemd.tmpfiles.rules = [
            "d /workspace 0755 dev users -"
          ];

          environment.systemPackages = with pkgs; [
            bash
            coreutils
            curl
            fd
            git
            gnugrep
            gnumake
            gnused
            jq
            nodejs
            python3
            ripgrep
          ];
        };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/mac-mesh 0700 root root -"
      "d /run/mac-mesh 0755 root root -"
      "d /run/mac-mesh/psks 0700 root root -"
      "d /run/mac-mesh/leases 0700 root root -"
    ];

    systemd.services.mac-meshd = {
      description = "Sovereign MacBook Tether Coordinator (wg-macmesh0 & Touch ID Broker)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      before = [ "sshd-tether.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${macMeshDaemonScript}/bin/mac-meshd";
        ExecStopPost = "${pkgs.bash}/bin/bash -c '${pkgs.nftables}/bin/nft delete table inet mac_mesh 2>/dev/null || true; ${pkgs.iproute2}/bin/ip link del dev wg-macmesh0 2>/dev/null || true'";
        Restart = "always";
        RestartSec = "2s";
      };
    };

    systemd.services.sshd-tether = {
      description = "Isolated OpenSSH Daemon for Sovereign MacBook Tether (10.88.200.1:${toString cfg.sshPort})";
      wantedBy = [ "multi-user.target" ];
      after = [
        "mac-meshd.service"
        "apparmor.service"
      ];
      requires = [ "mac-meshd.service" ];
      preStart = ''
        install -d -m 0700 /var/lib/mac-mesh
        if [ ! -s /var/lib/mac-mesh/ssh_host_ed25519_key ]; then
          ${config.services.openssh.package}/bin/ssh-keygen -q -t ed25519 -N "" -f /var/lib/mac-mesh/ssh_host_ed25519_key
        fi
        chmod 0600 /var/lib/mac-mesh/ssh_host_ed25519_key
        if ! ${pkgs.iproute2}/bin/ip link show dev wg-macmesh0 >/dev/null 2>&1; then
          ${pkgs.iproute2}/bin/ip link add dev wg-macmesh0 type wireguard
        fi
        if ! ${pkgs.iproute2}/bin/ip -4 addr show dev wg-macmesh0 2>/dev/null | grep -q '10\.88\.200\.1'; then
          ${pkgs.iproute2}/bin/ip -4 addr add 10.88.200.1/32 dev wg-macmesh0 2>/dev/null || true
        fi
        ${pkgs.iproute2}/bin/ip link set mtu 1420 up dev wg-macmesh0
      '';
      serviceConfig = {
        Type = "simple";
        ExecStart = "${config.services.openssh.package}/bin/sshd -D -e -f ${sshdTetherConfig}";
        Restart = "always";
        RestartSec = "2s";
      };
    };
  };
}
