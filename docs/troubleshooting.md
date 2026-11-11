# Troubleshooting

Symptom-first notes for problems that are easy to hit on a fresh install.
Each entry states the symptom, the cause, and the fix.

## The whole screen shows "lockscreen app died"

**Symptom:** after the session idles (or after `SUPER + ESCAPE`), the desktop is
replaced by a Hyprland banner saying the lockscreen app died, and the session
cannot be used.

**Cause:** the locker took the `ext-session-lock` surface and then exited, so
Hyprland keeps the surface blocked. `hyprlock` 0.9.x does this on some Apple
Silicon hosts: it starts, runs its PAM conversation, and exits immediately.

**Fix (recover now):**

```console
hyprctl eval "hl.clear_crashed_lockscreen()"
```

**Fix (permanently):** omarchnix uses the `omarchy-shell` lock service instead of
`hyprlock`, both for the idle timeout and for `SUPER + ESCAPE`:

```console
omarchy-shell lock lock
```

## The password is requested again and again

**Symptom:** the lock screen appears every 30–60 s, or right after every unlock.

**Cause:** two independent idle lockers were active at the same time. `hypridle`
sent `loginctl lock-session` while `omarchy-shell`'s idle service also locked the
screen, so each unlock was immediately followed by a new lock request.

**Fix:** keep a single lock owner. Idf hypridle is enabled, do not add a
`loginctl lock-session` listener and do not set `before_sleep_cmd` to
`loginctl lock-session`; the bundled `services.hypridle` configuration in
`home/hypridle.nix` only handles brightness, DPMS and suspend, and the shell
owns locking.

To check who is locking:

```console
journalctl --user -S "-10min" | grep -E "session got locked|lock-requested"
```

## `home-manager` activation fails with "would be clobbered"

**Symptom:** `home-manager-<user>.service` fails and the new configuration is not
applied:

```
Existing file '/home/<user>/.config/hypr/hypridle.conf' would be clobbered by backing up
```

**Cause:** the file already exists and is not a Home Manager symlink (hand-written
or produced by another tool).

**Fix:** omarchnix sets `home-manager.backupFileExtension = "hm-bak"` by
default, so pre-existing files are renamed to `<file>.hm-bak` on activation.
If you override `home-manager` options yourself, keep that setting (or use
`home-manager.backupFileExtension`/`force = true`) rather than deleting the files.

## `nix copy --to ssh-ng://host` says "lacks a signature by a trusted key"

**Symptom:** pushing a closure to another machine fails even though SSH works.

**Cause:** the remote `nix.settings.trusted-users` only contains `root`, so
non-root imports of unsigned paths are refused.

**Fix:** use `scripts/remote-switch.sh`, which builds locally, exports only the
missing store paths and imports them as root:

```console
scripts/remote-switch.sh m2air thomas@192.168.1.165
```

Alternatively add your user to `nix.settings.trusted-users` on the host (this
grants that account the ability to add arbitrary store contents).

## `gsettings` cannot find `org.gnome.desktop.interface`

**Symptom:** theme helpers print `No such schema "org.gnome.desktop.interface"`
even though `gsettings-desktop-schemas` is installed.

**Cause:** the schemas live under
`$out/share/gsettings-schemas/gsettings-desktop-schemas-*/glib-2.0/schemas`, and
the GLib build in use does not discover that layout through `XDG_DATA_DIRS`.

**Fix:** point `GSETTINGS_SCHEMA_DIR` at that directory. `pkgs/omarchy-shell.nix`
already does this in the `omarchy-shell` wrapper.

## Touch ID / fprintd prompts appear on the lock screen but never match

Check the PAM stack for the locker before the SEP is ready:

```console
journalctl -b | grep -E "pam_unix|fprintd"
omarchnix-touchid-status
```

`fprintd` needs the Aurora Stage 2 bootloader (`omarchnix-install-stage2`) and a
few seconds after boot before `/dev/sep-bio` is usable. Disable the fingerprint
prompt in the locker configuration if the device is not enrolled yet.
