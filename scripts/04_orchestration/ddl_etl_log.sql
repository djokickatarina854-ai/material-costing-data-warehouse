/*
===============================================================================
DDL Script: ETL Load Log
===============================================================================
Script Purpose:
    Creates etl.load_log, which records every step of every pipeline run:
    when it started and finished, whether it succeeded, how many rows it
    produced and, if it failed, the error message.

    Unlike the other DDL scripts this one does NOT drop an existing table,
    so the run history survives when the warehouse objects are rebuilt.

    Also creates the view etl.last_refresh, which returns the time of the
    last successful full load (useful as "data refreshed at" in reports).
===============================================================================
*/

USE MaterialCosting;
GO

IF OBJECT_ID('etl.load_log', 'U') IS NULL
BEGIN
    CREATE TABLE etl.load_log
    (
        log_id        INT IDENTITY(1,1) NOT NULL,
        run_id        UNIQUEIDENTIFIER  NOT NULL,   -- one value per full run
        step_name     NVARCHAR(20)      NOT NULL,   -- bronze / silver / gold
        started_at    DATETIME2(0)      NOT NULL,
        finished_at   DATETIME2(0)      NULL,
        status        NVARCHAR(10)      NOT NULL,   -- RUNNING / SUCCESS / FAILED
        row_counts    NVARCHAR(200)     NULL,
        error_message NVARCHAR(4000)    NULL,
        CONSTRAINT PK_etl_load_log PRIMARY KEY CLUSTERED (log_id)
    );
END
GO

CREATE OR ALTER VIEW etl.last_refresh AS
SELECT MAX(finished_at) AS last_refresh_at
FROM etl.load_log
WHERE step_name = 'gold'
  AND status = 'SUCCESS';
GO
