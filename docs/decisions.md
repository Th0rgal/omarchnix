# DR — decision records

Numbered, append-only. A decision is never edited after being recorded;
supersede it with a new record.

## DR-1 — NixOS over Omarchy as the end state

Date: 2026-11-05. Status: accepted.

Omarchy 4.5 ships the best out-of-the-box Apple Silicon experience
(Touch ID via Secure Enclave, external displays), but it is Arch-based
and imperative. The target machine is a daily driver; declarative,
rollback-able configuration wins over Touch ID. Omarchy remains the
fallback: its Mac installer is the known-good path if NixOS bring-up
stalls.

## DR-2 — Touch ID deferred, not blocked

Date: 2026-11-05. Status: deferred.

Touch ID on M-series requires the Omarchy kernel fork's Secure Enclave
work, not upstreamed to Asahi. Path if wanted later: package their
kernel tag as a `linux_asahi_omarchy` override on the
`nixos-apple-silicon` kernel plus the userspace helper. Requires
reverse-engineering the userspace contract; pinned to their exact
release tag.

## DR-3 — Rehearse on rented hardware before the Air

Date: 2026-11-05. Status: accepted.

Scaleway Mac mini M2 (€0.17/h, M2 chip — same chip class as the Air)
validates the parts qemu cannot: m1n1 on real BootROM, firmware
extraction from APFS, UEFI standalone install. Provider confirmed
personal-use Linux installs are acceptable; provider-side reset is the
failure recovery. The rehearsal box tests no laptop hardware (no Touch
ID, no speakers, no panel) — those gates only exist on the Air.

## DR-4 — Partition layout for the Air (1 TB)

Date: 2026-11-05. Status: accepted.

- macOS ~120 GB (kept for firmware updates and recovery; not optional)
- shared exFAT ~150 GB (transfer shelf; the only FS both OSes mount
  read-write natively; no journaling, no encryption — nothing precious
  lives here)
- rest: NixOS, LUKS2 + ext4 (software-only encryption; Apple's
  hardware-sealed FileVault keys are unavailable under Asahi)

## DR-6 — Secrets via sops-nix, age root key held by the owner

Date: 2026-11-05. Status: accepted.

Repo contains zero plaintext secrets. sops-nix with an age keypair:
public key committed, private key only on the owner's machines and the
standing builder VM. Rehearsal-box IP and any credentials live in
`secrets/` (encrypted), never in git.

## DR-7 — Container isolation, not VMs (no KVM on Asahi)

Date: 2026-11-05. Status: accepted.

Qubes-style hardware isolation is unavailable: m1n1 owns the
hypervisor and KVM guests are not usable on Apple Silicon today.
Isolation model: declarative `nixos-container`s (systemd-nspawn)
with no-network-by-default and uid-shifted bind mounts, plus bwrap
sandboxing for untrusted `nix develop`. Revisit if KVM lands upstream.

## DR-5 — Boot chain updates stay manual

Date: 2026-11-05. Status: accepted.

`boot.loader.*` stays off in NixOS on Asahi machines. m1n1/U-Boot and
vendor firmware updates go through the documented Asahi installer steps
(`docs/runbook-scaleway.md`), not `nixos-rebuild`, to avoid a
half-updated boot chain that the OS cannot repair itself.

## DR-8 — Omarchy compatibility contract on pure NixOS

Date: 2026-11-06. Status: accepted. Supersedes DR-1's framing of Omarchy solely as an imperative Arch fallback.

`omarchnix` rebrands `asahi-nixos` into a reusable cross-architecture (`aarch64-linux` for Apple Silicon M-series + NVIDIA Grace/DGX Spark, and `x86_64-linux` for workstations/VMs) NixOS + Home Manager distribution layer (`nixosModules.omarchnix`, `homeManagerModules.omarchnix`) with first-class compatibility for the upstream Omarchy (`omacom/omarchy`) ecosystem:

1. **Theme contract (`lib.omarchy.importTheme`):** Parses upstream Omarchy `colors.toml` (and optional `shell.*.toml` overrides) across all 23+ first-party and community themes into a typed Nix palette + `shell.toml` surface token set, driving Hyprland 0.57 Lua, `omarchy-shell` / Waybar, Foot, Fuzzel, Hyprlock, and SVG/PNG wallpapers, plus atomic runtime theme switching (`omarchnix-theme-set` / `omarchy-theme-set`) via `~/.local/state/omarchy/current/theme` and `omarchy-shell` Unix-socket IPC.
2. **Shell & plugin contract (`quickshell` + `omarchy-shell` + `plugins.omarchy.org`):** Packages `quickshell` (Qt 6.12) and the upstream `omarchy-shell` QML tree (`qs.Commons`, `qs.Ui`, first-party plugins, and NixOS FHS shims) alongside a dual-mode `plugins.omarchy.org` loader supporting both Nix-locked declarative plugins (`programs.omarchnix.plugins.locked`, validated at build time for `manifest.json` `schemaVersion == 1`, non-`omarchy.*` reverse-DNS ID, relative entrypoints, and zero symlinks) and user-space runtime plugin management (`omarchnix-plugin`).
3. **Agent-first ergonomics:** Pre-wires coding agents (`opencode`, `claude`, `codex`, `hermes`) with a governed `omarchnix` system skill and `omarchnix check` CLI that runs `nix fmt`, host evaluations, and NixOS VM tests before permitting `nixos-rebuild switch`.

## DR-9 — Proof-carrying Lean 4 userspace (`turbo-lean` + `lean-sys` + `LeanNative`)

Date: 2026-11-06. Status: accepted.

Critical userspace components and system gates in `omarchnix` carry machine-checked proofs and cryptographic build receipts rather than relying on unverified C/shell utilities:

1. **Zero-`sorryAx` + kernel axiom hygiene:** `pkgs.omarchnix.buildVerifiedLeanSys` builds Lean 4 (`v4.35.0`) targets from pinned `Th0rgal/lean-sys` and `Th0rgal/turbo-lean` inputs while enforcing `0` `sorry`/`admit` tokens in source and `Lean.collectAxioms` restricted strictly to `{propext, Quot.sound, Classical.choice}` (`0 sorryAx`, `0 Lean.trustCompiler`, `0 Lean.ofReduceBool`).
2. **Architecture-verified `LeanNative` codegen:** On `aarch64-linux` (Apple M-series / Grace), `LeanNative` (`arm64` / `appleA15`) emits LLVM 18 IR with verified ARMv8.2+/NEON SIMD (`@llvm.aarch64.neon.pmull64`, `@llvm.aarch64.crypto.eor3u.v2i64`, LSE atomics, and SVE2 multi-versioned loops) and verifies ELF64 `EM_AARCH64` / `EM_X86_64` object invariants (`verifyObjectBytesForTarget`).
3. **Signed BLAKE3 + Ed25519 store receipts & live closure audit:** Every derivation built by `pkgs.omarchnix.buildVerifiedLeanSys` writes `<out>/share/omarchnix/receipts/<name>.receipt.json` (binding `turbo-lean` Schema v2 `receipt_blake3`, `interface_hash`, `lean_toolchain`, target binary BLAKE3 digest, `sorry_ax_count = 0`, `codegen_backend = "LeanNative"`, and target ISA features) signed with `ed25519-v1` (`turbo-lean verify-receipt --require-signature`). `omarchnix audit` walks the active NixOS system closure (`/run/current-system` or an explicit store path), recomputes every binary's BLAKE3 digest, and cryptographically verifies every Ed25519 receipt offline in milliseconds.

## DR-10 — Non-IFD plugin manifest evaluation & Waybar/Quickshell dual shell backend

Date: 2026-11-06. Status: accepted.

1. **Pure evaluation for cross-architecture checks (`pluginManifest` passthru):** `lib.omarchy.buildPlugin` parses and validates `manifest.json` (`schemaVersion == 1`, non-`omarchy.*` ID, safe relative entrypoints, and recursive symlink-free source tree) purely at Nix evaluation time and exposes `passthru.pluginManifest` alongside derivation-level enforcement. Home Manager's `programs.omarchnix.plugins.locked` reads `drv.pluginManifest` directly instead of `builtins.readFile "${drv}/manifest.json"`, eliminating Import-From-Derivation (IFD) so `aarch64-linux` host and check evaluations succeed cleanly on `x86_64-linux` builders without remote builders.
2. **NixOS FHS & Quickshell 0.3.2 QML shims:** Upstream `omacom/omarchy` targets Arch FHS paths (`/usr/bin/python3`, `/usr/share/zoneinfo/zone1970.tab`, `/usr/share/omarchy-platform/display-cutouts.json`) and a custom `//@ pragma OmarchyLoadPatch` directive in `shell.qml`. `pkgs/omarchy-shell.nix` strips the custom pragma for stock `quickshell` 0.3.2 (`Qt 6.12`), substitutes Nix store paths for Python 3 and `tzdata`, patches `socat STDIO,shut-none` so `quickshell`'s `SocketServer` receives request lines before EOF, skips privileged `/etc/*/policies/managed` browser-policy writes when no managed browser policy directories exist, installs `omarchy.ttf`, and seeds writable `~/.config/omarchy/shell.json` + `~/.local/state/omarchy/current/theme` during Home Manager activation so `foot`'s `include = "~/.local/state/omarchy/current/theme/foot.ini"` and live `omarchnix theme set` work immediately on first login under both `shellBackend = "omarchy-shell"` and `shellBackend = "waybar"`.

## DR-11 — Binary-cached Nixpkgs `lean4`, portable ARMv8.2+ NEON SIMD, and signed binary-hash receipt binding

Date: 2026-11-06. Status: accepted. Refines DR-9's build and receipt-authority mechanics.

1. **Binary-cached Nixpkgs `lean4` compatibility in `turbo-lean`:** Nixpkgs builds `lean4` (`v4.35.0`) with `-DUSE_GITHASH=OFF` and `System.Platform.target == ""` so binaries pull directly from `cache.nixos.org` without compiling Lean from C++ source. `pkgs/turbo-lean.nix` applies a minimal compile-time patch to `module_builder.rs` (`NIX_PINNED_LEAN_BIN` + `NIX_VERIFIER_SYS_PATH`) that accepts empty git/target strings when `--version` matches the pinned `lean-toolchain` release while keeping `.olean` skew checks, `Lean.collectAxioms` inspection (`0 sorryAx`, `0 Lean.trustCompiler`, `0 Lean.ofReduceBool`), and `audit-spec` tightness gates strictly fail-closed.
2. **Portable ARMv8.2+ `aarch64-linux` ELF64 SIMD lowering:** Upstream `lean-native compile-llvm --arch macos-arm64` selects the Apple Silicon `appleA15` ISA profile (`@llvm.aarch64.neon.pmull64` + `@llvm.aarch64.crypto.eor3u.v2i64`), whereas `--arch arm64` falls back to scalar shifts (`isaMask = 1`) and `FEAT_SHA3` (`eor3`) is optional on generic ARMv8.2 cloud runners (`ubuntu-24.04-arm` Neoverse-N1). On `aarch64-linux`, `buildVerifiedLeanSys` lowers through `--arch macos-arm64` to preserve hardware NEON polynomial carryless multiplication (`pmull v0.1q, v1.1d, v0.1d`), rewrites the module header to `aarch64-unknown-linux-gnu` (`e-m:e-...`), lowers `@llvm.aarch64.crypto.eor3u.v2i64` to two associative `<2 x i64>` `xor` instructions (matching `OmarchnixGate.SimdRef.eor3`), and compiles with `-march=armv8.2-a+crypto+lse` so the identical ELF64 `EM_AARCH64` archive executes natively on Apple M-series, NVIDIA Grace / DGX Spark, and Neoverse-N1 CI runners.
3. **Co-tampering defense & signing authority boundary (DR-6):** Before invoking `turbo-lean ci-verify --mode trusted`, `buildVerifiedLeanSys` runs `patchelf --shrink-rpath`, sets `dontStrip = true; dontPatchELF = true;`, and writes `BuildArtifacts/BinaryBlake3_<hex>.lean` and `BuildArtifacts/ArchiveBlake3_<hex>.lean` so the exact ELF64 binary and `LeanNative` `.a` BLAKE3 digests are hashed inside `per_file_interfaces` -> `receipt_blake3` -> `ed25519_signature` (defeating simultaneous tampering of the binary and top-level `.binary_blake3`). Inside pure Nix derivations (which hold zero secret keys per DR-6), default deterministic signing seeds are public test/build inputs, not operator authentication: their signatures detect corruption relative to a trusted build artifact, but anyone can regenerate them. Never put a private signing seed in Nix expressions or `/nix/store` (`receiptSigningSeedHex` is strictly for public deterministic/test seeds); operator authority requires externally isolated release signing and auditing closures against an independently trusted public key via `omarchnix audit --pubkey <hex64>`. Likewise, the Lean admission proof covers the Boolean admission policy (`OmarchnixGate.Spec`), not the JSON parser, compiler, cryptographic primitives, or whole operating system.

## DR-12 — Scaleway `M2-L-ASAHI` rehearsal, never a clean halt

Date: 2026-11-06. Status: accepted. Refines DR-3 and DR-5.

1. **macOS Apple Silicon cannot host the Asahi installer on Scaleway.** `M1-M` (`fr-par-3`), `M2-M`, and `M2-L` (`fr-par-1`) expose only macOS `screensharingd` VNC. There is no hardware KVM, and MDM blocks 1TR Recovery and `bputil`, so `curl https://alx.sh | sh` cannot complete. `M4-*` has no Asahi support. Governed Orb probes on 2026-11-06 rejected `size = "M2-L-ASAHI"` as unknown to the Core allowlist (`action_id` `307153ce-37b8-4e9b-b884-ec283b962bba`), `M2-M` as `HTTP 503 out_of_stock` (`action_id` `86c424f5-703b-4fb9-b856-2b67029b8944`), and `M2-PRO` as an invalid `server_type` (`action_id` `95066a1a-027a-4d42-adb7-2d0283685619`).
2. **The rehearsal SKU is `M2-L-ASAHI`.** Scaleway's Mac mini M2 Pro 10-core / 16 GiB / 412 GB in `fr-par-1` ships Fedora Asahi Remix 42 with `m1n1`, U-Boot, and `/boot/asahi` vendor firmware already installed, at €0.21/h with a 0-hour minimum lease. `hosts/rehearsal.nix` mounts that firmware tree read-only and `noauto`. NixOS must not format it or enable `boot.loader.*`.
3. **Power safety is mandatory.** Scaleway has no out-of-band power control. `systemd-poweroff.service` and `systemd-halt.service` are redirected to `systemctl --force --force reboot`; sleep, suspend, hibernate, and hybrid-sleep are disabled. A clean halt waits for a provider reset and is a failed rehearsal, not a recovery step.
4. **Access uses the committed throwaway rehearsal key only.** Password authentication stays off. The public key `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIrDpszSSJT9ZfrkTp/pPvA9vfzV0QGizKDTP2HEBG4Q` is the only authorized key. Its private half never enters git (DR-6).

## DR-13 — De-vacuous Lean verification and native Linux ARM64 codegen

Date: 2026-11-06. Status: accepted. Refines DR-9 and DR-11.

1. **Receipt extraction is total and fail-closed.** `OmarchnixGate.Spec` and `OmarchnixGate.Main` reject missing fields, duplicate keys (including `\u` escapes), wrong JSON types, malformed objects, and duplicate CLI flags. `--actual-binary-blake3` and `--crypto-sig-ok` are mandatory. No `.getD` default can admit a hostile receipt.
2. **Plugin and sandbox gates are verified admission policies.** `OmarchnixGate.PluginGate` admits only schema version 1, a reverse-DNS id outside `omarchy.*`, and relative entrypoints with no `..`, leading `/`, or NUL. `OmarchnixGate.SandboxGate` admits `bwrap` and `nixos-container` mount tables only when every read-write mount stays under a declared workspace root and `/run/secrets`, `/root/.ssh`, `/home/*/.ssh`, `/etc/shadow`, and `/nix/var/nix/daemon-socket` stay unmounted unless an explicit capability grants them.
3. **Trust is externally pinned.** `security.omarchnix.trustedReceiptKeys` is empty by default and `allowDevReceiptKeys` is false. `omarchnix audit` fails closed unless a pinned Ed25519 key or an explicit `--allow-dev-keys` flag is supplied. Required critical packages must each have a verified receipt; finding some other receipt is not success. Private signing seeds stay out of the Nix store (DR-6). Detached `omarchnix-receipt-attestation-v1` files are optional operator evidence, not a claim that the Nix build itself authenticated the signer.
4. **`linux-arm64` is a first-class LeanNative target.** `pkgs/turbo-lean.nix` patches LeanNative with `--isa armv8.2-crypto`, emitting `aarch64-unknown-linux-gnu` and `e-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128`. `@llvm.aarch64.neon.pmull64` is enabled with `+aes,+sha2`; `@llvm.aarch64.crypto.eor3u.v2i64` stays behind explicit `FEAT_SHA3`. `buildVerifiedLeanSys` no longer rewrites `macos-arm64` IR with `sed`. The resulting objects run on Apple M-series, NVIDIA Grace, and Neoverse-N1.

## DR-14 — Retire Lean 4 (`lean-sys` / `turbo-lean` / `omarchnix-receipt-gate`) scaffolding

Date: 2026-11-07. Status: accepted. Supersedes DR-9, DR-11, and DR-13.

`omarchnix-receipt-gate` was the sole package built through `buildVerifiedLeanSys`: it existed only to verify its own receipt, delegated hashing and signature verification to external `b3sum` and `openssl` processes, and duplicated plugin and container invariants already enforced declaratively in Nix (`lib.omarchy.buildPlugin` in `lib/omarchy.nix`, `omarchnix-plugin`, and `modules/containers.nix` / `modules/hardening.nix`). Carrying `lean-sys`, `turbo-lean`, `lean4`, LLVM 18 `LeanNative` cross-architecture patches, `security.omarchnix.*` receipt keys, `omarchnix audit` / `omarchnix sandbox`, and dedicated CI builds added heavy toolchain maintenance and build cost with zero operational leverage for a declarative NixOS + Omarchy workstation config. Lean 4 inputs, derivations, module options, CLI subcommands, and receipt checks are removed cleanly in favor of pure Nix evaluation/build gates and NixOS VM tests.

## DR-15 — Aurora Silicon (`nixos-aurora`) Secure Enclave & Touch ID Integration Path for `m2air`

Date: 2026-11-08. Status: planned (opt-in after initial `m2air` cutover). Refines DR-2.

Upstream Omarchy M's Apple Silicon Secure Enclave Processor (SEP) and Touch ID stack is published openly as NixOS modules and binary-cached derivations in [`aurora-silicon/nixos-aurora`](https://github.com/aurora-silicon/nixos-aurora) (`https://aurorasilicon.org/nixos-aurora/cache`, public key `aurora-nixos-1:ZxmPNEWsrzgXai+W+dlTE8cachb1xaatfXKK8X8go14=`):

1. **Architecture on M2 Air (`J413`, `T8112` warm-attach SEP):**
   - **Kernel (`linux-aurora` 7.3.0):** Ships the `apple_sep` module (`/dev/sep-bio`, `/dev/sep-key`) with APFS `iBootSystemContainer` xART GigaLocker ownership checks and `xart_guard = 1` by default on M2 (`T8112` warm-attach performs zero pre-Linux xART writes during Linux keybag creation, preserving macOS Touch ID records).
   - **Boot chain requirement:** `linux-aurora` 7.3.0 builds with `CONFIG_ARM64_CTXR_EXECMEM=y` and requires Aurora's monitor-free Stage 1/2 bootloader (`aura` `1.0.0b8+` + `uboot-aurora`), not stock upstream `m1n1`.
   - **Userspace & PAM (`modules/sep.nix`, `modules/fido.nix`):** Overlays `aurora-sep` (`aurora-touchid-setup`, `aurora-sep-load`, `aurora-sep-ready`), `aurora-xart`, `aurora-touchid-rearm` (`pam_aurora_touchid.so` re-arming Touch ID after first post-boot password, matching macOS behavior), patched `libfprint` (`1.94.100-apple-sep`) + `fprintd --no-timeout` (`sudo`, `polkit-1`, and `hyprlock` via `security.pam.services.hyprlock.fprintAuth = true`), plus optional `aurora-fido` (`aurora-fidod` exposing Touch ID + `/dev/sep-key` as a native `/dev/uhid` FIDO2/WebAuthn passkey & `ecdsa-sk` authenticator).
2. **Adoption sequence (preserving DR-5 BootROM safety):**
   - **Step 1 (initial cutover):** Install `m2air` on the battle-tested `nixos-apple-silicon` kernel + `alx.sh` boot chain first so dual-boot, LUKS2 `cryptroot`, Wi-Fi, DSP audio, and `omarchy-shell` are verified cleanly.
   - **Step 2 (opt-in `omarchnix.hardware.m2air.sep.enable`):** Add `nixos-aurora` as an optional flake input/overlay paired with an explicit `aura` Stage 1/2 transition runbook, enabling Touch ID for `sudo`, `polkit`, `hyprlock`, and `aurora-fido` WebAuthn passkeys once Stage 1 is provisioned to `aura`.


## DR-16 — Ship Aurora Silicon (`nixos-aurora`) SEP, Touch ID & FIDO2 Enabled on `m2air`

Date: 2026-11-08. Status: accepted. Supersedes DR-2's deferral and DR-15's two-step staging.

Direct inspection of `AsahiLinux/m1n1` (`src/main.c`, `src/asc.c`, `src/chainload.c`), `aurora-silicon/aura` (`src/kboot.c`, `src/ctxr_exec.c`), `aurora-silicon/linux` (`drivers/soc/apple/{sep.rs,xart_store.rs}`), and `aurora-silicon/nixos-aurora` (`4b025a0cfd35bede6bc87a50fcce6e2a95170f39`) established that `m2air` (`Mac14,2` / `J413`, `T8112`) can run the full Secure Enclave + Touch ID + FIDO2 stack out of the box from day one:

1. **Stage 1 compatibility (`alx.sh` Stage 1 -> `aura` Stage 2):** Stock `alx.sh` `m1n1` Stage 1 sends zero ASC mailbox commands to `/arm-io/sep` during `chainload_load()`. Installing the checked `system.build.auroraStage2` (`aura` `1.0.0b8` + `linux-aurora` `7.3.0` DTBs + `uboot-aurora` `2026.07`) to `/boot/m1n1/boot.bin` via `omarchnix-install-stage2` (preserving `/boot/m1n1/boot.bin.pre-aurora`) preserves `T8112`'s iBoot warm SEP registration and forwards `/chosen/apfs-preboot-uuid` without touching Stage 1 or NVRAM.
2. **Binary-cache identity:** `nixosConfigurations.m2air` overlays `nixos-aurora.inputs.apple-silicon.overlays.default` + `nixos-aurora.overlays.default` on the shared `nixpkgs` lock (`1d060086...`) and configures `https://aurorasilicon.org/nixos-aurora/cache`, achieving 100% store-path binary cache substitution for `linux-aurora` `7.3.0`, `aura`, `uboot-aurora`, `mesa` `26.3.0`, `aurora-sep`, `libfprint`, `fprintd`, `aurora-touchid-rearm`, `aurora-fido`, and `aurora-xart`.
3. **GPT & PAM resilience (`modules/aurora-sep.nix`):**
   - `61-omarchnix-iboot-isc.rules` maps GPT partition type `69646961-6700-11AA-AA11-00306543ECAC` (`Apple_APFS_ISC`) to `/dev/disk/by-partlabel/iBootSystemContainer` even when factory macOS GPT tables leave `PartName` blank.
   - Touch ID (`pam_fprintd.so`) is enabled on `sudo`, `polkit-1` (with `omarchy-hw-laptop-closed` clamshell bypass), `hyprlock`, and `omarchy-lock-fingerprint` (for `omarchy-shell`'s native Quickshell lock screen), while `sshd`, `login`, and `su` remain strictly non-fingerprint.
   - `pam_aurora_touchid.so` re-arming is wired after `pam_unix.so` on `sudo`, `polkit-1`, `login`, `hyprlock`, and `omarchy-lock-password`, matching macOS's `require_password_after_boot = yes` policy.
    - `aurora-fidod` (`/dev/uhid`) runs by default (`omarchnix.hardware.m2air.touchId.fido.enable = true`) so Brave, Firefox, Orb WebAuthn passkeys, and `ssh-keygen -t ecdsa-sk` authenticate via Touch ID + Secure Enclave.

## DR-17 — UUID-based Asahi disk layout (no `shared` exFAT) and staged `m2air` -> `m2air-aurora` cutover

Date: 2026-11-09. Status: accepted. Supersedes DR-4's `shared` exFAT partition/label assumptions and refines DR-16's first-boot staging.

1. **Match the actual Apple/Asahi GPT layout by UUID, never GPT `PartName` or partition number (`modules/disko-m2air.nix`):**
   - `alx.sh` on the target MacBook Air M2 leaves `nvme0n1p4` (EFI FAT32) and `nvme0n1p6` (Linux LUKS2) with empty GPT partition names (`PARTLABEL`), places `RecoveryOSContainer` (macOS Recovery) at `nvme0n1p5`, and has no `150 GiB` exFAT partition.
   - The `shared` partition declaration and `/mnt/shared` mount are removed completely, along with the dangerous `mkfs.exfat ... /dev/nvme0n1p5` command in `docs/install-m2air.md`.
   - `/boot` mounts `/dev/disk/by-uuid/C650-1003` (`vfat`, `fmask=0077,dmask=0077`) and `boot.initrd.luks.devices.cryptroot.device` targets `/dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9` -> `/dev/mapper/cryptroot` (`ext4` on `/`), keeping boot independent of GPT labels and partition numbering while `disko.devices.disk.nvme0n1.destroy = false` and `preCreateHook` refuse destructive `disko` formatting on live Apple Silicon disks.
2. **Validate ordinary NixOS boot before applying Aurora Stage 2 (`m2air` vs `m2air-aurora`):**
   - `nixosConfigurations.m2air` (`omarchnix.hardware.m2air.touchId.enable = false`) uses stock `nixos-apple-silicon` and boots directly from `alx.sh`'s untouched `/boot/m1n1/boot.bin` for initial `nixos-install` verification.
    - `nixosConfigurations.m2air-aurora` enables the `nixos-aurora` overlay, `linux-aurora` `7.3.0`, SEP/Touch ID, and FIDO2 (`omarchnix.hardware.m2air.touchId.enable = true`), applied via `nixos-rebuild boot --flake .#m2air-aurora && omarchnix-install-stage2 /boot` once baseline NixOS boot is confirmed on the Air.

## DR-18 — Remove `disko` GPT declarations in favor of pure NixOS `fileSystems` + `initrd.luks` (`modules/filesystems-m2air.nix`)

Date: 2026-11-09. Status: accepted. Refines DR-17 and retires `disko` on Apple Silicon dual-boot hardware.

1. **Zero partition-table / formatting capability in NixOS (`modules/filesystems-m2air.nix`):**
   - `disko`'s dual-boot GPT handling is unsafe on Apple Silicon (`iBootSystemContainer`, APFS containers, `alx.sh` stub, and `RecoveryOSContainer`). Even with `destroy = false`, carrying `disko` GPT `ESP` and `cryptroot` partition definitions generated `system.build.{destroyFormatMount,formatMount,diskoScript}` scripts capable of running `sgdisk`, `mkfs.vfat`, and `cryptsetup luksFormat` against `/dev/nvme0n1`.
   - `disko` (`inputs.disko`, `diskoConfigurations.m2air`, `packages.*.disko`, `modules/disko-m2air.nix`) is removed completely and replaced with `modules/filesystems-m2air.nix`, declaring strictly `boot.initrd.luks.devices.cryptroot` (`/dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9` -> `/dev/mapper/cryptroot`) and `fileSystems` (`/` ext4, `/boot` `/dev/disk/by-uuid/C650-1003` vfat `fmask=0077,dmask=0077`). `tests/security.nix` asserts `!(m2airConfig ? disko)` and `!(m2airConfig.system.build ? destroyFormatMount)`.
2. **Deferred GPT physical-order sorting (`p6` before `p5`):**
   - Because free space lay physically before `nvme0n1p5` (`RecoveryOSContainer`), `nvme0n1p6` precedes `p5` on disk. Sorting GPT partition entries (`gdisk` `s`) renumbers `p5`/`p6` and is deferred to a separate post-install maintenance window with a verified backup (`docs/install-m2air.md` §5); UUID-only NixOS mounts remain unaffected by partition renumbering.

## DR-19 — Removable ARM64 UEFI GRUB on `m2air` ESP (`BOOTAA64.EFI`), preserving `m1n1/boot.bin` and initrd-only Argon2id LUKS2

Date: 2026-11-09. Status: accepted. Refines DR-5, DR-17, and DR-18.

1. **Root cause on live `m2air` cutover:**
   - With `boot.loader.grub.enable = false` and `boot.loader.systemd-boot.enable = false` hardcoded in `hosts/common.nix` and `modules/omarchnix.nix` (`profile = "asahi"`), `nixos-install --flake .#m2air` wrote the NixOS system closure to `/dev/mapper/cryptroot` (`ext4`) but emitted `"do not know how to make this configuration bootable; please enable a boot loader"`, leaving `/mnt/boot` (`UUID=C650-1003`) with no `EFI/BOOT/BOOTAA64.EFI`, `grub/grub.cfg`, or `/boot/kernels/*` for U-Boot to chainload.
2. **Two-stage boot ownership (`Apple iBoot -> m1n1 -> U-Boot -> UEFI GRUB -> Linux + initrd`):**
   - `hosts/common.nix` and `modules/omarchnix.nix` (`profile = "asahi"`) relax `boot.loader.{systemd-boot,grub}.enable` and `boot.loader.efi.canTouchEfiVariables` to `lib.mkDefault false` so `rehearsal` and generic `asahi` consumers still keep `boot.loader.*` off by default.
   - `hosts/m2air.nix` (inherited by `m2air-aurora`, with Aurora Stage 2 kept opt-in/deferred on `m2air`) enables removable ARM64 UEFI GRUB only: `boot.loader.grub = { enable = true; device = "nodev"; efiSupport = true; efiInstallAsRemovable = true; enableCryptodisk = false; configurationLimit = 2; extraFiles = lib.mkForce { }; };` with `boot.loader.efi = { canTouchEfiVariables = false; efiSysMountPoint = "/boot"; };` and `boot.loader.systemd-boot.enable = false;`.
   - Clearing `boot.loader.grub.extraFiles = lib.mkForce { }` overrides `nixos-apple-silicon`'s `boot-m1n1` `extraFiles."m1n1/boot.bin"` copy so `nixos-install` and `nixos-rebuild` never overwrite `alx.sh`'s `/boot/m1n1/boot.bin` or `/boot/vendorfw/firmware.cpio` (leaving Aurora Stage 2 exclusively to explicit, backup-preserving `omarchnix-install-stage2 /boot` in §4).
3. **Initrd-only Argon2id LUKS2 unlock & ESP capacity budget (~353 MiB free on 477 MiB FAT32 ESP):**
   - `enableCryptodisk = false` ensures GRUB reads only unencrypted FAT32 `/boot` (`UUID=C650-1003`) and never attempts Argon2id LUKS2 decryption; Linux stage-1 `initrd` (`systemd-cryptsetup` + `dm_crypt` + `nvme_apple` + `dockchannel-hid` + `hid_apple`) unlocks `/dev/disk/by-uuid/aa0403dd-9917-49e1-85b1-46b21b39f2d9` -> `/dev/mapper/cryptroot`.
   - `configurationLimit = 2` bounds `/boot/kernels/` to at most two generations and relies on `install-grub.pl` automatic pruning of older `/boot/kernels/*` entries on every rebuild so future `nixos-rebuild switch`/`boot` runs stay well inside the ~353 MiB free ESP budget.

