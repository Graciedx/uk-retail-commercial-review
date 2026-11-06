# UK Online Retail: Commercial Review (SQL)

**The question:** sales went up 1.4%, so is the business healthy?

**The answer:** not as healthy as the headline. All of the growth came from orders with no customer ID. Sales to known customers fell 2.7%, and £3.1m of last year's revenue was lost or shrinking, replaced by £2.9m from other customers.

Built with SQL (DuckDB) on 1.07m real transaction rows from a UK online gift wholesaler, Dec 2009 to Dec 2011.


**Status:** the SQL analysis is complete. A Power BI dashboard is in progress, and its working files are in `dashboard/`.

## What I found

Y1 is Dec 2009 to Nov 2010. Y2 is Dec 2010 to Nov 2011.

| Finding | Evidence |
|---|---|
| Growth is not coming from known customers | Net sales +1.4% to £9.31m. Known customers -2.7%. Sales with no customer ID rose from £1.06m to £1.41m |
| The flat total hides heavy churn | Lost customers -£1.04m, existing customers spending less -£2.05m, spending more +£1.50m, new customers +£1.37m |
| Revenue depends on few accounts | 43 customers (top 1%) were 29.7% of Y2 known-customer sales. 428 customers (top 10%) were 59.7% |
| The biggest accounts are not safe | 106 of the top 200 Y1 accounts fell by more than 25%, a gross decline of £1.14m |
| A second order is the turning point | 39% of Q1 2011 new customers reordered in 90 days. Those who reorder spend a median £1,398 in 12 months against £425 |
| Returns are not the priority | 2.4% of Y2 sales. The top 20 products account for 30% of returned value |

## What I recommend

1. **Give the top 200 accounts named owners.** They were 47% of known Y1 sales. Start with the customer table in `marts/mart_customers.csv`, which flags 59 high-value accounts that are overdue.
2. **Capture a customer ID on every order.** £1.41m, 15% of Y2 sales, cannot be tied to a customer, so nobody can tell whether it is repeat business.
3. **Run a 90-day second-order programme.** Raising the 90-day reorder rate from 39% to 45% would add about 100 repeat customers a year. At the median spend gap of £973 that is worth up to about £100k. This is an upper estimate, because keener buyers may simply reorder more.
4. **Leave returns alone for now.** Handle them as product fixes, not as a business programme.

## Testing the overdue flag

A flag is only useful if it predicts something, so I ran the same rule at Dec 2010 and checked the next 12 months for top-20% customers:

| Group at Dec 2010 | Customers | Sales change, next 12 months | No purchase in next 12 months |
|---|---|---|---|
| Flagged overdue | 46 | -81.4% | 45.7% |
| Not flagged | 802 | -17.9% | 7.4% |

The flag works but catches only a small share of the money. Most of the decline comes from accounts still ordering less, which is why recommendation 1 is account ownership and not a win-back campaign. Some of the -17.9% is also natural: customers picked for a strong year tend to fall back.

## Making the numbers trustworthy

Raw revenue reconciles to clean revenue line by line. See `marts/mart_dq_bridge.csv`.

| Step | Rows | Value |
|---|---:|---:|
| Raw rows, both sheets | 1,067,371 | £19,287,251 |
| Rows repeated in both sheets (1 to 9 Dec 2010) | -22,523 | -£377,488 |
| Bad debt adjustments | -6 | +£147,614 |
| Postage, fees, manual and test codes | -5,987 | -£77,264 |
| Zero-price stock movements | -5,938 | £0 |
| **Clean product sales and returns** | **1,032,917** | **£18,980,113** |

Other decisions:

- Three bulk orders worth £285k were cancelled in full on the same day. They are removed so they do not count as sales or returns.
- 11,790 exact repeat lines inside an invoice (£54k, 0.3% of value) are kept, because they may be real.
- Dec 2011 is a part month, so it is left out of year-on-year figures.

## Limits

- The data covers sales only. There is no margin, marketing cost or reason for leaving, so £ figures are revenue, not profit.
- Many customers are wholesalers, so patterns may not apply to a consumer retailer.
- Customer-level findings exclude the 15% of sales with no ID.
- The data is from 2009 to 2011.

## Repository

```text
sql/01_clean.sql             Removes overlap, labels every row, builds the reconciliation
sql/02_customer_tables.sql   Removes reversed bulk orders, builds customer tables
sql/03_analysis.sql          one mart table per business question
marts/                       Query outputs
dashboard/                   Power BI work in progress
run_all.py                   Rebuilds everything from the raw file
```


Dataset: Chen, D. (2019). Online Retail II. UCI Machine Learning Repository. CC BY 4.0.
