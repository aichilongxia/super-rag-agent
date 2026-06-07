@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ====================================
echo Starting SuperBizAgent Services
echo ====================================
echo.

REM Check if uv is installed (optional, falls back to pip if not available)
echo [1/6] Checking package manager...
where uv >nul 2>&1
if errorlevel 1 (
    echo [Info] uv not installed, will use traditional pip approach
    echo [Tip] Install uv for faster setup: pip install uv
    set USE_UV=0
) else (
    echo [Success] uv package manager detected
    set USE_UV=1
)
echo.

REM Ensure correct Python version
echo [2/6] Configuring Python version...
if exist .python-version (
    set /p PYTHON_VERSION=<.python-version
    echo [Info] Current configured version: !PYTHON_VERSION!
    
    REM Check if it's 3.10 (incompatible)
    echo !PYTHON_VERSION! | findstr /C:"3.10" >nul
    if not errorlevel 1 (
        echo [Warning] Python 3.10 is incompatible, auto-updating to 3.13...
        echo 3.13> .python-version
        echo [Success] Updated to Python 3.13
    )
) else (
    echo [Info] Creating .python-version file...
    echo 3.13> .python-version
)
echo.

REM Create or sync virtual environment
echo [3/6] Creating/syncing virtual environment...
if exist .venv\Scripts\python.exe (
    echo [Info] Virtual environment exists, checking for updates...
    
    REM If uv is available, try uv sync
    if "%USE_UV%"=="1" (
        uv sync 2>nul
        if errorlevel 1 (
            echo [Warning] uv sync failed, using pip update...
            .venv\Scripts\python.exe -m pip install -e . -q
        ) else (
            echo [Success] Sync completed with uv
        )
    ) else (
        echo [Info] Updating dependencies with pip...
        .venv\Scripts\python.exe -m pip install -e . -q
    )
) else (
    echo [Info] Creating new virtual environment...
    
    REM If uv is available, try uv sync
    if "%USE_UV%"=="1" (
        echo [Info] Attempting to create with uv sync...
        uv sync 2>nul
        if not errorlevel 1 (
            echo [Success] Created with uv
            goto :venv_created
        )
        echo [Warning] uv sync failed, falling back to traditional approach...
    )
    
    REM Create using traditional python -m venv
    echo [Info] Creating with python -m venv...
    python -m venv .venv
    if errorlevel 1 (
        echo [Error] Failed to create virtual environment
        echo [Tip] Please ensure Python 3.11+ is installed
        pause
        exit /b 1
    )
    
    REM Install dependencies
    echo [Info] Installing project dependencies (this may take a few minutes)...
    .venv\Scripts\python.exe -m pip install --upgrade pip -q
    .venv\Scripts\python.exe -m pip install -e . -q
    if errorlevel 1 (
        echo [Error] Dependency installation failed
        pause
        exit /b 1
    )
    echo [Success] Virtual environment created
)

:venv_created
echo [Success] Virtual environment ready
echo.

REM Set Python command
set PYTHON_CMD=.venv\Scripts\python.exe

REM Start Docker Compose
echo [4/6] Starting Milvus vector database...
docker ps --format "{{.Names}}" | findstr "milvus-standalone" >nul 2>&1
if not errorlevel 1 (
    echo [Info] Milvus container already running
) else (
    docker compose -f vector-database.yml up -d
    if errorlevel 1 (
        echo [Error] Docker startup failed, please ensure Docker Desktop is running
        pause
        exit /b 1
    )
    echo [Info] Waiting for Milvus to start (10 seconds)...
    timeout /t 10 /nobreak >nul
)
echo [Success] Milvus database ready
echo.

REM Start CLS MCP service
echo [5/6] Starting CLS MCP service...
start "CLS MCP Server" /min %PYTHON_CMD% mcp_servers/cls_server.py
timeout /t 2 /nobreak >nul
echo [Success] CLS MCP service started
echo.

REM Start Monitor MCP service
echo [6/6] Starting Monitor MCP service...
start "Monitor MCP Server" /min %PYTHON_CMD% mcp_servers/monitor_server.py
timeout /t 2 /nobreak >nul
echo [Success] Monitor MCP service started
echo.

REM Start FastAPI service
echo [7/8] Starting FastAPI service...
start "SuperBizAgent API" %PYTHON_CMD% -m uvicorn app.main:app --host 0.0.0.0 --port 9900
echo [Info] Waiting for service startup (15 seconds)...
timeout /t 15 /nobreak >nul
echo.

REM Check service status and upload documents
echo.
echo [Info] Checking service status...
curl -s http://localhost:9900/health >nul 2>&1
if errorlevel 1 (
    echo [Warning] Service may not be fully started yet, please wait a moment
) else (
    echo [Success] FastAPI service running normally
    echo.
    
    REM Call API to upload aiops-docs documents to vector database
    echo [8/8] Uploading documents to vector database...
    for %%f in (aiops-docs\*.md) do (
        echo   Uploading: %%~nxf
        curl -s -X POST http://localhost:9900/api/upload -F "file=@%%f" >nul 2>&1
    )
    echo [Success] Document upload completed
)

echo.
echo ====================================
echo Services startup completed!
echo ====================================
echo Web UI: http://localhost:9900
echo API Docs: http://localhost:9900/docs
echo.
echo View logs:
echo   - FastAPI: logs\app_*.log (Loguru logs, daily rotation)
echo   - CLS MCP: type mcp_cls.log
echo   - Monitor: type mcp_monitor.log
echo Stop services: stop-windows.bat
echo ====================================
pause