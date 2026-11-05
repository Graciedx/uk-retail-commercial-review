-- 03_analysis.sql
-- Each mart_ table answers one business question and feeds the Power BI dashboard.
-- Y1 = Dec 2009 to Nov 2010. Y2 = Dec 2010 to Nov 2011. Dec 2011 is a part month, so it is
-- left out of year-on-year comparisons.

-- Q1. Did the business actually grow?
CREATE OR REPLACE TABLE mart_kpi_year AS
SELECT
    trading_year,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale'), 0)                            AS gross_sales,
    ROUND(-SUM(line_value) FILTER (WHERE line_type = 'return'), 0)                         AS returns_value,
    ROUND(SUM(line_value), 0)                                                              AS net_sales,
    COUNT(DISTINCT invoice) FILTER (WHERE line_type = 'sale')                              AS orders,
    COUNT(DISTINCT customer_id) FILTER (WHERE line_type = 'sale')                          AS identified_customers,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale')
          / COUNT(DISTINCT invoice) FILTER (WHERE line_type = 'sale'), 2)                  AS avg_order_value,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale' AND customer_id IS NULL), 0)    AS sales_no_customer_id,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale' AND customer_id IS NOT NULL), 0) AS sales_with_customer_id,
    ROUND(SUM(line_value) FILTER (WHERE customer_id IS NOT NULL), 0)                       AS net_sales_with_customer_id,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale' AND month(invoice_ts) IN (9, 10, 11)), 0) AS sales_sep_to_nov
FROM analysis_lines
GROUP BY trading_year
ORDER BY trading_year;

CREATE OR REPLACE TABLE mart_monthly AS
SELECT
    order_month,
    trading_year,
    strftime(order_month, '%b')                                   AS month_label,
    CASE WHEN month(order_month) = 12 THEN 1 ELSE month(order_month) + 1 END AS month_index,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale'), 2)   AS gross_sales,
    ROUND(-SUM(line_value) FILTER (WHERE line_type = 'return'), 2) AS returns_value,
    ROUND(SUM(line_value), 2)                                     AS net_sales,
    COUNT(DISTINCT invoice) FILTER (WHERE line_type = 'sale')     AS orders,
    COUNT(DISTINCT customer_id) FILTER (WHERE line_type = 'sale') AS active_customers
FROM analysis_lines
WHERE trading_year NOT LIKE 'Dec 2011%'
GROUP BY order_month, trading_year
ORDER BY order_month;

-- Q2. What sits behind the headline? Revenue bridge from Y1 to Y2, identified customers only.
CREATE OR REPLACE TABLE mart_revenue_bridge AS
WITH c AS (
    SELECT customer_id, COALESCE(y1_net, 0) AS y1, COALESCE(y2_net, 0) AS y2
    FROM customer_year
), bucketed AS (
    SELECT *, CASE
        WHEN y1 >  0 AND y2 <= 0 THEN 'Lost customers'
        WHEN y1 <= 0 AND y2 >  0 THEN 'New customers'
        WHEN y1 >  0 AND y2 > y1 THEN 'Existing customers spending more'
        WHEN y1 >  0 AND y2 < y1 THEN 'Existing customers spending less'
        ELSE 'Returns only or unchanged'
    END AS bucket
    FROM c
)
SELECT 1 AS sort_order, 'Y1 net sales, identified customers' AS step, ROUND(SUM(y1), 0) AS value, NULL::BIGINT AS customers
FROM bucketed
UNION ALL
SELECT CASE bucket WHEN 'Lost customers' THEN 2 WHEN 'Existing customers spending less' THEN 3
                   WHEN 'Existing customers spending more' THEN 4 WHEN 'New customers' THEN 5 ELSE 6 END,
       bucket, ROUND(SUM(y2 - y1), 0), COUNT(*)
FROM bucketed GROUP BY bucket
UNION ALL
SELECT 7, 'Y2 net sales, identified customers', ROUND(SUM(y2), 0), NULL
FROM bucketed
ORDER BY sort_order;

-- Same bridge without the closing row, because the waterfall chart draws its own total.
CREATE OR REPLACE TABLE mart_bridge_chart AS
SELECT sort_order,
       CASE sort_order WHEN 1 THEN 'Y1 net sales' WHEN 2 THEN 'Lost' WHEN 3 THEN 'Spending less'
                       WHEN 4 THEN 'Spending more' WHEN 5 THEN 'New' ELSE 'Other' END AS step,
       value
FROM mart_revenue_bridge WHERE sort_order < 7;

-- Q3. How dependent is revenue on a few accounts?
CREATE OR REPLACE TABLE mart_concentration AS
WITH r AS (
    SELECT y2_net AS v,
           ROW_NUMBER() OVER (ORDER BY y2_net DESC) AS rn,
           COUNT(*) OVER ()    AS n,
           SUM(y2_net) OVER () AS total
    FROM customer_year WHERE y2_net > 0
), bands(band, pct) AS (VALUES ('Top 1%', 0.01), ('Top 5%', 0.05), ('Top 10%', 0.10), ('Top 20%', 0.20), ('Top 50%', 0.50))
SELECT b.band, ROUND(b.pct * MAX(r.n)) AS customers, ROUND(SUM(r.v), 0) AS y2_net_sales,
       ROUND(100 * SUM(r.v) / MAX(r.total), 1) AS share_pct
FROM bands b JOIN r ON r.rn <= r.n * b.pct
GROUP BY b.band, b.pct ORDER BY b.pct;

-- Q3b. Is the drop among existing customers spread out, or sitting in a few big accounts?
CREATE OR REPLACE TABLE mart_decline_by_size AS
WITH r AS (
    SELECT COALESCE(y2_net, 0) - y1_net AS change, y1_net,
           ROW_NUMBER() OVER (ORDER BY y1_net DESC) AS rn
    FROM customer_year WHERE y1_net > 0
), banded AS (
    SELECT *, CASE WHEN rn <= 50 THEN '1. Top 50' WHEN rn <= 200 THEN '2. Next 150'
                   WHEN rn <= 845 THEN '3. Rest of top 20%' ELSE '4. Everyone else' END AS y1_size_band
    FROM r
)
SELECT y1_size_band, COUNT(*) AS customers, ROUND(SUM(y1_net), 0) AS y1_net_sales,
       ROUND(SUM(change), 0) AS net_change,
       ROUND(SUM(change) FILTER (WHERE change < 0), 0) AS gross_decline,
       COUNT(*) FILTER (WHERE change < -0.25 * y1_net) AS customers_down_over_25pct
FROM banded GROUP BY y1_size_band ORDER BY y1_size_band;

-- Q4. Which valuable customers have gone quiet?
-- A customer is overdue when the days since their last order exceed three times their usual gap,
-- with a floor of 60 days. Needs at least three orders to have a usual gap. The same rule is
-- run at two snapshot dates so the second can be tested against what actually happened.
CREATE OR REPLACE TABLE customer_snapshot AS
WITH snaps(snapshot_date) AS (VALUES (DATE '2010-12-01'), (DATE '2011-12-01')),
o AS (
    SELECT s.snapshot_date, c.customer_id, c.order_ts, c.order_value,
           date_diff('day', LAG(c.order_ts) OVER (PARTITION BY s.snapshot_date, c.customer_id ORDER BY c.order_ts), c.order_ts) AS gap_days
    FROM customer_orders c
    JOIN snaps s ON c.order_ts < s.snapshot_date
)
SELECT
    snapshot_date,
    customer_id,
    COUNT(*)                                          AS orders_to_date,
    MIN(order_ts)::DATE                               AS first_order,
    MAX(order_ts)::DATE                               AS last_order,
    date_diff('day', MAX(order_ts)::DATE, snapshot_date) AS days_since_last_order,
    MEDIAN(gap_days) FILTER (WHERE gap_days > 0)      AS usual_gap_days,
    ROUND(SUM(order_value) FILTER (WHERE order_ts >= snapshot_date - INTERVAL 365 DAY), 2) AS sales_last_12m
FROM o
GROUP BY snapshot_date, customer_id;

CREATE OR REPLACE TABLE customer_snapshot_scored AS
SELECT *,
    NTILE(10) OVER (PARTITION BY snapshot_date ORDER BY COALESCE(sales_last_12m, 0) DESC) AS value_decile,
    CASE
        WHEN orders_to_date >= 3 AND usual_gap_days IS NOT NULL
         AND days_since_last_order > GREATEST(60, 3 * usual_gap_days)
        THEN TRUE ELSE FALSE
    END AS is_overdue
FROM customer_snapshot;

-- Back-test: did customers flagged at Dec 2010 really spend less over the next 12 months?
CREATE OR REPLACE TABLE mart_overdue_backtest AS
SELECT
    CASE WHEN s.is_overdue THEN 'Flagged overdue' ELSE 'Not flagged' END AS group_name,
    COUNT(*)                                       AS customers,
    ROUND(SUM(s.sales_last_12m), 0)                AS sales_prior_12m,
    ROUND(SUM(COALESCE(y.y2_net, 0)), 0)           AS sales_next_12m,
    ROUND(100.0 * SUM(COALESCE(y.y2_net, 0)) / SUM(s.sales_last_12m) - 100, 1) AS change_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE COALESCE(y.y2_net, 0) <= 0) / COUNT(*), 1) AS pct_no_purchase_next_12m
FROM customer_snapshot_scored s
LEFT JOIN customer_year y USING (customer_id)
WHERE s.snapshot_date = DATE '2010-12-01' AND s.value_decile <= 2 AND s.sales_last_12m > 0
GROUP BY 1;

-- The call list: top-20% customers overdue at the end of Nov 2011.
CREATE OR REPLACE TABLE mart_customers AS
WITH home AS (
    SELECT customer_id, MODE(country) AS country FROM analysis_lines
    WHERE customer_id IS NOT NULL GROUP BY customer_id
)
SELECT s.customer_id, h.country, s.orders_to_date, s.first_order, s.last_order,
       s.days_since_last_order, s.usual_gap_days, s.sales_last_12m, s.value_decile, s.is_overdue,
       CASE
           WHEN s.value_decile = 1 AND s.is_overdue THEN 'Key account at risk'
           WHEN s.value_decile = 2 AND s.is_overdue THEN 'High value at risk'
           WHEN s.value_decile <= 2                 THEN 'High value active'
           WHEN s.orders_to_date = 1                THEN 'One-time buyer'
           WHEN s.is_overdue                        THEN 'Lower value lapsed'
           ELSE 'Lower value active'
       END AS segment
FROM customer_snapshot_scored s
JOIN home h USING (customer_id)
WHERE s.snapshot_date = DATE '2011-12-01';

CREATE OR REPLACE TABLE mart_segments AS
SELECT segment, COUNT(*) AS customers, ROUND(SUM(COALESCE(sales_last_12m, 0)), 0) AS sales_last_12m,
       ROUND(MEDIAN(days_since_last_order), 0) AS median_days_since_order
FROM mart_customers GROUP BY segment ORDER BY sales_last_12m DESC;

-- Q5. Do first-time buyers come back? Only cohorts with a full 90 days of follow-up are shown.
CREATE OR REPLACE TABLE mart_second_order AS
WITH o AS (
    SELECT customer_id, order_ts,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts) AS rn
    FROM customer_orders
), f AS (
    SELECT customer_id, MAX(order_ts) FILTER (WHERE rn = 1) AS first_ts, MAX(order_ts) FILTER (WHERE rn = 2) AS second_ts
    FROM o GROUP BY customer_id
)
SELECT
    strftime(date_trunc('quarter', first_ts), '%Y-Q') || quarter(first_ts) AS first_order_quarter,
    date_trunc('quarter', first_ts)::DATE AS quarter_start,
    COUNT(*) AS new_customers,
    COUNT(*) FILTER (WHERE second_ts <= first_ts + INTERVAL 90 DAY) AS reordered_in_90d,
    ROUND(100.0 * COUNT(*) FILTER (WHERE second_ts <= first_ts + INTERVAL 90 DAY) / COUNT(*), 1) AS reorder_rate_pct
FROM f
WHERE first_ts >= TIMESTAMP '2010-01-01' AND first_ts < TIMESTAMP '2011-07-01'
GROUP BY 1, 2 ORDER BY 2;

-- Value of a second order: 12-month spend after the first order, by whether they reordered in 90 days.
CREATE OR REPLACE TABLE mart_reorder_value AS
WITH o AS (
    SELECT customer_id, order_ts, order_value,
           MIN(order_ts) OVER (PARTITION BY customer_id) AS first_ts
    FROM customer_orders
), s AS (
    SELECT customer_id, MIN(first_ts) AS first_ts,
           COUNT(*) FILTER (WHERE order_ts > first_ts AND order_ts <= first_ts + INTERVAL 90 DAY) AS orders_90d,
           SUM(order_value) FILTER (WHERE order_ts <= first_ts + INTERVAL 365 DAY) AS spend_12m
    FROM o GROUP BY customer_id
)
SELECT CASE WHEN orders_90d > 0 THEN 'Reordered within 90 days' ELSE 'Did not reorder within 90 days' END AS group_name,
       COUNT(*) AS customers,
       ROUND(MEDIAN(spend_12m), 0) AS median_12m_spend,
       ROUND(AVG(spend_12m), 0)    AS mean_12m_spend
FROM s
WHERE first_ts >= TIMESTAMP '2010-01-01' AND first_ts < TIMESTAMP '2010-12-01'
GROUP BY 1;

-- Q6. Are returns the problem?
CREATE OR REPLACE TABLE mart_products AS
SELECT
    stock_code,
    MODE(description)                                                    AS description,
    ROUND(SUM(line_value) FILTER (WHERE line_type = 'sale' AND trading_year LIKE 'Y2%'), 2)    AS y2_gross_sales,
    ROUND(-SUM(line_value) FILTER (WHERE line_type = 'return' AND trading_year LIKE 'Y2%'), 2) AS y2_returns,
    SUM(quantity) FILTER (WHERE line_type = 'sale' AND trading_year LIKE 'Y2%')                AS y2_units,
    ROUND(100.0 * -SUM(line_value) FILTER (WHERE line_type = 'return' AND trading_year LIKE 'Y2%')
          / NULLIF(SUM(line_value) FILTER (WHERE line_type = 'sale' AND trading_year LIKE 'Y2%'), 0), 1) AS y2_return_rate_pct
FROM analysis_lines
GROUP BY stock_code
HAVING y2_gross_sales IS NOT NULL
ORDER BY y2_gross_sales DESC;

-- Where the revenue is sold.
CREATE OR REPLACE TABLE mart_country AS
SELECT
    country,
    ROUND(SUM(line_value) FILTER (WHERE trading_year LIKE 'Y1%'), 0) AS y1_net_sales,
    ROUND(SUM(line_value) FILTER (WHERE trading_year LIKE 'Y2%'), 0) AS y2_net_sales,
    COUNT(DISTINCT customer_id) AS identified_customers
FROM analysis_lines
GROUP BY country
ORDER BY y2_net_sales DESC NULLS LAST;

-- Are unidentified sales a few big orders or an everyday gap?
CREATE OR REPLACE TABLE mart_no_customer_id AS
SELECT
    trading_year,
    COUNT(DISTINCT invoice) FILTER (WHERE customer_id IS NULL)                  AS orders_no_id,
    ROUND(100.0 * COUNT(DISTINCT invoice) FILTER (WHERE customer_id IS NULL) / COUNT(DISTINCT invoice), 1) AS pct_orders_no_id,
    ROUND(SUM(line_value) FILTER (WHERE customer_id IS NULL), 0)                AS sales_no_id,
    ROUND(100.0 * SUM(line_value) FILTER (WHERE customer_id IS NULL) / SUM(line_value), 1) AS pct_sales_no_id
FROM analysis_lines
WHERE line_type = 'sale'
GROUP BY trading_year ORDER BY trading_year;

CREATE OR REPLACE TABLE mart_dq_bridge AS SELECT * FROM dq_bridge ORDER BY step, item;
