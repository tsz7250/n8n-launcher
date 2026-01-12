@echo off
setlocal enabledelayedexpansion

:: ================================================
:: n8n.bat — 本地 n8n 服務 管理腳本
:: ================================================

:: 視窗標題與配色
title n8n 本地 服務 管理 介面
color 07

:: 工作目錄（可自行調整）
set "WORKDIR=%USERPROFILE%\n8n"

:: ==================================================================
:: 1. 環境與 Docker 檢查
:: ==================================================================
echo [檢查] 正在檢查 Docker 服務狀態...
docker info >nul 2>&1
if %errorlevel% equ 0 (
    echo [成功] Docker 已在運作中。
) else (
    echo [提示] Docker 尚未啟動，正在嘗試啟動 Docker Desktop...
    docker --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo [錯誤] 未偵測到 Docker Desktop，即將開啟下載頁面...
        start "" "https://desktop.docker.com/win/main/amd64/Docker%%20Desktop%%20Installer.exe?utm_source=docker&utm_medium=webreferral&utm_campaign=dd-smartbutton&utm_location=module"
        pause
        goto END
    )
    start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
    echo 正在初始化 Docker Desktop，請稍候...
    timeout /t 5 >nul
    set "MAX_RETRIES=3"
    set "RETRY_COUNT=0"
    :wait_docker
    docker info >nul 2>&1
    if errorlevel 1 (
        set /a RETRY_COUNT+=1
        if !RETRY_COUNT! GEQ !MAX_RETRIES! (
            echo [錯誤] Docker Desktop 啟動失敗，請手動開啟並確認其正常運作。
            pause
            goto END
        )
        echo Docker 尚未就緒，等待 3 秒後重試（第 !RETRY_COUNT! 次）...
        timeout /t 3 >nul
        goto wait_docker
    )
    echo [成功] Docker 已成功啟動！
)

:: ==================================================================
:: 2. 初始化與首次啟動
:: ==================================================================
if not exist "%WORKDIR%" (
    echo 建立工作目錄：%WORKDIR%
    mkdir "%WORKDIR%"
)
cd /d "%WORKDIR%"
call :create_compose_if_needed

:: 檢查服務是否已在運行
echo.
echo [檢查] 正在檢查 n8n 服務狀態...
curl -s --fail http://localhost:5678 >nul 2>&1
if %errorlevel% equ 0 (
    echo [提示] n8n 服務已在運行中。
    echo [提示] 可透過選單進行管理操作。
) else (
    echo [提示] n8n 服務尚未啟動，正在啟動服務...
    call :start_and_check_service
)

:: ==================================================================
:: 3. 互動式控制（主選單，輸入後需按 Enter）
:: ==================================================================
:MAIN_MENU
cls
echo ┌───────────────────────────────────┐
echo │        n8n 本地服務 管理工具      │
echo ├───────────────────────────────────┤
echo │ 1. 啟動服務                       │
echo │ 2. 關閉服務                       │
echo │ 3. 安裝指定版本                   │
echo │ 4. 重新安裝                       │
echo │ 5. 手動備份                       │
echo │ 6. 還原備份                       │
echo │ 7. 更新至最新版本                 │
echo │ 0. 離開                           │
echo └───────────────────────────────────┘
set /p "cmd=請輸入操作 [0-7]: "
if not defined cmd goto MAIN_MENU

if "%cmd%"=="1" (
    goto ACT_ON
) else if "%cmd%"=="2" (
    goto ACT_OFF
) else if "%cmd%"=="3" (
    goto ACT_UPDATE_VERSION
) else if "%cmd%"=="4" (
    goto ACT_REINSTALL
) else if "%cmd%"=="5" (
    goto ACT_BACKUP
) else if "%cmd%"=="6" (
    goto ACT_RESTORE
) else if "%cmd%"=="7" (
    goto ACT_UPDATE_LATEST
) else if "%cmd%"=="0" (
    goto ACT_EXIT
) else (
    echo.
    echo 無效選項，請重新輸入並按 Enter…
    pause >nul
    goto MAIN_MENU
)

:ACT_ON
    call :start_and_check_service
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_OFF
    echo [操作] 關閉服務中…
    docker compose down
    echo [完成] 服務已關閉。
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_UPDATE_LATEST
    echo [操作] 更新服務…
    echo [步驟1] 拉取最新映像…
    docker compose pull
    echo [步驟2] 停止舊版本服務…
    docker compose down
    echo [步驟3] 啟動新版本服務…
    call :start_and_check_service
    echo [完成] 更新並重啟。
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_REINSTALL
    echo [警告] 重新安裝將刪除所有 n8n 工作流程、憑證和資料庫！
    set /p "yn=是否要先備份？ (Y/N)，輸入後請按 Enter: "
    set "yn=!yn:~0,1!"
    if /I "!yn!"=="Y" (
        call :do_backup
    ) else (
        set "BACKUP_PERFORMED=false"
    )

    echo --- 開始重置環境 ---
    docker compose down
    docker volume rm n8n_basic_data n8n_basic_postgres_data --force >nul 2>&1
    if exist "docker-compose.yml" del "docker-compose.yml"
    call :create_compose_if_needed
    docker compose up -d

    if "%BACKUP_PERFORMED%"=="true" (
        call :recover_backup
    )

    call :check_service_status
    echo [完成] 重新安裝完成。
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_RESTORE
    set /p "RESTORE_DIR=請輸入備份目錄名稱 (如 backup_YYYYMMDD-HHMMSS)，輸入後請按 Enter: "
    if not defined RESTORE_DIR (
        echo 目錄名稱不可為空，請重試。
        pause >nul
        goto ACT_RESTORE
    )
    call :do_restore "%RESTORE_DIR%"
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_BACKUP
    call :do_backup
    if "%BACKUP_PERFORMED%"=="true" (
        echo.
        echo [資訊] 備份路徑：%CD%\!BACKUP_DIR!
    )
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_UPDATE_VERSION
    echo [操作] 指定版本更新服務…
    echo.
    echo [提示] 請輸入語義化版本號（純數字格式，如 2.2.3, 1.123.9, 2.3.1）
    :INPUT_VERSION
    set /p "VERSION=請輸入版本號，輸入後請按 Enter: "
    if not defined VERSION (
        echo 版本號不可為空，請重試。
        goto INPUT_VERSION
    )
    call :validate_version "%VERSION%"
    if %errorlevel% neq 0 (
        echo [錯誤] 版本號格式不正確！
        echo [提示] 請輸入語義化版本號（純數字格式，如 2.2.3, 1.123.9）
        goto INPUT_VERSION
    )
    echo [確認] 將更新至版本：%VERSION%
    echo [步驟1] 更新 docker-compose.yml 中的映像標籤…
    call :update_compose_image "%VERSION%"
    if %errorlevel% neq 0 (
        echo [錯誤] 更新 docker-compose.yml 失敗！
        echo.
        echo 按任意鍵返回主選單...
        pause >nul
        goto MAIN_MENU
    )
    echo [步驟2] 拉取指定版本映像…
    docker compose pull
    if %errorlevel% neq 0 (
        echo [錯誤] 拉取映像失敗！請確認版本號是否正確。
        echo.
        echo 按任意鍵返回主選單...
        pause >nul
        goto MAIN_MENU
    )
    echo [步驟3] 停止舊版本服務…
    docker compose down
    echo [步驟4] 啟動新版本服務…
    call :start_and_check_service
    echo [完成] 已更新至版本 %VERSION% 並重啟。
    echo.
    echo 按任意鍵返回主選單...
    pause >nul
    goto MAIN_MENU

:ACT_EXIT
    echo [操作] 程式結束前，先檢查並關閉服務（如有啟動）...
    docker compose down >nul 2>&1
    echo [完成] 服務已關閉！
    echo [操作] 程式結束。
    goto END

:: ==================================================================
:: 4. 子程序區
:: ==================================================================

:start_and_check_service
    echo.
    echo [操作] 啟動 n8n 服務…
    
    :: 檢查服務是否已在運行
    curl -s --fail http://localhost:5678 >nul 2>&1
    if %errorlevel% equ 0 (
        echo [提示] n8n 服務已在運行中，無需重複啟動。
        echo [提示] 您可以直接訪問：http://localhost:5678
        exit /b
    )
    
    docker compose up -d
    call :check_service_status
    exit /b

:check_service_status
    echo.
    echo [檢查] 輪詢 n8n 服務狀態 (最多60秒)…
    set "MAX_ATTEMPTS=20"
    set "ATTEMPT=0"
    :wait_service
    set /a ATTEMPT+=1
    curl -s --fail http://localhost:5678 >nul 2>&1
    if %errorlevel% equ 0 (
        echo [成功] n8n 已就緒！正在開啟瀏覽器…
        start http://localhost:5678
        exit /b
    )
    if !ATTEMPT! GEQ !MAX_ATTEMPTS! (
        echo [警告] 偵測超時，請手動檢查 http://localhost:5678
        exit /b
    )
    timeout /t 3 >nul
    goto wait_service

:create_compose_if_needed
    if not exist "docker-compose.yml" (
        echo [檢查] 未找到 docker-compose.yml，正在建立...
        (
        echo # n8n local docker - enhanced basic version
        echo services:
        echo.  postgres:
        echo.    image: postgres:15.3-alpine
        echo.    restart: always
        echo.    ports:
        echo.      - "${POSTGRES_PORT:-5432}:5432"
        echo.    environment:
        echo.      POSTGRES_USER: ${POSTGRES_USER:-n8n}
        echo.      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-n8npass}
        echo.      POSTGRES_DB: ${POSTGRES_DB:-n8n}
        echo.    volumes:
        echo.      - n8n_postgres_data:/var/lib/postgresql/data
        echo.    networks:
        echo.      - n8n_network
        echo.  n8n:
        echo.    image: n8nio/n8n:latest
        echo.    restart: unless-stopped
        echo.    ports:
        echo.      - "${N8N_PORT:-5678}:5678"
        echo.    environment:
        echo.      - N8N_ENCRYPTION_KEY=a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
        echo.      - N8N_SECURE_COOKIE=false
        echo.      - NODE_TLS_REJECT_UNAUTHORIZED=0
        echo.      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
        echo.      - DB_TYPE=postgresdb
        echo.      - DB_POSTGRESDB_HOST=postgres
        echo.      - DB_POSTGRESDB_PORT=${POSTGRES_PORT:-5432}
        echo.      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n}
        echo.      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n}
        echo.      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
        echo.      - N8N_BASIC_AUTH_ACTIVE=true
        echo.      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER:-admin}
        echo.      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
        echo.      - N8N_RUNNERS_ENABLED=true
        echo.      - N8N_HOST=${N8N_HOST:-localhost}
        echo.      - N8N_PORT=${N8N_PORT:-5678}
        echo.      - WEBHOOK_URL=${WEBHOOK_URL:-http://localhost:5678}
        echo.      - GENERIC_TIMEZONE=Asia/Taipei
        echo.      - TZ=Asia/Taipei
        echo.    volumes:
        echo.      - n8n_data:/root/.n8n
        echo.    networks:
        echo.      - n8n_network
        echo.    depends_on:
        echo.      - postgres
        echo.    user: "root"
        echo networks:
        echo.  n8n_network:
        echo.    driver: bridge
        echo volumes:
        echo.  n8n_postgres_data:
        echo.    name: n8n_basic_postgres_data
        echo.  n8n_data:
        echo.    name: n8n_basic_data
        ) > docker-compose.yml
    )
    exit /b

:recover_backup
    echo --- 開始還原備份 ---
    docker compose stop >nul
    docker run --rm -v n8n_basic_data:/data -v "%CD%\!BACKUP_DIR!:/backup" alpine ^
        sh -c "tar xzf /backup/n8n_data.tar.gz -C /data" >nul
    docker run --rm -v n8n_basic_postgres_data:/data -v "%CD%\!BACKUP_DIR!:/backup" alpine ^
        sh -c "tar xzf /backup/n8n_postgres_data.tar.gz -C /data" >nul
    docker compose start >nul
    echo [完成] 還原完成。
    exit /b

:do_backup
    echo [操作] 開始備份...
    docker volume inspect n8n_basic_data >nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [提示] 找不到資料卷，將以全新安裝方式繼續。
        set "BACKUP_PERFORMED=false"
        exit /b
    )
    echo [操作] 正在拉取備份工具 (alpine)...
    docker pull alpine >nul
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /format:list') do set "dt=%%I"
    set "TIMESTAMP=!dt:~0,4!!dt:~4,2!!dt:~6,2!-!dt:~8,2!!dt:~10,2!!dt:~12,2!"
    set "BACKUP_DIR=backup_!TIMESTAMP!"
    mkdir "!BACKUP_DIR!"
    echo [操作] 備份 n8n 資料卷…
    docker run --rm -v n8n_basic_data:/data -v "%CD%\!BACKUP_DIR!:/backup" alpine ^
        tar czf /backup/n8n_data.tar.gz -C /data . >nul
    echo [操作] 備份 PostgreSQL 資料卷…
    docker run --rm -v n8n_basic_postgres_data:/data -v "%CD%\!BACKUP_DIR!:/backup" alpine ^
        tar czf /backup/n8n_postgres_data.tar.gz -C /data . >nul
    echo [完成] 備份完成：!BACKUP_DIR!
    echo [資訊] 備份路徑：%CD%\!BACKUP_DIR!
    set "BACKUP_PERFORMED=true"
    exit /b

:do_restore
    set "RESTORE_DIR=%~1"
    echo --- 開始還原備份資料： %RESTORE_DIR% ---
    docker compose down
    docker volume create n8n_basic_data >nul 2>&1
    docker volume create n8n_basic_postgres_data >nul 2>&1
    echo 正在還原 n8n 工作流程與設定...
    docker run --rm -v n8n_basic_data:/data -v "%CD%\%RESTORE_DIR%:/backup" alpine ^
        sh -c "tar xzf /backup/n8n_data.tar.gz -C /data"
    echo 正在還原 PostgreSQL 資料庫...
    docker run --rm -v n8n_basic_postgres_data:/data -v "%CD%\%RESTORE_DIR%:/backup" alpine ^
        sh -c "tar xzf /backup/n8n_postgres_data.tar.gz -C /data"
    echo [完成] 還原完成。
    docker compose up -d
    call :check_service_status
    exit /b

:validate_version
    set "VERSION=%~1"
    :: 使用 PowerShell 驗證語義化版本號格式（純數字：主.次.修訂）
    powershell -NoProfile -Command "if ('%VERSION%' -match '^\d+\.\d+\.\d+$') { exit 0 } else { exit 1 }" >nul 2>&1
    if %errorlevel% equ 0 exit /b 0
    :: 格式不符合
    exit /b 1

:update_compose_image
    set "VERSION=%~1"
    if not exist "docker-compose.yml" (
        echo [錯誤] 找不到 docker-compose.yml 檔案！
        exit /b 1
    )
    :: 使用 PowerShell 來替換映像標籤（保留檔案格式）
    powershell -NoProfile -Command "$version = '%VERSION%'; $lines = Get-Content 'docker-compose.yml'; $newLines = $lines | ForEach-Object { if ($_ -match '^\s+image:\s+n8nio/n8n:') { $_ -replace 'n8nio/n8n:[^\s]+', ('n8nio/n8n:' + $version) } else { $_ } }; $newLines | Set-Content 'docker-compose.yml'"
    if %errorlevel% neq 0 (
        echo [錯誤] 無法更新 docker-compose.yml！
        exit /b 1
    )
    exit /b 0

:END
endlocal
pause