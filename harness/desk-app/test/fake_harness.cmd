@echo off
rem The stand-in harness as a program Windows can start: desk.json names this file.
set "FAKE_BINARY=%~f0"
python "%~dp0fake_harness.py" %*
