@echo off
REM Launches the Persistence MCP server with LAN binding + token auth.
REM Reads the token from %USERPROFILE%\.persistence\token.txt (created by install.ps1).
REM Task Scheduler runs this file at startup.

set PERSISTENCE_HOST=0.0.0.0
set PERSISTENCE_PORT=8077
set OLLAMA_URL=http://localhost:11434
set /p PERSISTENCE_TOKEN=<"%USERPROFILE%\.persistence\token.txt"

"%USERPROFILE%\.persistence\venv\Scripts\persistence-server.exe"
