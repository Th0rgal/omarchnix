#!/usr/bin/env python3
"""Patch Omarchy's default/hypr/monitor-settings.lua to prevent transient monitor overlap.

When an external monitor (e.g. DP-2 at 0x0) is plugged in while eDP-1 was shifted to 0x0
by single-monitor origin normalization, applying only DP-2 first puts DP-2 at 0x0 on top
of eDP-1 and triggers Hyprland's "Monitor DP-2 overlaps with eDP-1" warning.

This patch:
1. Applies saved rules for all connected monitors on `monitor.added` (not just the newly
   added one), ordering monitors moving AWAY from 0x0 first and 0x0 monitors second.
2. Guards against two simultaneously connected monitors sharing the exact same saved
   position (falling back to `auto` for the second one).
"""

import pathlib
import sys


def replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f"Expected 1 match for {label}, found {count}")
    return src.replace(old, new, 1)


def main() -> None:
    out_dir = pathlib.Path(sys.argv[1])
    ms_lua = out_dir / "default" / "hypr" / "monitor-settings.lua"
    src = ms_lua.read_text(encoding="utf-8")

    old_apply = """function M.apply(loading, only)
  local settings = load()
  if next(settings) == nil then
    return
  end

  local identities = o.workspaces.identities()
  for _, monitor in ipairs(hl.get_monitors()) do
    local saved = settings[identities[monitor.name]]
    if not monitor.is_mirror and saved and (not only or monitor.name == only)
        and (loading or not matches(monitor, saved)) then
      hl.monitor(rule(monitor.name, saved))
    end
  end

  set_gdk_scale(settings, identities)
end"""

    new_apply = """function M.apply(loading, only)
  local settings = load()
  if next(settings) == nil then
    return
  end

  local identities = o.workspaces.identities()
  local pending = {}
  local used_positions = {}

  for _, monitor in ipairs(hl.get_monitors()) do
    local saved = settings[identities[monitor.name]]
    if not monitor.is_mirror and saved and (not only or monitor.name == only) then
      local effective = saved
      if saved.position and used_positions[saved.position] then
        effective = {
          mode = saved.mode,
          position = "auto",
          scale = saved.scale,
          transform = saved.transform,
        }
      elseif saved.position then
        used_positions[saved.position] = monitor.name
      end

      if loading or not matches(monitor, effective) then
        pending[#pending + 1] = { monitor = monitor, saved = effective }
      end
    end
  end

  -- Apply monitors moving away from 0x0 first so a monitor claiming 0x0 (e.g. DP-2)
  -- never transiently overlaps one currently sitting at 0x0 (e.g. eDP-1).
  table.sort(pending, function(a, b)
    local a_origin = (a.saved.position == "0x0")
    local b_origin = (b.saved.position == "0x0")
    if a_origin ~= b_origin then
      return not a_origin
    end
    return (a.monitor.name or "") < (b.monitor.name or "")
  end)

  for _, item in ipairs(pending) do
    hl.monitor(rule(item.monitor.name, item.saved))
  end

  set_gdk_scale(settings, identities)
end"""

    src = replace_once(src, old_apply, new_apply, "M.apply overlap-safe ordering")

    old_added = """hl.on("monitor.added", function(monitor)
  M.apply(false, monitor and monitor.name)
end)"""

    new_added = """hl.on("monitor.added", function(_)
  M.apply(false)
end)"""

    src = replace_once(src, old_added, new_added, "monitor.added full layout apply")

    ms_lua.write_text(src, encoding="utf-8")


if __name__ == "__main__":
    main()
