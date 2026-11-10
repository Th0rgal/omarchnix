#!/usr/bin/env python3
"""Demand-driven idle speaker-amp suspend wrapper for speakerguardd-session (v2).

Keeps 100% of speakerguardd-v2's hardware safety invariants intact:
  - `alsa_output.platform-sound.RawSpeakers` (`libsgv2_lv2.so`) continues beating
    on PipeWire's dummy driver while idle, and `/run/speakerguardd/<uid>/helper/session`
    stays fresh at 150 ms (well inside the 500 ms supervisor bound), so kernel
    `"Speaker Protection"` stays granted and ready at all times.
  - Whenever any client stream links or runs into `sgv2.voicing.<m>` (or
    `RawSpeakers`), speaker amps (`sgv2.speaker.<m>`) and IV-sense (`sgv2.sense.<m>`)
    link immediately on the PipeWire monitor event without waiting for the next tick.
  - After `SGV2_IDLE_TAIL_SECS` (default 8 s) with zero active client streams,
    speaker amps and IV-sense are unlinked and suspended so `pcm1p` & `pcm2c`
    close (`tas2764` Class-D speaker amps power down instead of idling at ~50 °C)
    and the 4-channel voicing convolver drops to 0% CPU.
"""

import argparse
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import os
import signal
import sys
import time


def _load_upstream(path: str):
    loader = SourceFileLoader("sgv2_session_upstream", path)
    spec = spec_from_loader(loader.name, loader)
    if spec is None:
        raise SystemExit(f"speakerguardd-session-idle: cannot load {path}")
    mod = module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] != "--upstream":
        raise SystemExit("usage: speakerguardd-session-idle --upstream <path> --machine <m> [--selfcheck <path>]")
    upstream_path = sys.argv[2]
    sys.argv = [sys.argv[0], *sys.argv[3:]]

    sgv2 = _load_upstream(upstream_path)
    sgv2.PERIOD = float(os.environ.get("SGV2_REPORT_PERIOD", "0.150"))
    idle_tail_secs = float(os.environ.get("SGV2_IDLE_TAIL_SECS", "8.0"))
    new_link_grace_secs = float(os.environ.get("SGV2_NEW_LINK_GRACE_SECS", "8.0"))

    class IdleSession(sgv2.Session):
        def __init__(self, m, c):
            super().__init__(m, c)
            self.link_first_seen = {}
            self.last_demand = -100.0
            self.was_active = False

        def has_client_demand(self, g, now=None) -> bool:
            if now is None:
                now = time.monotonic()
            protect = g.node_id(sgv2.PROTECT_INPUT)
            internal = {
                protect,
                g.node_id(self.protect_out),
                g.node_id(self.speaker),
                g.node_id(self.sense_name) if self.sense else None,
                g.node_id(f"sgv2.voicing.{self.m}"),
                g.node_id(f"sgv2.voicing.{self.m}.out"),
                g.node_id(f"effect_input.{self.m}-convolver"),
                g.node_id(self.voicing),
            } - {None}
            entry_sinks = {
                g.node_id(f"sgv2.voicing.{self.m}"),
                g.node_id(f"effect_input.{self.m}-convolver"),
                protect,
            } - {None}
            if not entry_sinks:
                return False

            port_owner = {
                o["id"]: (o["info"].get("props") or {}).get("node.id")
                for o in g.of_type("Port")
            }
            live_lids = set()
            active_now = False

            for o in g.of_type("Link"):
                lid = o.get("id")
                live_lids.add(lid)
                li = o.get("info") or {}
                out_n = li.get("output-node-id")
                if out_n is None:
                    out_n = port_owner.get(li.get("output-port-id"))
                in_n = li.get("input-node-id")
                if in_n is None:
                    in_n = port_owner.get(li.get("input-port-id"))
                if in_n not in entry_sinks or out_n in internal:
                    continue

                first = self.link_first_seen.setdefault(lid, now)
                lstate = li.get("state")
                nstate = g.node_state(out_n)
                if (
                    (now - first) < new_link_grace_secs
                    or lstate in ("active", "init", "negotiating")
                    or nstate == "running"
                ):
                    active_now = True

            if len(self.link_first_seen) != len(live_lids):
                for k in [k for k in self.link_first_seen if k not in live_lids]:
                    del self.link_first_seen[k]

            if active_now:
                self.last_demand = now
                return True
            return (now - self.last_demand) < idle_tail_secs

        def _unlink_and_suspend_amps(self, g) -> None:
            spk = g.node_id(self.speaker)
            sense = g.node_id(self.sense_name) if self.sense else None
            owners = {
                o["id"]: (o["info"].get("props") or {}).get("node.id")
                for o in g.of_type("Port")
            }
            linked = False
            for lid, o, i in g.links():
                if owners.get(i) == spk or (sense is not None and owners.get(o) == sense):
                    linked = True
                    self._spawn(("unlink", lid), ["pw-link", "-d", str(lid)])
            if not linked:
                self.suspend_for_sleep(g, (spk, sense))

        def reconcile(self, g, granted) -> None:
            self._reap()
            if not granted:
                self.was_active = False
                super().reconcile(g, False)
                return

            if self.has_client_demand(g):
                if not self.was_active:
                    self.was_active = True
                    self.last_try = -10.0
                    sgv2.log("audio active: linking speaker amps")
                super().reconcile(g, True)
            else:
                if self.was_active:
                    self.was_active = False
                    sgv2.log("audio idle: unlinking and suspending speaker amps")
                self._unlink_and_suspend_amps(g)

    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", required=True)
    ap.add_argument("--selfcheck", default="/var/lib/speakerguardd/selfcheck.json")
    args = ap.parse_args()
    c = sgv2.machine(args)
    card = sgv2.Card(c["card"])
    g = sgv2.Graph()
    s = IdleSession(args.machine, c)
    report = f"/run/speakerguardd/{os.getuid()}/helper/session"

    def stop(*_):
        try:
            os.unlink(report)
        except OSError:
            pass
        try:
            s.unlink_all(g, 1.0)
        except Exception as e:  # noqa: BLE001
            sgv2.log(f"unlink on stop: {e}")
        raise SystemExit(0)

    sgv2.realtime()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last = (None, None, None, None)
    was_granted = None
    nxt = time.monotonic()
    while True:
        ready = g.pump(max(0.0, nxt - time.monotonic()), [card.fd] if card.events else [])
        if ready and card.drain():
            granted = card.granted()
            if granted != was_granted:
                s.reconcile(g, granted)
                was_granted = granted
        if time.monotonic() < nxt:
            wake_amps = bool(was_granted) and (not s.was_active) and s.has_client_demand(g)
            if ready is not None and (wake_amps or s.check(g) != last[1:3]):
                nxt = time.monotonic()
            else:
                continue
        nxt += sgv2.PERIOD
        if nxt < time.monotonic():
            nxt = time.monotonic() + sgv2.PERIOD
        granted = card.granted()
        links, carrier = s.check(g)
        wrote = sgv2.write_report(report, links, carrier, s.wiring(g), s.amps_linked(g))
        s.reconcile(g, granted)
        s.pin_amps_unity(g)
        was_granted = granted
        state = (granted, links, carrier, wrote)
        if state != last:
            sgv2.log(
                f"granted={int(granted)} links={int(links)} carrier={int(carrier)} report={'ok' if wrote else 'unwritable'}"
            )
            last = state


if __name__ == "__main__":
    main()
