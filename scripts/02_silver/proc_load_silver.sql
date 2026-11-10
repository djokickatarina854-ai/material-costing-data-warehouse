/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    Parses and cleans the raw bronze text into typed silver tables.

    silver.bom
        - Cuts the fixed-width columns (product, default flag, component,
          quantity) out of each raw line.
        - Removes 'Ukupno' (total) lines.
        - Fills the product code down: the source file prints it only on the
          first line of each BOM, so every component row inherits the code
          of the nearest product line above it (ordered by line_no).
    silver.price_list
        - Splits each tab-separated line into item code and price, removes
          quotes and thousands separators ("2,002.65" -> 2002.65).
        - An empty price becomes NULL (not 0).

    Everything runs in one transaction: if anything fails, silver keeps the
    previous load and the error is re-raised so the pipeline stops.

Parameters:
    None.

Usage Example:
    EXEC silver.load_silver;
===============================================================================
*/

USE MaterialCosting;
GO

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time       DATETIME;
    DECLARE @batch_start_time DATETIME = GETDATE();
    DECLARE @row_count        INT;

    BEGIN TRY
        PRINT '=========================================================';
        PRINT 'LOADING SILVER LAYER';
        PRINT '=========================================================';

        BEGIN TRANSACTION;

        ---------------------------------------------------------------
        -- silver.bom
        ---------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.bom';
        TRUNCATE TABLE silver.bom;

        PRINT '>> Inserting Data Into: silver.bom';

        WITH parsed AS
        (
            SELECT
                b.line_no,
                NULLIF(LTRIM(RTRIM(SUBSTRING(l.line,  2, 26))), '') AS product_code,
                NULLIF(LTRIM(RTRIM(SUBSTRING(l.line, 28, 22))), '') AS default_flag,
                NULLIF(LTRIM(RTRIM(SUBSTRING(l.line, 51, 30))), '') AS component_code,
                TRY_CONVERT(DECIMAL(18,6),
                    NULLIF(REPLACE(LTRIM(RTRIM(SUBSTRING(l.line, 81, 20))), ',', ''), '')
                ) AS quantity
            FROM bronze.bom b
            CROSS APPLY (SELECT REPLACE(b.raw_line, CHAR(13), '') AS line) l
        ),
        cleaned AS
        (
            -- drop total lines before the fill-down
            SELECT *
            FROM parsed
            WHERE ISNULL(product_code,   '') <> 'Ukupno'
              AND ISNULL(default_flag,   '') <> 'Ukupno'
              AND ISNULL(component_code, '') <> 'Ukupno'
        ),
        marked AS
        (
            SELECT
                c.*,
                -- line_no of the nearest product line at or above this row
                MAX(CASE WHEN product_code IS NOT NULL THEN line_no END)
                    OVER (ORDER BY line_no ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                    AS product_line_no,
                -- line_no of the nearest line carrying a Da/Ne flag
                MAX(CASE WHEN default_flag IN ('Da', 'Ne') THEN line_no END)
                    OVER (ORDER BY line_no ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                    AS flag_line_no
            FROM cleaned c
        )
        INSERT INTO silver.bom (source_line_no, parent_code, component_code, quantity, is_default)
        SELECT
            m.line_no,
            p.product_code,
            m.component_code,
            m.quantity,
            CASE
                WHEN f.line_no >= m.product_line_no     -- flag belongs to this product
                    THEN CASE f.default_flag WHEN 'Da' THEN 1 WHEN 'Ne' THEN 0 END
            END
        FROM marked m
        INNER JOIN cleaned p ON p.line_no = m.product_line_no
        LEFT  JOIN cleaned f ON f.line_no = m.flag_line_no
        WHERE m.component_code IS NOT NULL;

        SET @row_count = @@ROWCOUNT;

        IF @row_count = 0
            THROW 50010, N'No rows were loaded into silver.bom. Check bronze.bom and the column positions.', 1;

        IF EXISTS (SELECT 1 FROM silver.bom WHERE quantity IS NULL)
            THROW 50011, N'silver.bom has rows with an unreadable quantity. Check the source file (column positions or number format).', 1;

        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '------------------------------';

        ---------------------------------------------------------------
        -- silver.price_list
        ---------------------------------------------------------------
        SET @start_time = GETDATE();

        IF EXISTS (SELECT 1 FROM bronze.price_list
                   WHERE LTRIM(RTRIM(REPLACE(raw_line, CHAR(13), ''))) <> ''
                     AND CHARINDEX(CHAR(9), raw_line) = 0)
            THROW 50020, N'bronze.price_list has lines without a tab separator. The file format has changed.', 1;

        PRINT '>> Truncating Table: silver.price_list';
        TRUNCATE TABLE silver.price_list;

        PRINT '>> Inserting Data Into: silver.price_list';

        INSERT INTO silver.price_list (item_code, unit_price)
        SELECT
            LTRIM(RTRIM(REPLACE(LEFT(l.line, t.tab_pos - 1), '"', ''))) AS item_code,
            TRY_CONVERT(DECIMAL(18,6),
                NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(
                    SUBSTRING(l.line, t.tab_pos + 1, 400), '"', ''), ',', ''))), '')
            ) AS unit_price
        FROM bronze.price_list b
        CROSS APPLY (SELECT REPLACE(b.raw_line, CHAR(13), '') AS line) l
        CROSS APPLY (SELECT CHARINDEX(CHAR(9), l.line) AS tab_pos) t
        WHERE t.tab_pos > 1;

        SET @row_count = @@ROWCOUNT;

        IF @row_count = 0
            THROW 50021, N'No rows were loaded into silver.price_list. Check bronze.price_list.', 1;

        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '------------------------------';

        COMMIT TRANSACTION;

        PRINT '======================================================';
        PRINT 'Loading Silver Layer is Completed';
        PRINT 'Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '======================================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        PRINT '======================================================';
        PRINT 'Error occurred during loading silver layer';
        PRINT 'Error message: ' + ERROR_MESSAGE();
        PRINT 'Error number:  ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '======================================================';
        THROW;
    END CATCH
END
GO
