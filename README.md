# Comm-log send reconciliation

Finance reports `target_base = 22` for merchant 501, October 2026, Diwali campaigns. I get 22 from the raw data. The query that gets there is `sql/target_base.sql`.

Two wrong queries also get 22 or close to it, so most of this README is about why I trust this 22 over those.

## Run it

Needs only the `sqlite3` CLI (3.25 or newer for window functions) and Python 3 for the tests. No packages.

```sh
sqlite3 data/comm_log.db < sql/target_base.sql                      # 22
sqlite3 -header -column data/comm_log.db < sql/bridge.sql           # every step below, recomputed
sqlite3 -header -column data/comm_log.db < sql/row_ledger.sql       # all 30 rows and what happened to each
sqlite3 -header -column data/comm_log.db < sql/data_checks.sql      # the checks I ran first
python3 tests/edge_cases.py                                         # 13 made-up situations the real data doesn't cover
```

## Bridge

In the order I ran into each thing. Rows marked "no" are attempts I dropped. I left them in on purpose because they explain the ones I kept.

| Step | What I changed | Result | Kept? | Why |
|---|---|---|---|---|
| 0 | `COUNT(*)` of sends in scope (merchant 501, type '2', October, Diwali) | 30 | yes | Starting point. 8 too many. |
| 1 | Drop sends whose campaign hasn't cleared approval | 26 | yes | Campaign 9004 is `approval_awaiting`. Its 4 sends went out anyway, but the data dictionary says they don't count yet. |
| 2 | `COUNT(DISTINCT customer_id)` | 21 | no | Now one short. It merges C20's two sends in 9101, which is a standalone campaign where every send counts. |
| 3 | Keep only delivered sends (`delivery_status = 900`) | 22 | no | Right number, wrong reason. It counts rows, not customers. It matches here only because every retried customer got through exactly once. |
| 4 | Collapse retries into their parent: `COALESCE(parent_id, id)` | 23 | fixed in 5 | Correct idea, but it only looks one level up. 9003's parent is 9002, not 9001, so C3 ends up in two families. |
| 5 | Resolve every campaign to its top-level root with a recursive CTE | **22** | yes | C3 is counted once for chain 9001. The C20 repeat in standalone 9101 is left alone. |

As a plain subtraction: 30 sends − 4 from unapproved 9004 − 4 retry attempts for customers already counted in their chain (C2 in 9002, C3 in 9002, C3 in 9003, D1 in 9202) = **22**. `sql/row_ledger.sql` labels each of the 30 rows so this can be checked line by line.

| Chain | Campaigns that count | Counted |
|---|---|---|
| 9001 | 9001, 9002, 9003 (9004 excluded) | 10 customers, C1–C10 |
| 9101 | standalone | 7 sends to 6 customers (C20 twice) |
| 9201 | 9201, 9202 | 5 customers, D1–D5 |
| | | **22** |

## How I got there

Before counting anything, I checked the data itself (`sql/data_checks.sql`). The SQLite file and the CSVs match value for value. Every log row has a campaign, merchants agree across both tables, nothing falls outside October, and there are no exact duplicate rows. A 30 vs 22 gap therefore isn't dirty data. It has to come from the counting rules.

`COUNT(*)` gave 30. The campaign profile showed right away that one campaign was still `approval_awaiting`, and the dictionary is explicit that those sends don't count. That gave 26.

The next obvious move was distinct customers, which gave 21. That was too far, so I listed every customer with more than one send. There turned out to be two different kinds of repeat. C2, C3 and D1 show up across different campaigns, failing and then being retried. C20 shows up twice inside one campaign, ten days apart, with nothing chained to it. The dictionary treats these differently: a retry chain counts a customer once, and a standalone campaign counts every send. Blanket `DISTINCT` can't tell the two apart.

While looking at those repeats I noticed every retried customer's history ends in exactly one delivery. So I tried counting delivered rows, and it came out to exactly 22. That was the moment I trusted least. The rule in the dictionary is about distinct customers per chain, not deliveries, and the two only agree here by accident. `tests/edge_cases.py` adds a customer who fails every retry, and one who gets retried after already being delivered. Delivered-only drifts to 22 and 24 while the real rule gives 23 in both cases.

To collapse chains properly I first used one hop, `COALESCE(parent_id, id)`, which gave 23. The extra one was C3, who went 9001 → 9002 → 9003. One hop maps 9003 to 9002, so C3 appears under two different "families". Chains can be any depth, so the only safe fix is walking all the way up. A recursive CTE does that, and the answer came out to 22.

I then ran the same problem in Python from scratch, without the SQL, and it also came to 22 with the same per-chain split.

## The query

`sql/target_base.sql` is one statement with the filters in a `params` CTE at the top.

The recursive CTE starts at every campaign and climbs up through `parent_id`, carrying the path as a string so it stops if the ids ever loop. I went upward rather than down from the roots, because a downward walk silently loses any campaign stuck in a cycle or whose parent isn't on file.

Whether a family is a chain is decided from the campaign table alone. 9001 is a chain because 9002, 9003 and 9004 point at it, and it doesn't stop being one just because 9004 isn't approved. Approval is applied afterwards, send by send.

Rather than adding two sub-counts, every qualifying send gets a key: `chain:<root>:<customer>` inside a chain, `send:<row id>` in a standalone campaign. `COUNT(DISTINCT key)` is the answer, and both counting rules sit on one line.

"Diwali" is matched on the root campaign's name, since a retry belongs to the communication it retries even if someone names it "Retry D". The date filter is a half-open range on the raw column (`>= '2026-10-01' AND < '2026-11-01'`) instead of `strftime(sent_time)`, so an index on `sent_time` would still get used.

## Calls I made that the data can't settle

These don't change 22 on this dataset, but they would change it on a messier month. I'd confirm them with Finance before this became a scheduled report.

1. **"Reached" vs "targeted".** The dictionary says a chain counts distinct customers "reached". I count a customer who was targeted in the chain even if every attempt failed. The standalone rule counts every send whatever the delivery status, and the metric is called target_base, so I read it as targeted. Here nobody fails a whole chain, so both readings give 22.
2. **A campaign whose only retries are unapproved.** I still treat it as a chain, because the dictionary defines standalone by the `parent_id` links, not by approval. The other reading would count repeat sends in that root separately.
3. **An unapproved root with approved retries.** The root's own sends drop out, and the approved retries still roll up under it and count once per customer.
4. **A chain that crosses a month boundary.** I filter sends by `sent_time`, so a customer counts in whichever month their in-scope attempts happened. A chain starting 30 October and retrying 2 November would put that customer in both months' numbers.
5. **Name-based Diwali filter.** This works on seven campaigns. On real data I'd want a campaign tag or festival field instead of `LIKE '%diwali%'`.

## Stress tests

`python3 tests/edge_cases.py` copies the database into memory, adds one awkward case at a time, and compares the final query with the two shortcuts from the bridge.

```
case                                           expect  got   delivered-only one-hop
untouched data                                     22   22               22      23
chain customer fails every attempt                 23   23               22      24
retry re-sent to someone already delivered         23   23               24      24
chain three deep (9201 > 9202 > 9203)              23   23               23      25
approved retry hanging off the pending 9004        23   23               24      25
third standalone send to C20                       23   23               23      24
send in November                                   22   22               22      23
row from another merchant                          22   22               22      23
retry whose own name lacks 'Diwali'                23   23               22      23
chain whose only child is unapproved               23   23               24      24
unapproved root with an approved retry             24   24               25      25
parent_id points at a campaign not on file         23   23               24      25
parent_id cycle (9301 <-> 9302)                    23   23                -       -

13/13 cases match
```

## What surprised me

The thing that bothered me most was that "only count delivered sends" lands on exactly 22. If I'd tried that first, I could easily have stopped there with the right number and the wrong logic. Campaign 9004 was the other surprise. It's labelled a retry of 9001, but none of its four customers were ever sent 9001, so it isn't retrying anyone. It looks more like a new audience attached to the wrong parent. It had also already been processed and delivered, with credits billed, while still waiting for approval. So October's number isn't final: if 9004 gets approved later, target_base for the month moves from 22 to 26 after the fact. Credits don't line up with target_base either (30 billed against 22 counted), which is worth knowing if anyone ever divides spend by this metric. Smaller things: every send has `sent_time` equal to `scheduled_time`, and all 30 go out at exactly 10:00:00, so time can't be used to tell a legitimate re-run from a retry. The `parent_id` link is the only signal.

## Files

```
data/                 comm_log.db and the two CSVs, as provided
sql/target_base.sql   the answer
sql/bridge.sql        each bridge step, including the dropped ones
sql/row_ledger.sql    30 rows, each marked counted / collapsed / excluded
sql/data_checks.sql   integrity checks, repeat customers, chain tree, retry audiences
tests/edge_cases.py   13 added situations, final query vs shortcuts
```
