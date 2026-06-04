@echo off
:: WNBA Pipeline — Windows Task Scheduler entry point
:: Schedule this file to run every 30 minutes via Task Scheduler.
::
:: Setup steps:
::   1. Open Task Scheduler → Create Basic Task
::   2. Trigger: Daily, repeat every 30 minutes, duration: 1 day
::   3. Action: Start a program
::      Program:  C:\Program Files\R\R-4.x.x\bin\Rscript.exe
::      Arguments: "G:\My Drive\Scripting Projects\wnba_project\scripts\run_pipeline.R"
::      Start in: G:\My Drive\Scripting Projects\wnba_project
::
:: Or simply point Task Scheduler at this .bat file directly.

SET R_HOME=C:\Program Files\R\R-4.4.0
SET RSCRIPT=%R_HOME%\bin\Rscript.exe
SET SCRIPT_DIR=G:\My Drive\Scripting Projects\wnba_project

"%RSCRIPT%" "%SCRIPT_DIR%\scripts\run_pipeline.R" >> "%SCRIPT_DIR%\logs\scheduler.log" 2>&1
