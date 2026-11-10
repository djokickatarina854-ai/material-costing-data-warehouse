/*
===============================================================================
Create Database
===============================================================================
Script Purpose:
    Creates the 'MaterialCosting' database. If it already exists, it is dropped and
    recreated from scratch.

WARNING:
    Running this script permanently deletes the entire 'MaterialCosting' database,
    including all bronze, silver and gold data. Only the source files and
    the scripts in this project are needed to rebuild everything.

Next step:
    Run create_schemas.sql
===============================================================================
*/

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'MaterialCosting')
BEGIN
    ALTER DATABASE MaterialCosting SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MaterialCosting;
END
GO

CREATE DATABASE MaterialCosting;
GO
