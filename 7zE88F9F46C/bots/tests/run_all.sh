#!/bin/sh
# Full offline verification of the bot (requires lua5.1 + luac5.1: sudo apt-get install -y lua5.1)
set -e
cd "$(dirname "$0")/.."
echo "== syntax"; for f in *.lua nevermore/*.lua; do luac5.1 -p "$f"; done; echo "all files compile"
echo "== replay cases (19 curated moments from the 3 demos)"; lua5.1 tests/run_replay_cases.lua | tail -1
echo "== smoke: whole bot on the mock API"; lua5.1 tests/smoke_think.lua 40 300 | tail -2
echo "== limbo reset"; lua5.1 tests/limbo_reset.lua | tail -1
echo "== v5.1 units (anti-bait gate, spacing hysteresis, approach margin)"; lua5.1 tests/v51_units.lua | tail -1
echo "== v5.1 recall rules"; lua5.1 tests/recall_rules.lua 2>&1 | tail -1
echo "== v5.1 creep-tank drop"; lua5.1 tests/creep_tank.lua 2>&1 | tail -1
echo "== v5.2 lane CS (whole bot, discrete creep hits, enemy dead / full mana / no mana / dips)"; lua5.1 tests/lane_cs.lua 2>&1 | tail -1
