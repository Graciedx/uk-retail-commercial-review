-- 01_clean.sql
-- Turns the two raw UCI sheets into one trusted table of order lines.
-- Every row removed is counted in dq_bridge, so raw revenue reconciles to clean revenue.

-- The two sheets overlap for 1-9 Dec 2010. The later sheet is kept for those dates.
CREATE OR REPLACE TABLE stg_lines AS
SELECT *
FROM raw_lines
WHERE NOT (source_sheet = 'Year 2009-2010' AND invoice_ts >= TIMESTAMP '2010-12-01');

-- Label each row once, in priority order, so no row falls into two groups.
CREATE OR REPLACE TABLE lines_labelled AS
SELECT
    *,
    quantity * price AS line_value,
    CASE
        WHEN invoice LIKE 'A%'                                   THEN 'bad_debt_adjustment'
        WHEN NOT regexp_matches(stock_code, '^[0-9]{5}[A-Za-z]*$')
          OR upper(stock_code) LIKE 'TEST%'                      THEN 'non_product_code'
        WHEN price <= 0                                          THEN 'zero_price_stock_movement'
        WHEN invoice LIKE 'C%' AND quantity < 0                  THEN 'return'
        WHEN quantity > 0                                        THEN 'sale'
        ELSE 'other_negative'
    END AS line_type
FROM stg_lines;

-- Trusted lines: product sales and product returns only.
CREATE OR REPLACE TABLE clean_lines AS
SELECT
    invoice,
    stock_code,
    upper(trim(description))              AS description,
    quantity,
    invoice_ts,
    date_trunc('month', invoice_ts)::DATE AS order_month,
    price,
    line_value,
    customer_id,
    country,
    line_type,
    CASE
        WHEN invoice_ts <  TIMESTAMP '2010-12-01' THEN 'Y1 (Dec09-Nov10)'
        WHEN invoice_ts <  TIMESTAMP '2011-12-01' THEN 'Y2 (Dec10-Nov11)'
        ELSE 'Dec 2011 (part month)'
    END AS trading_year
FROM lines_labelled
WHERE line_type IN ('sale', 'return');

-- Reconciliation from raw rows to clean rows.
CREATE OR REPLACE TABLE dq_bridge AS
WITH raw_total AS (
    SELECT COUNT(*) AS n_rows, SUM(quantity * price) AS value FROM raw_lines
), overlap AS (
    SELECT COUNT(*) AS n_rows, SUM(quantity * price) AS value
    FROM raw_lines
    WHERE source_sheet = 'Year 2009-2010' AND invoice_ts >= TIMESTAMP '2010-12-01'
), labelled AS (
    SELECT line_type, COUNT(*) AS n_rows, SUM(line_value) AS value
    FROM lines_labelled GROUP BY line_type
)
SELECT 1 AS step, 'Raw rows, both sheets' AS item, n_rows, ROUND(value, 2) AS value FROM raw_total
UNION ALL SELECT 2, 'Less: rows repeated in both sheets', -n_rows, ROUND(-value, 2) FROM overlap
UNION ALL SELECT 3, 'Less: ' || line_type, -n_rows, ROUND(-value, 2)
          FROM labelled WHERE line_type NOT IN ('sale', 'return')
UNION ALL SELECT 4, 'Clean: product sales and returns', COUNT(*), ROUND(SUM(line_value), 2)
          FROM clean_lines;
