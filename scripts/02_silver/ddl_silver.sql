/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
Script Purpose:
    Creates the tables of the 'silver' layer: parsed, typed and cleaned data.

    silver.bom        - one row per parent -> component relationship, with
                        the parent code already filled in on every row.
    silver.price_list - one row per item with its purchase price.
                        item_code is the primary key: a duplicated code in
                        the source file makes the load fail on purpose, as
                        duplicates would multiply costs in the gold layer.

WARNING:
    Existing silver tables are dropped and recreated.
===============================================================================
*/

USE MaterialCosting;
GO

IF OBJECT_ID('silver.bom', 'U') IS NOT NULL
    DROP TABLE silver.bom;
GO

CREATE TABLE silver.bom
(
    source_line_no INT           NOT NULL,   -- bronze.bom.line_no, for tracing back to the file
    parent_code    NVARCHAR(50)  NOT NULL,
    component_code NVARCHAR(50)  NOT NULL,
    quantity       DECIMAL(18,6) NULL,       -- NULL only if unreadable; the load fails in that case
    is_default     BIT           NULL,       -- 1 = default BOM ('Da'), 0 = alternative ('Ne')
    CONSTRAINT PK_silver_bom PRIMARY KEY CLUSTERED (source_line_no)
);
GO

IF OBJECT_ID('silver.price_list', 'U') IS NOT NULL
    DROP TABLE silver.price_list;
GO

CREATE TABLE silver.price_list
(
    item_code  NVARCHAR(100) NOT NULL,
    unit_price DECIMAL(18,6) NULL,           -- NULL = item has no price
    CONSTRAINT PK_silver_price_list PRIMARY KEY CLUSTERED (item_code)
);
GO
