-- target_base for merchant 501, October 2026, Diwali campaigns.
-- Run: sqlite3 data/comm_log.db < sql/target_base.sql      (expects 22)
--
-- Rules, all from the data dictionary:
--   1. A send counts only if its campaign cleared approval (finalized creation_status)
--      AND finished processing.
--   2. A retry chain (a campaign plus every retry under it, any depth) is one
--      communication: each customer counts once across the whole chain.
--   3. A standalone campaign (no parent, no children) counts every send, repeats included.

WITH RECURSIVE
params AS (
    SELECT 501                   AS merchant_id,
           '2026-10-01 00:00:00' AS period_start,   -- half-open range, keeps the
           '2026-11-01 00:00:00' AS period_end,     -- predicate usable by an index
           '%diwali%'            AS family_name_like
),

finalized(creation_status) AS (
    VALUES ('approved'), ('aborted'), ('resumed'), ('stopped')
),

-- Walk upward from every campaign to all of its ancestors. The path string stops
-- the recursion if parent_id ever loops back on itself.
ancestry(campaign_id, ancestor_id, depth, path) AS (
    SELECT c.id, c.id, 0, ',' || c.id || ','
    FROM campaign c
    JOIN params p ON p.merchant_id = c.merchant_id

    UNION ALL

    SELECT a.campaign_id, parent.id, a.depth + 1, a.path || parent.id || ','
    FROM ancestry a
    JOIN campaign child  ON child.id  = a.ancestor_id
    JOIN campaign parent ON parent.id = child.parent_id
                        AND parent.merchant_id = child.merchant_id
    WHERE instr(a.path, ',' || parent.id || ',') = 0
),

-- Root = the ancestor that has nowhere further to go (parent NULL or not on file).
-- A pure cycle has no such ancestor, so fall back to its lowest id, which every
-- member of the cycle agrees on.
campaign_root AS (
    SELECT a.campaign_id,
           COALESCE(
               MIN(CASE WHEN anc.parent_id IS NULL
                          OR NOT EXISTS (SELECT 1 FROM campaign x
                                         WHERE x.id = anc.parent_id
                                           AND x.merchant_id = anc.merchant_id)
                        THEN a.ancestor_id END),
               MIN(a.ancestor_id)
           ) AS root_id
    FROM ancestry a
    JOIN campaign anc ON anc.id = a.ancestor_id
    GROUP BY a.campaign_id
),

-- Family shape is structural: it counts every campaign in the chain, approved or
-- not. A root whose own parent_id points somewhere we can't see is still a retry.
family AS (
    SELECT r.root_id,
           rc.name                                     AS root_name,
           COUNT(*) > 1 OR rc.parent_id IS NOT NULL    AS is_chain
    FROM campaign_root r
    JOIN campaign rc ON rc.id = r.root_id
    GROUP BY r.root_id, rc.name, rc.parent_id
),

qualifying_sends AS (
    SELECT l.id AS log_id,
           l.customer_id,
           r.root_id,
           f.is_chain
    FROM communication_log l
    JOIN params p         ON p.merchant_id = l.merchant_id
    JOIN campaign c       ON c.id = l.communication_id
                         AND c.merchant_id = l.merchant_id
    JOIN campaign_root r  ON r.campaign_id = c.id
    JOIN family f         ON f.root_id = r.root_id
    WHERE l.communication_type = '2'
      AND l.sent_time >= p.period_start
      AND l.sent_time <  p.period_end
      AND f.root_name LIKE p.family_name_like          -- a retry belongs to its root's campaign
      AND c.creation_status IN (SELECT creation_status FROM finalized)
      AND c.processing_status = 'processed'
)

-- One counting key per unit of "reach": (chain, customer) inside a chain,
-- the individual send row for a standalone campaign.
SELECT COUNT(DISTINCT CASE WHEN is_chain
                           THEN 'chain:' || root_id || ':' || customer_id
                           ELSE 'send:'  || log_id
                      END) AS target_base
FROM qualifying_sends;
