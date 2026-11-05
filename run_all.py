"""Rebuilds the whole project from the raw UCI file.

1. Download online_retail_II.xlsx from the UCI link in the README into data/.
2. pip install duckdb pandas openpyxl
3. python run_all.py
"""
import pathlib
import duckdb
import pandas as pd

ROOT = pathlib.Path(__file__).parent
RAW = ROOT / "data" / "online_retail_II.xlsx"
COLUMNS = ["invoice", "stock_code", "description", "quantity", "invoice_ts",
           "price", "customer_id", "country", "source_sheet"]

sheets = pd.read_excel(RAW, sheet_name=None,
                       dtype={"Invoice": str, "StockCode": str, "Customer ID": "Int64"})
raw = pd.concat([df.assign(source_sheet=name) for name, df in sheets.items()], ignore_index=True)
raw.columns = COLUMNS
raw["description"] = raw["description"].astype("string")

con = duckdb.connect()
con.register("raw_df", raw)
con.execute("CREATE TABLE raw_lines AS SELECT * FROM raw_df")

for script in sorted((ROOT / "sql").glob("*.sql")):
    print("Running", script.name)
    con.execute(script.read_text(encoding="utf-8"))

(ROOT / "marts").mkdir(exist_ok=True)
tables = [r[0] for r in con.execute("SHOW TABLES").fetchall() if r[0].startswith("mart_")]
for table in tables:
    con.execute(f"COPY {table} TO '{ROOT / 'marts' / table}.csv' (HEADER, DELIMITER ',')")
    print("Wrote", table)
