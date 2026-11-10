#!/usr/bin/env python3
"""Murmure Settings Window (GTK3 native UI matching SettingsWindow.swift)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from typing import Any, Dict

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
VOICED_DIR = os.path.abspath(os.path.join(THIS_DIR, "..", "voiced"))
for p in (THIS_DIR, VOICED_DIR):
    if p not in sys.path:
        sys.path.insert(0, p)

import gi  # type: ignore

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # type: ignore

import murmure_cli as cli  # noqa: E402
import murmured as md  # noqa: E402
import pipeline as vp  # noqa: E402
import worker as w  # noqa: E402


CSS = b"""
.murmure-card {
  border-radius: 12px;
  padding: 10px 14px;
  background-color: alpha(@theme_fg_color, 0.045);
  border: 1px solid alpha(@theme_fg_color, 0.09);
}
.murmure-badge {
  border-radius: 13px;
  background-color: #1a1a1a;
  color: #ffffff;
  font-weight: 700;
  font-size: 18px;
}
.murmure-caption {
  opacity: 0.65;
  font-size: 12px;
}
"""


class MurmureSettingsWindow(Gtk.Window):
    def __init__(self) -> None:
        GLib.set_prgname("murmure-settings")
        GLib.set_application_name("Murmure")
        super().__init__(title="Murmure")
        self.set_wmclass("murmure-settings", "Murmure")
        self.set_default_size(430, -1)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_border_width(18)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        screen = Gdk.Screen.get_default()
        if screen:
            Gtk.StyleContext.add_provider_for_screen(
                screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        self.store = md.SettingsStore()
        self.capturing = False
        self._updating_ui = False

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(outer)

        # Header
        hdr = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        hdr.set_halign(Gtk.Align.CENTER)
        badge = Gtk.Label(label="|||")
        badge.set_size_request(52, 52)
        badge.get_style_context().add_class("murmure-badge")
        badge.set_halign(Gtk.Align.CENTER)
        hdr.pack_start(badge, False, False, 0)

        title = Gtk.Label()
        title.set_markup("<b><big>Murmure</big></b>")
        hdr.pack_start(title, False, False, 0)

        sub = Gtk.Label(label="Private, on-device dictation")
        sub.get_style_context().add_class("murmure-caption")
        hdr.pack_start(sub, False, False, 0)
        outer.pack_start(hdr, False, False, 2)

        # Section 1: Shortcut & Language
        sec1 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        sec1.get_style_context().add_class("murmure-card")

        sc_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        sc_lbl = Gtk.Label(label="Shortcut")
        sc_lbl.set_xalign(0.0)
        sc_row.pack_start(sc_lbl, True, True, 0)

        self.reset_btn = Gtk.Button(label="↺")
        self.reset_btn.set_tooltip_text("Reset to Fn + Right ⇧")
        self.reset_btn.connect("clicked", self._on_reset_shortcut)
        sc_row.pack_end(self.reset_btn, False, False, 0)

        self.sc_btn = Gtk.Button(label="Fn + Right ⇧")
        self.sc_btn.set_size_request(150, -1)
        self.sc_btn.connect("clicked", self._on_toggle_capture)
        sc_row.pack_end(self.sc_btn, False, False, 0)
        sec1.pack_start(sc_row, False, False, 0)

        lang_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        lang_lbl = Gtk.Label(label="Language")
        lang_lbl.set_xalign(0.0)
        lang_row.pack_start(lang_lbl, True, True, 0)

        self.lang_combo = Gtk.ComboBoxText()
        for lang in vp.LANGUAGES:
            self.lang_combo.append(lang["code"], lang["name"])
        self.lang_combo.connect("changed", self._on_lang_changed)
        lang_row.pack_end(self.lang_combo, False, False, 0)
        sec1.pack_start(lang_row, False, False, 0)

        sec1.pack_start(self._make_switch_row("Open at login", "openAtLogin"), False, False, 0)
        outer.pack_start(sec1, False, False, 0)

        hint = Gtk.Label(label="Tap to start and stop, or hold to talk. Esc cancels, Return commits.")
        hint.set_xalign(0.0)
        hint.get_style_context().add_class("murmure-caption")
        outer.pack_start(hint, False, False, 0)

        # Section 2: Dictation & Vocabulary
        sec2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        sec2.get_style_context().add_class("murmure-card")
        sec2.pack_start(self._make_switch_row("Remove filler words (um, uh, euh)", "removeDisfluencies"), False, False, 0)
        sec2.pack_start(self._make_switch_row("Voice commands (new line, scratch that)", "voiceCommands"), False, False, 0)
        sec2.pack_start(self._make_switch_row("Convert spoken numbers (twenty five → 25)", "convertNumbers"), False, False, 0)
        sec2.pack_start(self._make_switch_row("Stream chunks inline as I speak", "streamInline"), False, False, 0)

        vocab_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vocab_lbl = Gtk.Label(label="Personal vocabulary")
        vocab_lbl.set_xalign(0.0)
        vocab_row.pack_start(vocab_lbl, True, True, 0)
        vocab_btn = Gtk.Button(label="Edit vocabulary.txt…")
        vocab_btn.connect("clicked", self._on_open_vocabulary)
        vocab_row.pack_end(vocab_btn, False, False, 0)
        sec2.pack_start(vocab_row, False, False, 0)
        outer.pack_start(sec2, False, False, 0)

        # Section 3: Runtime status
        self.status_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.status_box.get_style_context().add_class("murmure-card")
        self.status_lbl = Gtk.Label(label="Checking runtime…")
        self.status_lbl.set_xalign(0.0)
        self.status_lbl.set_line_wrap(True)
        self.status_box.pack_start(self.status_lbl, True, True, 0)
        self.dl_btn = Gtk.Button(label="Download Model")
        self.dl_btn.connect("clicked", self._on_download_model)
        self.status_box.pack_end(self.dl_btn, False, False, 0)
        outer.pack_start(self.status_box, False, False, 0)

        self._switches: Dict[str, Gtk.Switch]
        self._refresh_from_daemon()
        self._start_watcher()
        self.connect("destroy", self._on_destroy)

    def _make_switch_row(self, title: str, key: str) -> Gtk.Box:
        if not hasattr(self, "_switches"):
            self._switches = {}
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        lbl = Gtk.Label(label=title)
        lbl.set_xalign(0.0)
        row.pack_start(lbl, True, True, 0)
        sw = Gtk.Switch()
        sw.set_valign(Gtk.Align.CENTER)
        sw.connect("notify::active", self._on_switch_toggled, key)
        self._switches[key] = sw
        row.pack_end(sw, False, False, 0)
        return row

    def _apply_settings_to_ui(self, cfg: Dict[str, Any], snap: Dict[str, Any]) -> None:
        self._updating_ui = True
        try:
            if not self.capturing:
                self.sc_btn.set_label(cfg.get("shortcutLabel") or "Fn + Right ⇧")
            is_default = cfg.get("shortcut") == md.DEFAULT_SHORTCUT
            self.reset_btn.set_sensitive((not is_default) and (not self.capturing))
            self.lang_combo.set_active_id(cfg.get("language") or "en")
            for k, sw in self._switches.items():
                sw.set_active(bool(cfg.get(k)))

            model_ok = bool(snap.get("modelReady", w.model_present(w.resolve_model_dir())))
            evdev_ok = bool(snap.get("evdevReady", True))
            devs = int(snap.get("evdevDevices", 0))
            parts = []
            parts.append("Model ready (Cohere Q4_K Vulkan)" if model_ok else "Speech model not downloaded")
            parts.append(f"Keyboard active ({devs} device{'s' if devs != 1 else ''})" if evdev_ok else "Keyboard input permission pending")
            self.status_lbl.set_text("  ·  ".join(parts))
            if model_ok:
                self.dl_btn.hide()
            else:
                self.dl_btn.show()
        finally:
            self._updating_ui = False

    def _refresh_from_daemon(self) -> None:
        snap = cli.rpc({"op": "status"}, autostart=True)
        cfg = snap.get("settings") or self.store.get()
        self._apply_settings_to_ui(cfg, snap)

    def _push_patch(self, patch: Dict[str, Any]) -> None:
        res = cli.rpc({"op": "update_settings", "settings": patch}, autostart=True)
        cfg = res.get("settings") if res.get("ok") else self.store.update(patch)
        if "openAtLogin" in patch:
            action = "enable" if patch["openAtLogin"] else "disable"
            subprocess.run(
                ["systemctl", "--user", action, "murmure.service"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        self._apply_settings_to_ui(cfg, res)

    def _on_lang_changed(self, combo: Gtk.ComboBoxText) -> None:
        if self._updating_ui:
            return
        code = combo.get_active_id()
        if code:
            cli.rpc({"op": "set_language", "language": code}, autostart=True)

    def _on_switch_toggled(self, sw: Gtk.Switch, _pspec: Any, key: str) -> None:
        if self._updating_ui:
            return
        self._push_patch({key: sw.get_active()})

    def _on_reset_shortcut(self, _btn: Gtk.Button) -> None:
        self._stop_capture()
        self._push_patch({"shortcut": dict(md.DEFAULT_SHORTCUT)})

    def _on_toggle_capture(self, _btn: Gtk.Button) -> None:
        if self.capturing:
            self._stop_capture()
        else:
            self.capturing = True
            self.sc_btn.set_label("Press shortcut…")
            cli.rpc({"op": "capture_shortcut", "enable": True}, autostart=True)

    def _stop_capture(self) -> None:
        if self.capturing:
            self.capturing = False
            cli.rpc({"op": "capture_shortcut", "enable": False}, autostart=False)
            self._refresh_from_daemon()

    def _on_open_vocabulary(self, _btn: Gtk.Button) -> None:
        os.makedirs(vp.voice_home(), mode=0o700, exist_ok=True)
        vpath = os.path.join(vp.voice_home(), "vocabulary.txt")
        if not os.path.exists(vpath):
            with open(vpath, "w", encoding="utf-8") as f:
                f.write("# One proper noun or technical term per line (e.g. Murmure, Omarchnix, PostgreSQL)\n")
        subprocess.Popen(["xdg-open", vpath], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _on_download_model(self, btn: Gtk.Button) -> None:
        btn.set_sensitive(False)
        self.status_lbl.set_text("Downloading Cohere Transcribe Q4_K (~1.21 GiB)…")

        def _dl() -> None:
            rc = cli.download_model()
            GLib.idle_add(self._on_download_done, rc == 0)

        threading.Thread(target=_dl, daemon=True).start()

    def _on_download_done(self, _ok: bool) -> bool:
        self.dl_btn.set_sensitive(True)
        self._refresh_from_daemon()
        return False

    def _start_watcher(self) -> None:
        self._watch_Alive = True

        def _loop() -> None:
            while getattr(self, "_watch_Alive", False):
                s = cli.connect_daemon(autostart=True)
                if s is None:
                    threading.Event().wait(2.0)
                    continue
                try:
                    s.sendall(b'{"op":"watch"}\n')
                    rf = s.makefile("rb")
                    while getattr(self, "_watch_Alive", False):
                        line = rf.readline(65536)
                        if not line:
                            break
                        ev = json.loads(line.decode("utf-8"))
                        GLib.idle_add(self._on_daemon_event, ev)
                except Exception:
                    pass
                finally:
                    try:
                        s.close()
                    except OSError:
                        pass

        threading.Thread(target=_loop, daemon=True).start()

    def _on_daemon_event(self, ev: Dict[str, Any]) -> bool:
        kind = ev.get("event")
        if kind == "shortcut_preview" and self.capturing:
            self.sc_btn.set_label(ev.get("label") or "Press shortcut…")
        elif kind == "shortcut_captured":
            self.capturing = False
            self._refresh_from_daemon()
        elif kind == "shortcut_cancelled":
            self.capturing = False
            self._refresh_from_daemon()
        elif kind == "state" and not self.capturing:
            cfg = ev.get("settings")
            if isinstance(cfg, dict):
                self._apply_settings_to_ui(cfg, ev)
        return False

    def _on_destroy(self, *_args: Any) -> None:
        self._watch_Alive = False
        if self.capturing:
            cli.rpc({"op": "capture_shortcut", "enable": False}, autostart=False)
        Gtk.main_quit()


def main() -> int:
    win = MurmureSettingsWindow()
    if "--check-gtk" in sys.argv:
        win.destroy()
        return 0
    win.show_all()
    win._refresh_from_daemon()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
