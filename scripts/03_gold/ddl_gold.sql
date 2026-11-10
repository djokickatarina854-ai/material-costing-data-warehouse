/*
===============================================================================
DDL Script: Create Gold Objects
===============================================================================
Script Purpose:
    Creates the objects of the 'gold' layer.

    gold.bom_exploded     (table) The fully exploded BOM. One row per root
                          product and final material reached through one
                          path of the BOM tree. Filled by gold.load_gold.
    gold.material_cost    (view)  Material cost per product, with a status
                          that explains why a cost is NULL.
    gold.product_materials (view) Raw materials consumed per product:
                          quantity, unit price and cost, summed over all paths.

    Rows with is_cycle = 1 mark a circular reference in the BOM (a product
    that directly or indirectly contains itself). They hold no quantity
    that can be used; they exist so the affected products are reported
    as 'BOM_CYCLE' instead of getting a wrong cost.

WARNING:
    Existing gold objects are dropped and recreated.
===============================================================================
*/

USE MaterialCosting;
GO

IF OBJECT_ID('gold.product_materials', 'V') IS NOT NULL
    DROP VIEW gold.product_materials;
GO
IF OBJECT_ID('gold.material_cost', 'V') IS NOT NULL
    DROP VIEW gold.material_cost;
GO
IF OBJECT_ID('gold.bom_exploded', 'U') IS NOT NULL
    DROP TABLE gold.bom_exploded;
GO

CREATE TABLE gold.bom_exploded
(
    root_product   NVARCHAR(50)  NOT NULL,   -- product the explosion starts from
    parent_code    NVARCHAR(50)  NOT NULL,   -- direct parent of the component
    component_code NVARCHAR(50)  NOT NULL,   -- final material (or the repeated code, if is_cycle = 1)
    bom_level      INT           NOT NULL,   -- depth of the component below root_product
    extended_qty   DECIMAL(18,6) NOT NULL,   -- quantity needed per 1 unit of root_product
    unit_price     DECIMAL(18,6) NULL,       -- NULL = no price
    line_cost      DECIMAL(18,6) NULL,       -- extended_qty * unit_price
    is_cycle       BIT           NOT NULL,
    bom_path       NVARCHAR(MAX) NOT NULL    -- |root|child|...|component|
);
GO

CREATE CLUSTERED INDEX CIX_gold_bom_exploded
    ON gold.bom_exploded (root_product, component_code);
GO

-------------------------------------------------------------------------------
-- Material cost per product
-------------------------------------------------------------------------------
CREATE VIEW gold.material_cost AS
SELECT
    root_product AS product_code,
    CASE
        WHEN MAX(CAST(is_cycle AS INT)) = 1 THEN NULL     -- circular BOM
        WHEN COUNT(*) <> COUNT(line_cost)   THEN NULL     -- at least one material has no price
        ELSE SUM(line_cost)
    END AS material_cost,
    CASE
        WHEN MAX(CAST(is_cycle AS INT)) = 1 THEN 'BOM_CYCLE'
        WHEN COUNT(*) <> COUNT(line_cost)   THEN 'MISSING_PRICE'
        ELSE 'OK'
    END AS cost_status
FROM gold.bom_exploded
GROUP BY root_product;
GO

-------------------------------------------------------------------------------
-- Raw materials consumed per product
-------------------------------------------------------------------------------
CREATE VIEW gold.product_materials AS
SELECT
    root_product       AS product_code,
    component_code     AS material_code,
    SUM(extended_qty)  AS total_quantity,
    MAX(unit_price)    AS unit_price,      -- one price per material, so MAX just picks it
    SUM(line_cost)     AS total_cost       -- NULL when the material has no price
FROM gold.bom_exploded
WHERE is_cycle = 0
GROUP BY root_product, component_code;
GO
