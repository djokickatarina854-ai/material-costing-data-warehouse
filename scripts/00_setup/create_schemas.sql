/*
===============================================================================
Create Schemas
===============================================================================
Script Purpose:
    Creates the schemas used by the data warehouse:
        bronze - raw data, loaded 1:1 from the source files
        silver - parsed, typed and cleaned data
        gold   - business-ready data used for reporting
        etl    - pipeline orchestration and load logging
        adhoc  - helper objects for one-off analyses (not part of the pipeline)

    Safe to run more than once: schemas that already exist are skipped.
===============================================================================
*/

USE MaterialCosting;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze') EXEC('CREATE SCHEMA bronze');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver') EXEC('CREATE SCHEMA silver');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')   EXEC('CREATE SCHEMA gold');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'etl')    EXEC('CREATE SCHEMA etl');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'adhoc')  EXEC('CREATE SCHEMA adhoc');
GO
