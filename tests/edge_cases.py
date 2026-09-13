"""
The real data only exercises a few of the rules, and two wrong queries (delivered-only,
one-hop parent join) happen to land on or near 22. This script copies the database into
memory, adds one awkward situation at a time, and checks that sql/target_base.sql still
gives the number the data dictionary implies, while showing where the shortcuts drift.

Run from the repo root:  python3 tests/edge_cases.py
"""

import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "comm_log.db"
TARGET_SQL = (ROOT / "sql" / "target_base.sql").read_text()
BRIDGE_SQL = (ROOT / "sql" / "bridge.sql").read_text()

_next_log_id = [1000]


def send(campaign, customer, status=900, day="2026-10-15", merchant=501):
    _next_log_id[0] += 1
    ts = f"{day} 10:00:00"
    return (
        "INSERT INTO communication_log VALUES "
        f"({_next_log_id[0]}, {merchant}, {campaign}, '{customer}', '2', {status}, '{ts}', '{ts}', 1, 'sms')"
    )


def campaign(cid, parent, name, creation="approved", processing="processed"):
    parent_sql = "NULL" if parent is None else parent
    return f"INSERT INTO campaign VALUES ({cid}, 501, {parent_sql}, '{name}', '{creation}', '{processing}')"


# (name, statements, expected target_base, run the bridge shortcuts too?)
CASES = [
    ("untouched data", [], 22, True),
    ("chain customer fails every attempt",
     [send(9201, "E1", 1100, "2026-10-07"), send(9202, "E1", 1100, "2026-10-08")], 23, True),
    ("retry re-sent to someone already delivered",
     [send(9201, "E2", 900, "2026-10-07"), send(9202, "E2", 900, "2026-10-08")], 23, True),
    ("chain three deep (9201 > 9202 > 9203)",
     [campaign(9203, 9202, "Diwali Wave 2 - Retry 2"),
      send(9201, "E3", 1100, "2026-10-07"), send(9202, "E3", 1100, "2026-10-08"),
      send(9203, "E3", 900, "2026-10-09")], 23, True),
    ("approved retry hanging off the pending 9004",
     [campaign(9005, 9004, "Diwali Cart Recovery - Retry E"),
      send(9005, "C11"), send(9005, "C1")], 23, True),
    ("third standalone send to C20", [send(9101, "C20", 900, "2026-10-25")], 23, True),
    ("send in November", [send(9101, "C21", 900, "2026-11-02")], 22, True),
    ("row from another merchant", [send(9101, "Z1", merchant=777)], 22, True),
    ("retry whose own name lacks 'Diwali'",
     [campaign(9006, 9003, "Cart Recovery - Retry D"), send(9006, "L1")], 23, True),
    ("chain whose only child is unapproved",
     [campaign(9401, None, "Diwali Solo"), campaign(9402, 9401, "Diwali Solo - Retry", "approval_awaiting"),
      send(9401, "G1", 900, "2026-10-11"), send(9401, "G1", 900, "2026-10-21")], 23, True),
    ("unapproved root with an approved retry",
     [campaign(9601, None, "Diwali Late", "approval_awaiting"), campaign(9602, 9601, "Diwali Late - Retry"),
      send(9601, "J1", 1100, "2026-10-12"), send(9602, "J1", 900, "2026-10-13"),
      send(9602, "K1", 900, "2026-10-13"), send(9602, "K1", 900, "2026-10-14")], 24, True),
    ("parent_id points at a campaign not on file",
     [campaign(9501, 99999, "Diwali Orphan Retry"), send(9501, "H1"), send(9501, "H1", 900, "2026-10-16")], 23, True),
    ("parent_id cycle (9301 <-> 9302)",
     [campaign(9301, 9302, "Diwali Loop A"), campaign(9302, 9301, "Diwali Loop B"),
      send(9301, "F1", 1100), send(9302, "F1")], 23, False),
]


def run_case(statements):
    mem = sqlite3.connect(":memory:")
    with sqlite3.connect(DB) as src:
        src.backup(mem)
    for s in statements:
        mem.execute(s)
    target = mem.execute(TARGET_SQL).fetchone()[0]
    return mem, target


def bridge_results(mem):
    rows = mem.execute(BRIDGE_SQL).fetchall()
    return {r[0]: r[3] for r in rows}


def main():
    failures = 0
    print(f"{'case':<46} {'expect':>6} {'got':>4}   {'delivered-only':>14} {'one-hop':>7}")
    for name, statements, expected, with_bridge in CASES:
        mem, got = run_case(statements)
        delivered_only = one_hop = "-"
        if with_bridge:
            b = bridge_results(mem)
            delivered_only, one_hop = b["3"], b["4"]
        ok = got == expected
        failures += not ok
        flag = "" if ok else "   <-- FAIL"
        print(f"{name:<46} {expected:>6} {got:>4}   {delivered_only:>14} {one_hop:>7}{flag}")
        mem.close()
    print(f"\n{len(CASES) - failures}/{len(CASES)} cases match")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
