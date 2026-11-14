{
  config,
  lib,
  pkgs,
  ...
}:
let
  enabled = !(config ? omarchnix) || !config.omarchnix.enable || config.omarchnix.hardening.enable;
  firewallExceptions = {
    tcp = [
      22
    ];
    udp = [ ];
    trustedInterfaces = [ "lo" ];
  };

  sshdPackage = config.services.openssh.package;
  sshdRules = pkgs.apparmorRulesFromClosure { name = "sshd"; } (
    [
      sshdPackage
      pkgs.glibc
      pkgs.linux-pam
      pkgs.systemd
    ]
    ++ config.system.nssModules.list
  );
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = config.services.openssh.settings.PasswordAuthentication == false;
        message = "hardening invariant violated: services.openssh.settings.PasswordAuthentication must remain false.";
      }
      {
        assertion = config.services.openssh.settings.KbdInteractiveAuthentication == false;
        message = "hardening invariant violated: services.openssh.settings.KbdInteractiveAuthentication must remain false.";
      }
      {
        assertion = config.services.openssh.settings.PermitRootLogin == "no";
        message = "hardening invariant violated: services.openssh.settings.PermitRootLogin must remain \"no\".";
      }
    ];

    services.openssh = {
      openFirewall = false;
      settings = {
        PermitRootLogin = "no";
        PermitEmptyPasswords = false;
        X11Forwarding = lib.mkDefault false;
        AllowAgentForwarding = lib.mkDefault false;
        MaxAuthTries = lib.mkDefault 3;
      };
    };

    networking.firewall = {
      enable = true;
      allowPing = false;
      checkReversePath = "strict";
      trustedInterfaces = lib.mkForce firewallExceptions.trustedInterfaces;
      allowedTCPPorts = firewallExceptions.tcp;
      allowedUDPPorts = firewallExceptions.udp;
      allowedTCPPortRanges = [ ];
      allowedUDPPortRanges = [ ];
      extraCommands = lib.mkBefore ''
        ip6tables -w -I nixos-fw 1 -p icmpv6 --icmpv6-type echo-request ! -i lo -j nixos-fw-refuse
      '';
      extraStopCommands = lib.mkAfter ''
        ip6tables -w -D nixos-fw -p icmpv6 --icmpv6-type echo-request ! -i lo -j nixos-fw-refuse 2>/dev/null || true
      '';
    };

    security.sudo.execWheelOnly = true;

    security.apparmor = {
      enable = true;
      killUnconfinedConfinables = true;
      policies."bin.sshd" = lib.mkIf config.services.openssh.enable {
        state = "enforce";
        profile = ''
          abi <abi/4.0>,
          include <tunables/global>

          profile sshd ${sshdPackage}/bin/sshd flags=(attach_disconnected) {
            include <abstractions/base>
            include <abstractions/authentication>
            include <abstractions/nameservice>
            include <abstractions/wutmp>
            include "${sshdRules}"

            capability audit_write,
            capability chown,
            capability dac_override,
            capability dac_read_search,
            capability fowner,
            capability fsetid,
            capability kill,
            capability net_bind_service,
            capability setgid,
            capability setuid,
            capability sys_chroot,
            capability sys_ptrace,
            capability sys_resource,
            capability sys_tty_config,

            network inet stream,
            network inet6 stream,
            network inet dgram,
            network inet6 dgram,
            network netlink raw,
            network unix stream,
            network unix dgram,

            signal (send, receive),
            ptrace (read, trace) peer=sshd,

            ${sshdPackage}/bin/sshd mr,
            ${sshdPackage}/libexec/sshd-session mrCx -> sshd_auth_gate,
            ${sshdPackage}/libexec/sshd-auth mrix,

            /etc/** r,
            /nix/store/** r,
            /nix/store/*/lib/**.so* mr,
            /proc/** r,
            owner /proc/*/oom_score_adj rw,
            owner /proc/*/loginuid rw,
            owner /proc/*/uid_map r,
            owner /proc/*/gid_map r,
            /sys/fs/cgroup/** r,
            /run/** rw,
            /var/empty/ r,
            /var/empty/** r,
            /var/lib/mac-mesh/ r,
            /var/lib/mac-mesh/ssh_host_ed25519_key* r,
            /dev/null rw,
            /dev/zero r,
            /dev/urandom r,
            /dev/random r,
            /dev/ptmx rw,
            /dev/pts/* rw,
            /dev/tty rw,
            /home/*/.ssh/ r,
            /home/*/.ssh/authorized_keys* r,
            /root/.ssh/ r,
            /root/.ssh/authorized_keys* r,

            profile sshd_auth_gate flags=(attach_disconnected) {
              include <abstractions/base>
              include <abstractions/authentication>
              include <abstractions/nameservice>
              include <abstractions/wutmp>
              include "${sshdRules}"

              capability audit_write,
              capability chown,
              capability dac_override,
              capability dac_read_search,
              capability fowner,
              capability fsetid,
              capability kill,
              capability net_bind_service,
              capability setgid,
              capability setuid,
              capability sys_chroot,
              capability sys_ptrace,
              capability sys_resource,
              capability sys_tty_config,

              network inet stream,
              network inet6 stream,
              network inet dgram,
              network inet6 dgram,
              network netlink raw,
              network unix stream,
              network unix dgram,

              signal (send, receive),

              ${sshdPackage}/libexec/sshd-session mr,
              ${sshdPackage}/libexec/sshd-auth mrix,
              ${sshdPackage}/libexec/sftp-server PUx,
              /run/wrappers/bin/* mrix,
              /run/wrappers/wrappers.*/unix_chkpwd mrix,
              /run/wrappers/wrappers.*/* mrix,
              /run/current-system/sw/bin/* Uxr,
              /nix/store/*/bin/* Uxr,
              /etc/profiles/per-user/*/bin/* Uxr,

              /etc/** r,
              /nix/store/** r,
              /nix/store/*/lib/**.so* mr,
              /proc/** r,
              owner /proc/*/oom_score_adj rw,
              owner /proc/*/loginuid rw,
              owner /proc/*/limits r,
              /sys/fs/cgroup/** rw,
              /run/** rw,
              /var/log/lastlog rw,
              /var/log/btmp rwk,
              /var/log/wtmp rwk,
              /var/empty/ r,
              /var/empty/** r,
              /var/lib/mac-mesh/ r,
              /var/lib/mac-mesh/ssh_host_ed25519_key* r,
              /dev/null rw,
              /dev/zero r,
              /dev/urandom r,
              /dev/random r,
              /dev/ptmx rw,
              /dev/pts/* rw,
              /dev/tty rw,
              /home/*/.ssh/ r,
              /home/*/.ssh/authorized_keys* r,
              /root/.ssh/ r,
              /root/.ssh/authorized_keys* r,
            }
          }
        '';
      };
    };

    systemd.services.sshd = lib.mkIf config.services.openssh.enable {
      after = [ "apparmor.service" ];
      requires = [ "apparmor.service" ];
    };

    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      "kernel.yama.ptrace_scope" = 1;
      "kernel.sysrq" = 0;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      "fs.suid_dumpable" = 0;
      "net.ipv4.ip_forward" = 0;
      "net.ipv6.conf.all.forwarding" = 0;
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.tcp_rfc1337" = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.default.accept_source_route" = 0;
    };
  };
}
