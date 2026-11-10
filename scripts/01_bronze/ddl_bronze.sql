/*
===============================================================================
DDL Script: Create Bronze Tables
===============================================================================
Script Purpose:
    Creates the tables of the 'bronze' layer, which hold the source files
    1:1 as raw text, one line per row. Nothing is parsed or interpreted here.

    Each table has a 'line_no' identity column that records the position of
    the line in the source file. The silver layer depends on this order
    (e.g. the fill-down of product codes), so it must be reliable.

    Because the source files have only one field per line, BULK INSERT cannot
    load directly into a table that also has an identity column. The files are
    therefore loaded through the views bronze.v_bom and bronze.v_price_list,
    which expose only 'raw_line'; line_no is then generated automatically.

WARNING:
    Existing bronze tables and views are dropped and recreated.
===============================================================================
*/

USE MaterialCosting;
GO

-------------------------------------------------------------------------------
-- Drop existing objects (views first, they depend on the tables)
-------------------------------------------------------------------------------
IF OBJECT_ID('bronze.v_bom', 'V') IS NOT NULL
    DROP VIEW bronze.v_bom;
GO
IF OBJECT_ID('bronze.v_price_list', 'V') IS NOT NULL
    DROP VIEW bronze.v_price_list;
GO
IF OBJECT_ID('bronze.bom', 'U') IS NOT NULL
    DROP TABLE bronze.bom;
GO
IF OBJECT_ID('bronze.price_list', 'U') IS NOT NULL
    DROP TABLE bronze.price_list;
GO

-------------------------------------------------------------------------------
-- bronze.bom : raw Bill of Materials export
-------------------------------------------------------------------------------
CREATE TABLE bronze.bom
(
    line_no  INT IDENTITY(1,1) NOT NULL,
    raw_line NVARCHAR(500)     NULL,
    CONSTRAINT PK_bronze_bom PRIMARY KEY CLUSTERED (line_no)
);
GO

-------------------------------------------------------------------------------
-- bronze.price_list : raw purchase price list export
-------------------------------------------------------------------------------
CREATE TABLE bronze.price_list
(
    line_no  INT IDENTITY(1,1) NOT NULL,
    raw_line NVARCHAR(500)     NULL,
    CONSTRAINT PK_bronze_price_list PRIMARY KEY CLUSTERED (line_no)
);
GO

-------------------------------------------------------------------------------
-- Load views (BULK INSERT targets that hide the identity column)
-------------------------------------------------------------------------------
CREATE VIEW bronze.v_bom AS
    SELECT raw_line FROM bronze.bom;
GO

CREATE VIEW bronze.v_price_list AS
    SELECT raw_line FROM bronze.price_list;
GO
