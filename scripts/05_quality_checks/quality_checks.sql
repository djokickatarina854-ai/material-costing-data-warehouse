/*
===============================================================================
Quality Checks
===============================================================================
Script    : scripts/05_quality_checks/quality_checks.sql
Database  : MaterialCosting

Purpose
    Read-only data quality checks. Run after every full load
    (EXEC etl.run_full_load). Nothing is changed in the database.

Output
    1) SUMMARY  : one row per check (check_no, check_name, severity, issue_count)
    2) DETAILS  : one result set per check, listing the affected rows.
                  Only look at the checks where issue_count > 0.

Severity
    ERROR   - numbers are not reliable until the source data is fixed
    WARNING - results are valid but incomplete, or worth reviewing

Checks
    1  Products with a circular BOM
    2  Possibly truncated codes (fixed-width field is completely full)
    3  BOM lines with missing, zero or negative quantity
    4  BOM lines that are not the default BOM
    5  Duplicate BOM lines (same parent and component)
    6  Prices that are zero or negative
    7  Materials without a price (and how many products each one blocks)
    8  Unpriced materials found in the price list under a slightly
       different code (spaces, hyphens, slashes)
===============================================================================
*/

USE MaterialCosting;
GO

SET NOCOUNT ON;

/* ============================================================================
   1) SUMMARY
============================================================================ */
SELECT check_no, check_name, severity, issue_count
FROM
(
    SELECT 1 AS check_no,
           'Products with a circular BOM' AS check_name,
           'ERROR' AS severity,
           COUNT(DISTINCT root_product) AS issue_count
    FROM gold.bom_exploded
    WHERE is_cycle = 1

    UNION ALL

    SELECT 2,
           'Possibly truncated codes',
           'ERROR',
           COUNT(*)
    FROM silver.bom
    WHERE LEN(parent_code)    >= 26      -- parent field: positions 2-27
       OR LEN(component_code) >= 30      -- component field: positions 51-80

    UNION ALL

    SELECT 3,
           'BOM lines with missing, zero or negative quantity',
           'ERROR',
           COUNT(*)
    FROM silver.bom
    WHERE quantity IS NULL OR quantity <= 0

    UNION ALL

    SELECT 4,
           'BOM lines that are not the default BOM',
           'WARNING',
           COUNT(*)
    FROM silver.bom
    WHERE is_default IS NULL OR is_default = 0

    UNION ALL

    SELECT 5,
           'Duplicate BOM lines (same parent and component)',
           'WARNING',
           COUNT(*)
    FROM
    (
        SELECT parent_code, component_code
        FROM silver.bom
        GROUP BY parent_code, component_code
        HAVING COUNT(*) > 1
    ) AS d

    UNION ALL

    SELECT 6,
           'Prices that are zero or negative',
           'WARNING',
           COUNT(*)
    FROM silver.price_list
    WHERE unit_price <= 0

    UNION ALL

    SELECT 7,
           'Materials without a price',
           'WARNING',
           COUNT(DISTINCT component_code)
    FROM gold.bom_exploded
    WHERE is_cycle = 0
      AND unit_price IS NULL

    UNION ALL

    SELECT 8,
           'Unpriced materials present in price list under a similar code',
           'WARNING',
           COUNT(DISTINCT m.component_code)
    FROM
    (
        SELECT DISTINCT component_code
        FROM gold.bom_exploded
        WHERE is_cycle = 0
          AND unit_price IS NULL
    ) AS m
    JOIN silver.price_list AS p
      ON  REPLACE(REPLACE(REPLACE(p.item_code,      ' ', ''), '-', ''), '/', '')
        = REPLACE(REPLACE(REPLACE(m.component_code, ' ', ''), '-', ''), '/', '')
     AND p.item_code <> m.component_code
) AS summary
ORDER BY check_no;


/* ============================================================================
   2) DETAILS
============================================================================ */

-- 1) Products with a circular BOM -------------------------------------------
SELECT DISTINCT
       root_product,
       bom_path
FROM gold.bom_exploded
WHERE is_cycle = 1
ORDER BY root_product;

-- 2) Possibly truncated codes -----------------------------------------------
SELECT source_line_no,
       parent_code,
       component_code,
       LEN(parent_code)    AS parent_length,
       LEN(component_code) AS component_length
FROM silver.bom
WHERE LEN(parent_code)    >= 26
   OR LEN(component_code) >= 30
ORDER BY source_line_no;

-- 3) BOM lines with missing, zero or negative quantity ----------------------
SELECT source_line_no,
       parent_code,
       component_code,
       quantity
FROM silver.bom
WHERE quantity IS NULL OR quantity <= 0
ORDER BY source_line_no;

-- 4) BOM lines that are not the default BOM ---------------------------------
SELECT source_line_no,
       parent_code,
       component_code,
       quantity,
       is_default
FROM silver.bom
WHERE is_default IS NULL OR is_default = 0
ORDER BY source_line_no;

-- 5) Duplicate BOM lines ----------------------------------------------------
SELECT b.parent_code,
       b.component_code,
       COUNT(*)        AS line_count,
       SUM(b.quantity) AS total_quantity,
       MIN(b.source_line_no) AS first_source_line_no
FROM silver.bom AS b
GROUP BY b.parent_code, b.component_code
HAVING COUNT(*) > 1
ORDER BY line_count DESC, b.parent_code;

-- 6) Prices that are zero or negative ---------------------------------------
SELECT item_code,
       unit_price
FROM silver.price_list
WHERE unit_price <= 0
ORDER BY item_code;

-- 7) Materials without a price, ranked by number of products they block -----
SELECT component_code           AS material_code,
       COUNT(DISTINCT root_product) AS products_blocked
FROM gold.bom_exploded
WHERE is_cycle = 0
  AND unit_price IS NULL
GROUP BY component_code
ORDER BY products_blocked DESC, material_code;

-- 8) Unpriced materials that exist in the price list under a similar code ---
SELECT m.component_code AS material_code_in_bom,
       p.item_code      AS similar_code_in_price_list,
       p.unit_price
FROM
(
    SELECT DISTINCT component_code
    FROM gold.bom_exploded
    WHERE is_cycle = 0
      AND unit_price IS NULL
) AS m
JOIN silver.price_list AS p
  ON  REPLACE(REPLACE(REPLACE(p.item_code,      ' ', ''), '-', ''), '/', '')
    = REPLACE(REPLACE(REPLACE(m.component_code, ' ', ''), '-', ''), '/', '')
 AND p.item_code <> m.component_code
ORDER BY m.component_code;
GO
