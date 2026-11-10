/*
===============================================================================
Stored Procedure: Load Bronze Layer (Source Files -> Bronze)
===============================================================================
Script Purpose:
    Loads the source TXT files into the 'bronze' tables using BULK INSERT.
    Actions Performed:
        - Truncates the bronze tables (this also restarts line_no at 1).
        - Loads each file through its load view, so line_no follows file order.
        - Fails with an error if a table ends up empty, so the pipeline stops
          instead of silently continuing with no data.

Parameters:
    @source_folder - folder that contains the source files.
                     Change the default below or pass it when calling.

Usage Example:
    EXEC bronze.load_bronze;
    EXEC bronze.load_bronze @source_folder = N'D:\Data\MaterialCosting\';
===============================================================================
*/

USE MaterialCosting;
GO

CREATE OR ALTER PROCEDURE bronze.load_bronze
    @source_folder NVARCHAR(260) = N'C:\MaterialCosting\source_files\'
AS
BEGIN
    SET NOCOUNT ON;

    -- Source file names (edit here if the exports are named differently)
    DECLARE @bom_file        NVARCHAR(100) = N'bom_export.txt';
    DECLARE @price_list_file NVARCHAR(100) = N'price_list_export.txt';

    DECLARE @start_time       DATETIME;
    DECLARE @batch_start_time DATETIME = GETDATE();
    DECLARE @file_path        NVARCHAR(400);
    DECLARE @sql              NVARCHAR(MAX);
    DECLARE @row_count        INT;

    IF RIGHT(@source_folder, 1) <> N'\'
        SET @source_folder = @source_folder + N'\';

    BEGIN TRY
        PRINT '=========================================================';
        PRINT 'LOADING BRONZE LAYER';
        PRINT '=========================================================';

        ---------------------------------------------------------------
        -- bronze.bom  (2 header lines in the file)
        ---------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.bom';
        TRUNCATE TABLE bronze.bom;

        SET @file_path = @source_folder + @bom_file;
        PRINT '>> Loading file: ' + @file_path;

        -- BULK INSERT only accepts a literal file name, hence dynamic SQL
        SET @sql = N'BULK INSERT bronze.v_bom
                     FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
                     WITH (DATAFILETYPE = ''char'',
                           FIRSTROW     = 3,
                           ROWTERMINATOR = ''0x0a'',
                           CODEPAGE     = ''65001'',
                           TABLOCK);';
        EXEC sys.sp_executesql @sql;

        SELECT @row_count = COUNT(*) FROM bronze.bom;
        IF @row_count = 0
            THROW 50001, N'No rows were loaded into bronze.bom. Check the file path and format.', 1;

        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '------------------------------';

        ---------------------------------------------------------------
        -- bronze.price_list  (1 header line in the file)
        ---------------------------------------------------------------
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: bronze.price_list';
        TRUNCATE TABLE bronze.price_list;

        SET @file_path = @source_folder + @price_list_file;
        PRINT '>> Loading file: ' + @file_path;

        SET @sql = N'BULK INSERT bronze.v_price_list
                     FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
                     WITH (DATAFILETYPE = ''char'',
                           FIRSTROW     = 2,
                           ROWTERMINATOR = ''0x0a'',
                           CODEPAGE     = ''65001'',
                           TABLOCK);';
        EXEC sys.sp_executesql @sql;

        SELECT @row_count = COUNT(*) FROM bronze.price_list;
        IF @row_count = 0
            THROW 50002, N'No rows were loaded into bronze.price_list. Check the file path and format.', 1;

        PRINT '>> Rows loaded: ' + CAST(@row_count AS NVARCHAR(20));
        PRINT '>> Load duration: ' + CAST(DATEDIFF(SECOND, @start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '------------------------------';

        PRINT '======================================================';
        PRINT 'Loading Bronze Layer is Completed';
        PRINT 'Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, GETDATE()) AS NVARCHAR(20)) + ' seconds';
        PRINT '======================================================';
    END TRY
    BEGIN CATCH
        PRINT '======================================================';
        PRINT 'Error occurred during loading bronze layer';
        PRINT 'Error message: ' + ERROR_MESSAGE();
        PRINT 'Error number:  ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '======================================================';
        THROW;   -- re-raise, so the calling script stops here
    END CATCH
END
GO
