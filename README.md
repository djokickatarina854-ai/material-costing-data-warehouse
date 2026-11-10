# Material Costing Data Warehouse

A SQL Server data warehouse built on the **Medallion Architecture** (bronze → silver → gold) that calculates the **material-only cost** of manufactured products. It recursively explodes multi-level Bill of Materials (BOM) data exported from an ERP system, down to final materials, and prices each material from a purchase price list.

This is an independent portfolio project. It models a common manufacturing costing problem and contains no company data.

---

## Business problem

In an ERP system, a manufactured component is usually carried at its **full production cost**. Costing a higher-level product, however, needs only the **material part** of that cost.

| | Full ERP cost | Material cost |
|---|---|---|
| Component `X001` | 200 | 70 |
| Product `Y001` = 2 × `X001` | 2 × 200 = **400** (wrong) | 2 × 70 = **140** (correct) |

The solution ignores the ERP's full cost entirely. For every product it follows the BOM down through every sub-assembly to the **final materials** (components that have no BOM of their own), multiplies quantities along the way, and prices those materials.

**What you get**

- Material cost for **any** product, finished goods and sub-assemblies alike.
- For each product, the **raw materials consumed**: total quantity, unit price and cost.
- A **status** next to every cost that explains why a cost is missing (no price, or a circular BOM).
- A run log and a set of data quality checks for the daily refresh.

---

## Architecture

```
 Source files (.txt)
        │   BULK INSERT
        ▼
 ┌────────────┐   Raw text, one line per row, plus the line number
 │   BRONZE   │   Nothing is interpreted here
 └────────────┘
        │   parse, type, clean
        ▼
 ┌────────────┐   One typed row per parent → component relationship
 │   SILVER   │   Product codes filled down, total lines removed,
 └────────────┘   prices as numbers
        │   explode BOM, price materials
        ▼
 ┌────────────┐   Fully exploded BOM + reporting views
 │    GOLD    │   (material cost per product, materials per product)
 └────────────┘

 etl   : run log and orchestration        adhoc : helper objects for one-off analyses
```

| Layer | Responsibility |
|---|---|
| **Bronze** | Load the files 1:1 as text. Structure never changes, so reloads are always stable. |
| **Silver** | Everything needed to make the data *correct and usable*: parsing fixed-width columns, typing, cleaning, fill-down. |
| **Gold** | Everything needed to answer *business questions*: BOM explosion, pricing, cost per product. |

The warehouse is **fully reloaded** on every run (truncate and load). No history is kept; the data always reflects the latest export.

---

## Repository structure

```
material-costing-data-warehouse/
├── README.md
└── scripts/
    ├── 00_setup/
    │   ├── create_database.sql        Creates the database (drops it if it exists)
    │   └── create_schemas.sql         bronze, silver, gold, etl, adhoc
    ├── 01_bronze/
    │   ├── ddl_bronze.sql             Tables and load views
    │   └── proc_load_bronze.sql       bronze.load_bronze
    ├── 02_silver/
    │   ├── ddl_silver.sql             Tables
    │   └── proc_load_silver.sql       silver.load_silver
    ├── 03_gold/
    │   ├── ddl_gold.sql               Table and views
    │   └── proc_load_gold.sql         gold.load_gold
    ├── 04_orchestration/
    │   ├── ddl_etl_log.sql            etl.load_log, etl.last_refresh
    │   └── proc_run_full_load.sql     etl.run_full_load
    └── 05_quality_checks/
        └── quality_checks.sql         Read-only checks, run after every load
```

Folders are numbered in execution order. Inside each folder, scripts run in the order listed (DDL before procedures).

---

## Data model

### Bronze

| Object | Columns | Notes |
|---|---|---|
| `bronze.bom` | `line_no`, `raw_line` | One row per line of the BOM export. `line_no` follows the file order. |
| `bronze.price_list` | `line_no`, `raw_line` | One row per line of the price list. |
| `bronze.v_bom`, `bronze.v_price_list` | `raw_line` | Views used as `BULK INSERT` targets (see [Design decisions](#design-decisions)). |

### Silver

| Table | Columns | Notes |
|---|---|---|
| `silver.bom` | `source_line_no`, `parent_code`, `component_code`, `quantity`, `is_default` | One row per parent → component line. `source_line_no` traces back to `bronze.bom.line_no`. |
| `silver.price_list` | `item_code` (PK), `unit_price` | `unit_price` is `NULL` when the item has no price. |

### Gold

| Object | Type | Columns |
|---|---|---|
| `gold.bom_exploded` | table | `root_product`, `parent_code`, `component_code`, `bom_level`, `extended_qty`, `unit_price`, `line_cost`, `is_cycle`, `bom_path` |
| `gold.material_cost` | view | `product_code`, `material_cost`, `cost_status` |
| `gold.product_materials` | view | `product_code`, `material_code`, `total_quantity`, `unit_price`, `total_cost` |

`gold.bom_exploded` holds one row per root product and final material reached through one path of the BOM tree. `cost_status` is one of:

| Status | Meaning |
|---|---|
| `OK` | Every final material has a price. |
| `MISSING_PRICE` | At least one final material has no price, so `material_cost` is `NULL` instead of a misleading partial sum. |
| `BOM_CYCLE` | The product directly or indirectly contains itself, so no cost can be calculated. |

### ETL

| Object | Purpose |
|---|---|
| `etl.load_log` | One row per pipeline step per run: start, finish, status, row counts, error message. |
| `etl.last_refresh` | View returning the time of the last successful full load. |

---

## Pipeline

| Procedure | What it does |
|---|---|
| `bronze.load_bronze` | Truncates the bronze tables and loads both files with `BULK INSERT` (through the load views). Fails if a table ends up empty. |
| `silver.load_silver` | Parses the fixed-width BOM lines and the tab-separated price lines, removes totals, fills the product code down, and converts quantities and prices. Runs in one transaction. |
| `gold.load_gold` | Explodes the default BOM of every product to final materials, multiplying quantities level by level, prices the materials and flags circular references. Runs in one transaction. |
| `etl.run_full_load` | Runs the three steps in order, logs each step to `etl.load_log` and stops at the first error. |

**Error handling.** Every procedure re-raises its error (`THROW`), so a failure stops the pipeline instead of letting later steps run on bad or empty data. Silver and gold roll back on failure and keep the previous successful load.

---

## Source files

The pipeline expects two text exports from an ERP system. No data files are included in this repository; the expected formats are described here.

### BOM export (`bom_export.txt`)

A fixed-width report, two header lines, then one line per component. The product code is printed only on the first line of each BOM, which is why silver fills it down.

| Content | Characters |
|---|---|
| Product code | 2–27 |
| Default BOM flag (`Da` / `Ne`) | 28–49 |
| Component code | 51–80 |
| Quantity (right-aligned) | 81–100 |

- Lines containing `Ukupno` (total) are removed.
- **The export must be filtered to default BOMs** (`Da`) in the ERP. Silver keeps the flag in `is_default` and gold uses only default lines, so an unfiltered export cannot double-count alternative BOMs; quality check 4 reports it if one slips through.

### Price list (`price_list_export.txt`)

Tab-separated, one header line: item code, purchase price. Prices may be quoted with a thousands separator (`"2,002.65"`), and codes containing a comma are quoted too. Items without a price are simply absent or have an empty price.

Both files use Windows (`CRLF`) line endings and UTF-8. The file names are set at the top of `bronze.load_bronze`.

---

## Getting started

**Requirements:** SQL Server 2016 SP1 or later (uses `CREATE OR ALTER`, `DROP TABLE IF EXISTS`, `THROW`, `TRY_CONVERT`), developed on SQL Server Express. `BULK INSERT` reads files from the machine the SQL Server instance runs on, so the SQL Server service account needs read access to the source folder.

1. Run the scripts in `00_setup`, then `01_bronze`, `02_silver`, `03_gold` and `04_orchestration`, in the order listed.
2. Put the two export files in one folder.
3. Run the pipeline:

```sql
EXEC etl.run_full_load @source_folder = N'C:\path\to\source_files\';
```

4. Check the run and the data:

```sql
SELECT * FROM etl.load_log ORDER BY log_id DESC;
-- then run scripts/05_quality_checks/quality_checks.sql
```

Repeat step 3 whenever the exports change.

---

## Using the results

```sql
-- Material cost of one product
SELECT * FROM gold.material_cost WHERE product_code = 'PRODUCT-CODE';

-- Raw materials consumed by that product: quantity, price, cost
SELECT *
FROM gold.product_materials
WHERE product_code = 'PRODUCT-CODE'
ORDER BY material_code;

-- Where each material sits in the BOM tree
SELECT * FROM gold.bom_exploded
WHERE root_product = 'PRODUCT-CODE'
ORDER BY bom_level;

-- Which products cannot be costed, and why
SELECT cost_status, COUNT(*) FROM gold.material_cost GROUP BY cost_status;

-- When the data was last refreshed
SELECT * FROM etl.last_refresh;
```

---

## Data quality

`scripts/05_quality_checks/quality_checks.sql` returns a summary with one row per check, followed by a detail query for each check.

| # | Check | Severity |
|---|---|---|
| 1 | Products with a circular BOM | ERROR |
| 2 | Possibly truncated codes (fixed-width field is full) | ERROR |
| 3 | BOM lines with zero or negative quantity | ERROR |
| 4 | BOM lines that are not the default BOM | WARNING |
| 5 | Duplicate BOM lines (same parent and component) | WARNING |
| 6 | Prices that are zero or negative | WARNING |
| 7 | Materials without a price (with the number of products each one blocks) | WARNING |
| 8 | Unpriced materials that exist in the price list under a slightly different code | WARNING |

`ERROR` means the numbers are not reliable until the source is fixed. `WARNING` means the results are valid but incomplete or worth reviewing.

---

## Design decisions

- **Bronze keeps a single raw text column.** Adding typed columns to a bronze table makes `BULK INSERT` fail as soon as the file's field count differs from the table's. All parsing lives in silver.
- **Reliable line order through an identity column and a load view.** The fill-down in silver depends on the order of the lines, and `ROW_NUMBER() OVER (ORDER BY (SELECT NULL))` does not guarantee any order. Bronze tables therefore have an `IDENTITY` column, and `BULK INSERT` loads through a view that exposes only `raw_line`, so the identity is generated in file order.
- **Fill-down belongs to silver.** Propagating the product code to every component row and removing total lines is cleaning, so silver already produces a clean parent → component list.
- **An empty price is `NULL`, not `0`.** `TRY_CONVERT(DECIMAL, '')` returns `0`, which would silently price a material at zero and make the costing look complete. Empty values are turned into `NULL` before conversion.
- **A missing price makes the product's cost `NULL`.** A partial sum would understate the cost without any warning.
- **Circular references are recorded, not followed.** The recursion tracks the path of every branch. When a code repeats, the row is stored with `is_cycle = 1` and not expanded, so one bad BOM cannot stop the load, and the affected products are reported as `BOM_CYCLE`.
- **Every product is exploded on its own.** Cost and materials are available for sub-assemblies as well as for finished products.
- **The exploded BOM is a table, the reports are views.** `gold.bom_exploded` keeps the path-level detail (level, parent, path). `gold.material_cost` and `gold.product_materials` are aggregations of it, so the cost logic exists in one place.
- **The price list has a primary key on the item code.** A duplicated code in an export fails the load, instead of multiplying costs through a join.
- **Silver and gold load in transactions.** A failed run leaves the previous successful data in place.

---

## Limitations and roadmap

- Material cost only: no labor, overhead or outsourced processing.
- No history: each run replaces the previous one.
- Items are not classified by type (raw material, manufactured component, purchased component). A component without its own BOM is treated as a final material.
- Planned extensions: suppliers, outsourced processing costs, optional snapshots of historical costs, and a read-only web application on top of the gold views.

---

## License and copyright

Copyright © 2026 Katarina Dokic. All rights reserved.

This repository is published for portfolio and demonstration purposes only. No license is granted to use, copy, modify, merge, publish, distribute or sublicense any part of this code or documentation without prior written permission from the author.
