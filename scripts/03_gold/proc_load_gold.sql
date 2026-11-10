/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
Script Purpose:
    Fills gold.bom_exploded from silver.bom and silver.price_list.

    - Uses only the default BOM (is_default = 1).
    - Every product that has a BOM is exploded on its own, so the cost and
      the materials are available for finished products AND sub-assemblies.
    - Explodes the BOM level by level, multiplying quantities on the way down,
      until it reaches components that have no BOM of their own (final materials).
    - Prices each final material from silver.price_list.
    - Detects circular references: the loop is recorded (is_cycle = 1) and
      not followed further, so one bad BOM cannot break the whole load.

    gold.material_cost and gold.product_materials are views and need no loading.
    Runs in one transaction: on failure gold keeps the previous load.

Parameters:
    None.

Usage Example:
    EXEC gold.load_gold;
===============================================================================
*/

USE MaterialCosting;
GO

CREATE OR ALTER PROCEDURE gold.load_gold AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time DATETIME = GETDATE();
    DECLARE @row_count  INT;
    DECLARE @products   INT, @cycles INT, @missing INT;

    BEGIN TRY
        PRINT '=========================================================';
        PRINT 'LOADING GOLD LAYER';
        PRINT '=========================================================';

        BEGIN TRANSACTION;

        -- Working copy of the default BOM edges, indexed for the recursion
        DROP TABLE IF EXISTS #edges;

        SELECT parent_code, component_code, quantity
        INTO #edges
        FROM silver.bom
        WHERE is_default = 1;

        IF @@ROWCOUNT = 0
            THROW 50030, N'silver.bom has no default BOM rows (is_default = 1). Nothing to explode.', 1;

        CREATE CLUSTERED INDEX CIX_edges ON #edges (parent_code);

        PRINT '>> Truncating Table: gold.bom_exploded';
        TRUNCATE TABLE gold.bom_exploded;

        PRINT '>> Inserting Data Into: gold.bom_exploded';

        WITH bom_cte AS
        (
            -- LEVEL 1: every BOM line is the start of an explosion for its parent
            SELECT
                e.parent_code                                   AS root_product,
                e.parent_code                                   AS parent_code,
                e.component_code                                AS component_code,
                CAST(e.quantity AS DECIMAL(18,6))               AS extended_qty,
                1                                               AS bom_level,
                CAST('|' + e.parent_code + '|' + e.component_code + '|' AS NVARCHAR(MAX)) AS bom_path,
                CAST(CASE WHEN e.parent_code = e.component_code THEN 1 ELSE 0 END AS BIT) AS is_cycle
            FROM #edges e

            UNION ALL

            -- DRILL DOWN: expand components that have their own BOM
            SELECT
                c.root_product,
                e.parent_code,
                e.component_code,
                CAST(c.extended_qty * e.quantity AS DECIMAL(18,6)),
                c.bom_level + 1,
                c.bom_path + e.component_code + '|',
                CAST(CASE WHEN CHARINDEX('|' + e.component_code + '|', c.bom_path) > 0 THEN 1 ELSE 0 END AS BIT)
            FROM bom_cte c
            INNER JOIN #edges e
                ON e.parent_code = c.component_code
            WHERE c.is_cycle = 0       -- never expand a row that closed a loop
        )
        INSERT INTO gold.bom_exploded
            (root_product, parent_code, component_code, bom_level,
             extended_qty, unit_price, line_cost, is_cycle, bom_path)
        SELECT
            c.root_product,
            c.parent_code,
            c.component_code,
            c.bom_level,
            c.extended_qty,
            CASE WHEN c.is_cycle = 0 THEN p.unit_price END,
            CASE WHEN c.is_cycle = 0 THEN c.extended_qty * p.unit_price END,
            c.is_cycle,
            c.bom_path
        FROM bom_cte c
        LEFT JOIN silver.price_list p
            ON p.item_code = c.component_code
        WHERE c.is_cycle = 1                                   -- keep loop markers
           OR NOT EXISTS (SELECT 1 FROM #edges x
                          WHERE x.parent_code = c.component_code)   -- final materials only
        OPTION (MAXRECURSION 1000);

        SET @row_count = @@ROWCOUNT;

        IF @row_count = 0
            THROW 50031, N'No rows were produced in gold.bom_exploded.', 1;

        COMMIT TRANSACTION;

        SELECT @products = COUNT(*) FROM gold.material_cost;
        SELECT @cycles   = COUNT(*) FROM gold.material_cost WHERE cost_status = 'BOM_CYCLE';
        SELECT @missing  = COUNT(*) FROM gold.material_cost WHERE cost_status = 'MISSING_PRICE';

        PRINT '>> Rows in gold.bom_exploded: ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '>> Products costed:           ' + CAST(@products  AS NVARCHAR(20));
        PRINT '>> Products with missing price: ' + CAST(@missing AS NVARCHAR(20));
        IF @cycles > 0
            PRINT '>> WARNING: ' + CAST(@cycles AS NVARCHAR(20))
                + ' products have a circular BOM (cost_status = BOM_CYCLE). '
                + 'See: SELECT * FROM gold.bom_exploded WHERE is_cycle = 1';

        PRINT '======================================================';
        PRINT 'Loading Gold Layer is Completed';
        PRINT 'Total Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '======================================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        PRINT '======================================================';
        PRINT 'Error occurred during loading gold layer';
        PRINT 'Error message: ' + ERROR_MESSAGE();
        PRINT 'Error number:  ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '======================================================';
        THROW;
    END CATCH
END
GO
