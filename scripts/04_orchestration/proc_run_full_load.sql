/*
===============================================================================
Stored Procedure: Run Full Load (Bronze -> Silver -> Gold)
===============================================================================
Script Purpose:
    Runs the whole pipeline in order and logs every step to etl.load_log.
    - If a step fails, the pipeline stops at once and later steps do not run.
    - Silver and gold roll back on failure, so they keep the previous
      successful load. (Bronze is emptied before loading, but nothing
      downstream reads it until the next successful run.)

Parameters:
    @source_folder - folder with the source files. If omitted, the default
                     inside bronze.load_bronze is used.

Usage Example:
    EXEC etl.run_full_load @source_folder = N'C:\path\to\source_files\';

    -- Last runs:
    SELECT * FROM etl.load_log ORDER BY log_id DESC;
===============================================================================
*/

USE MaterialCosting;
GO

CREATE OR ALTER PROCEDURE etl.run_full_load
    @source_folder NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_id    UNIQUEIDENTIFIER = NEWID();
    DECLARE @run_start DATETIME2(0)     = SYSDATETIME();
    DECLARE @step_no   INT = 1;
    DECLARE @step_name NVARCHAR(20);
    DECLARE @log_id    INT;
    DECLARE @sql       NVARCHAR(MAX);
    DECLARE @counts    NVARCHAR(200);
    DECLARE @error     NVARCHAR(4000);

    DECLARE @steps TABLE (step_no INT PRIMARY KEY, step_name NVARCHAR(20) NOT NULL);
    INSERT INTO @steps VALUES (1, N'bronze'), (2, N'silver'), (3, N'gold');

    PRINT '#########################################################';
    PRINT 'FULL LOAD STARTED: ' + CONVERT(NVARCHAR(30), @run_start, 120);
    PRINT '#########################################################';

    WHILE @step_no <= 3
    BEGIN
        SELECT @step_name = step_name FROM @steps WHERE step_no = @step_no;

        INSERT INTO etl.load_log (run_id, step_name, started_at, status)
        VALUES (@run_id, @step_name, SYSDATETIME(), 'RUNNING');
        SET @log_id = SCOPE_IDENTITY();

        BEGIN TRY
            SET @sql = CASE @step_name
                WHEN N'bronze' THEN N'EXEC bronze.load_bronze'
                                    + CASE WHEN @source_folder IS NULL
                                           THEN N';'
                                           ELSE N' @source_folder = @folder;' END
                WHEN N'silver' THEN N'EXEC silver.load_silver;'
                WHEN N'gold'   THEN N'EXEC gold.load_gold;'
            END;

            EXEC sys.sp_executesql @sql, N'@folder NVARCHAR(260)', @folder = @source_folder;

            SET @counts = CASE @step_name
                WHEN N'bronze' THEN N'bom='          + CAST((SELECT COUNT(*) FROM bronze.bom)          AS NVARCHAR(20))
                                  + N'; price_list=' + CAST((SELECT COUNT(*) FROM bronze.price_list)   AS NVARCHAR(20))
                WHEN N'silver' THEN N'bom='          + CAST((SELECT COUNT(*) FROM silver.bom)          AS NVARCHAR(20))
                                  + N'; price_list=' + CAST((SELECT COUNT(*) FROM silver.price_list)   AS NVARCHAR(20))
                WHEN N'gold'   THEN N'bom_exploded=' + CAST((SELECT COUNT(*) FROM gold.bom_exploded)   AS NVARCHAR(20))
                                  + N'; products='   + CAST((SELECT COUNT(*) FROM gold.material_cost)   AS NVARCHAR(20))
            END;

            UPDATE etl.load_log
            SET finished_at = SYSDATETIME(),
                status      = 'SUCCESS',
                row_counts  = @counts
            WHERE log_id = @log_id;
        END TRY
        BEGIN CATCH
            SET @error = ERROR_MESSAGE();

            UPDATE etl.load_log
            SET finished_at   = SYSDATETIME(),
                status        = 'FAILED',
                error_message = @error
            WHERE log_id = @log_id;

            PRINT '#########################################################';
            PRINT 'PIPELINE STOPPED at step: ' + @step_name;
            PRINT @error;
            PRINT '#########################################################';
            THROW;
        END CATCH

        SET @step_no = @step_no + 1;
    END

    PRINT '#########################################################';
    PRINT 'FULL LOAD COMPLETED in '
        + CAST(DATEDIFF(SECOND, @run_start, SYSDATETIME()) AS NVARCHAR(20)) + ' seconds';
    PRINT '#########################################################';

    SELECT step_name, status, started_at, finished_at, row_counts
    FROM etl.load_log
    WHERE run_id = @run_id
    ORDER BY log_id;
END
GO
