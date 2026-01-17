#!/bin/bash

# ================================================
# n8n.sh — 本地 n8n 服務 管理腳本 (Mac版本)
# ================================================

# 顏色定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 工作目錄
WORKDIR="$HOME/n8n"

# 全局變數
BACKUP_PERFORMED="false"
BACKUP_DIR=""

# ==================================================================
# 輔助函數
# ==================================================================

# 暫停函數
pause() {
    read -n 1 -s -r -p "按任意鍵繼續..."
    echo
}

# 清屏並顯示標題
show_header() {
    clear
    echo "${BLUE}========================================${NC}"
    echo "${BLUE}   n8n 本地服務 管理工具 (Mac版本)${NC}"
    echo "${BLUE}========================================${NC}"
    echo
}

# ==================================================================
# 1. 環境與 Docker 檢查
# ==================================================================

check_docker() {
    echo "${YELLOW}[檢查]${NC} 正在檢查 Docker 服務狀態..."

    if docker info >/dev/null 2>&1; then
        echo "${GREEN}[成功]${NC} Docker 已在運作中。"
        return 0
    else
        echo "${YELLOW}[提示]${NC} Docker 尚未啟動，正在嘗試啟動 Docker Desktop..."

        # 檢查Docker是否已安裝
        if ! command -v docker &> /dev/null; then
            echo
            echo "${RED}[錯誤]${NC} 未偵測到 Docker Desktop，即將開啟下載頁面..."

            # 檢測CPU架構
            ARCH=$(uname -m)
            if [[ "$ARCH" == "arm64" ]]; then
                DOCKER_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
                echo "${YELLOW}[資訊]${NC} 檢測到 Apple Silicon (M系列晶片)"
            else
                DOCKER_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
                echo "${YELLOW}[資訊]${NC} 檢測到 Intel 晶片"
            fi

            echo "${YELLOW}[資訊]${NC} 下載連結: $DOCKER_URL"
            open "$DOCKER_URL"
            pause
            exit 1
        fi

        # 啟動Docker Desktop
        if [ -d "/Applications/Docker.app" ]; then
            open -a Docker
            echo "正在初始化 Docker Desktop，請稍候..."
            sleep 5

            # 等待Docker啟動（最多3次重試）
            MAX_RETRIES=3
            RETRY_COUNT=0

            while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                if docker info >/dev/null 2>&1; then
                    echo "${GREEN}[成功]${NC} Docker 已成功啟動！"
                    return 0
                fi

                RETRY_COUNT=$((RETRY_COUNT + 1))
                echo "Docker 尚未就緒，等待 3 秒後重試（第 $RETRY_COUNT 次）..."
                sleep 3
            done

            echo "${RED}[錯誤]${NC} Docker Desktop 啟動失敗，請手動開啟並確認其正常運作。"
            pause
            exit 1
        else
            echo "${RED}[錯誤]${NC} 找不到 Docker Desktop 應用程式。"
            pause
            exit 1
        fi
    fi
}

# ==================================================================
# 2. 創建 docker-compose.yml
# ==================================================================

create_compose_if_needed() {
    if [ ! -f "$WORKDIR/docker-compose.yml" ]; then
        echo "${YELLOW}[檢查]${NC} 未找到 docker-compose.yml，正在建立..."

        cat > "$WORKDIR/docker-compose.yml" << 'EOF'
# n8n local docker - enhanced basic version
services:
  postgres:
    image: postgres:15.3-alpine
    restart: always
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-n8n}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB:-n8n}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_network
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "${N8N_PORT:-5678}:5678"
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_SECURE_COOKIE=false
      - NODE_TLS_REJECT_UNAUTHORIZED=0
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=${POSTGRES_PORT:-5432}
      - NODE_FUNCTION_ALLOW_BUILTIN=fs,path
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_RUNNERS_ENABLED=true
      - N8N_HOST=${N8N_HOST:-localhost}
      - N8N_PORT=${N8N_PORT:-5678}
      - WEBHOOK_URL=${WEBHOOK_URL:-http://localhost:5678}
      - GENERIC_TIMEZONE=Asia/Taipei
      - TZ=Asia/Taipei      
      # v2.0更新:以下為可存取的路徑
      - N8N_RESTRICT_FILE_ACCESS_TO=/files;/backups;/download_data

    volumes:
      - n8n_data:/root/.n8n
    networks:
      - n8n_network
    depends_on:
      - postgres
    user: "root"
networks:
  n8n_network:
    driver: bridge
volumes:
  n8n_postgres_data:
    name: n8n_basic_postgres_data
  n8n_data:
    name: n8n_basic_data
EOF
        echo "${GREEN}[完成]${NC} docker-compose.yml 已建立。"
    fi
}

# ==================================================================
# 3. 服務管理函數
# ==================================================================

start_and_check_service() {
    echo
    echo "${YELLOW}[操作]${NC} 啟動 n8n 服務…"

    # 檢查服務是否已在運行
    if curl -s --fail http://localhost:5678 >/dev/null 2>&1; then
        echo "${YELLOW}[提示]${NC} n8n 服務已在運行中，無需重複啟動。"
        echo "${YELLOW}[提示]${NC} 您可以直接訪問：http://localhost:5678"
        return 0
    fi

    cd "$WORKDIR" || exit 1
    docker compose up -d
    check_service_status
}

check_service_status() {
    echo
    echo "${YELLOW}[檢查]${NC} 輪詢 n8n 服務狀態 (最多60秒)…"

    MAX_ATTEMPTS=20
    ATTEMPT=0

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))

        if curl -s --fail http://localhost:5678 >/dev/null 2>&1; then
            echo "${GREEN}[成功]${NC} n8n 已就緒！正在開啟瀏覽器…"
            open http://localhost:5678
            return 0
        fi

        sleep 3
    done

    echo "${YELLOW}[警告]${NC} 偵測超時，請手動檢查 http://localhost:5678"
}

# ==================================================================
# 4. 備份與還原函數
# ==================================================================

do_backup() {
    echo "${YELLOW}[操作]${NC} 開始備份..."

    # 檢查資料卷是否存在
    if ! docker volume inspect n8n_basic_data >/dev/null 2>&1; then
        echo "${YELLOW}[提示]${NC} 找不到資料卷，將以全新安裝方式繼續。"
        BACKUP_PERFORMED="false"
        return 1
    fi

    echo "${YELLOW}[操作]${NC} 正在拉取備份工具 (alpine)..."
    docker pull alpine >/dev/null 2>&1

    # 生成時間戳
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    BACKUP_DIR="backup_${TIMESTAMP}"

    mkdir -p "$WORKDIR/$BACKUP_DIR"

    echo "${YELLOW}[操作]${NC} 備份 n8n 資料卷…"
    docker run --rm -v n8n_basic_data:/data -v "$WORKDIR/$BACKUP_DIR:/backup" alpine \
        tar czf /backup/n8n_data.tar.gz -C /data . >/dev/null 2>&1

    echo "${YELLOW}[操作]${NC} 備份 PostgreSQL 資料卷…"
    docker run --rm -v n8n_basic_postgres_data:/data -v "$WORKDIR/$BACKUP_DIR:/backup" alpine \
        tar czf /backup/n8n_postgres_data.tar.gz -C /data . >/dev/null 2>&1

    echo "${GREEN}[完成]${NC} 備份完成：$BACKUP_DIR"
    echo "${YELLOW}[資訊]${NC} 備份路徑：$WORKDIR/$BACKUP_DIR"
    BACKUP_PERFORMED="true"
}

do_restore() {
    local RESTORE_DIR="$1"

    echo "--- 開始還原備份資料： $RESTORE_DIR ---"

    cd "$WORKDIR" || exit 1
    docker compose down

    # 創建資料卷
    docker volume create n8n_basic_data >/dev/null 2>&1
    docker volume create n8n_basic_postgres_data >/dev/null 2>&1

    echo "正在還原 n8n 工作流程與設定..."
    docker run --rm -v n8n_basic_data:/data -v "$WORKDIR/$RESTORE_DIR:/backup" alpine \
        sh -c "tar xzf /backup/n8n_data.tar.gz -C /data"

    echo "正在還原 PostgreSQL 資料庫..."
    docker run --rm -v n8n_basic_postgres_data:/data -v "$WORKDIR/$RESTORE_DIR:/backup" alpine \
        sh -c "tar xzf /backup/n8n_postgres_data.tar.gz -C /data"

    echo "${GREEN}[完成]${NC} 還原完成。"

    docker compose up -d
    check_service_status
}

recover_backup() {
    echo "--- 開始還原備份 ---"
    cd "$WORKDIR" || exit 1
    docker compose stop >/dev/null 2>&1

    docker run --rm -v n8n_basic_data:/data -v "$WORKDIR/$BACKUP_DIR:/backup" alpine \
        sh -c "tar xzf /backup/n8n_data.tar.gz -C /data" >/dev/null 2>&1

    docker run --rm -v n8n_basic_postgres_data:/data -v "$WORKDIR/$BACKUP_DIR:/backup" alpine \
        sh -c "tar xzf /backup/n8n_postgres_data.tar.gz -C /data" >/dev/null 2>&1

    docker compose start >/dev/null 2>&1
    echo "${GREEN}[完成]${NC} 還原完成。"
}

# ==================================================================
# 5. 版本管理函數
# ==================================================================

validate_version() {
    local VERSION="$1"
    if [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

update_compose_image() {
    local VERSION="$1"

    if [ ! -f "$WORKDIR/docker-compose.yml" ]; then
        echo "${RED}[錯誤]${NC} 找不到 docker-compose.yml 檔案！"
        return 1
    fi

    # Mac的sed需要特殊語法
    sed -i '' "s|image: n8nio/n8n:.*|image: n8nio/n8n:${VERSION}|g" "$WORKDIR/docker-compose.yml"

    if [ $? -ne 0 ]; then
        echo "${RED}[錯誤]${NC} 無法更新 docker-compose.yml！"
        return 1
    fi

    return 0
}

# ==================================================================
# 6. 主選單
# ==================================================================

show_menu() {
    show_header
    echo "┌───────────────────────────────────┐"
    echo "│        n8n 本地服務 管理工具      │"
    echo "├───────────────────────────────────┤"
    echo "│ 1. 啟動服務                       │"
    echo "│ 2. 關閉服務                       │"
    echo "│ 3. 安裝指定版本                   │"
    echo "│ 4. 重新安裝                       │"
    echo "│ 5. 手動備份                       │"
    echo "│ 6. 還原備份                       │"
    echo "│ 7. 更新至最新版本                 │"
    echo "│ 0. 離開                           │"
    echo "└───────────────────────────────────┘"
    echo
}

# ==================================================================
# 7. 操作處理函數
# ==================================================================

action_start() {
    start_and_check_service
    echo
    pause
}

action_stop() {
    echo "${YELLOW}[操作]${NC} 關閉服務中…"
    cd "$WORKDIR" || exit 1
    docker compose down
    echo "${GREEN}[完成]${NC} 服務已關閉。"
    echo
    pause
}

action_update_latest() {
    echo "${YELLOW}[操作]${NC} 更新服務…"
    echo "${YELLOW}[步驟1]${NC} 拉取最新映像…"
    cd "$WORKDIR" || exit 1
    docker compose pull

    echo "${YELLOW}[步驟2]${NC} 停止舊版本服務…"
    docker compose down

    echo "${YELLOW}[步驟3]${NC} 啟動新版本服務…"
    start_and_check_service

    echo "${GREEN}[完成]${NC} 更新並重啟。"
    echo
    pause
}

action_reinstall() {
    echo "${RED}[警告]${NC} 重新安裝將刪除所有 n8n 工作流程、憑證和資料庫！"
    read -p "是否要先備份？ (Y/N): " yn

    if [[ "$yn" =~ ^[Yy]$ ]]; then
        do_backup
    else
        BACKUP_PERFORMED="false"
    fi

    echo "--- 開始重置環境 ---"
    cd "$WORKDIR" || exit 1
    docker compose down
    docker volume rm n8n_basic_data n8n_basic_postgres_data --force >/dev/null 2>&1

    if [ -f "$WORKDIR/docker-compose.yml" ]; then
        rm "$WORKDIR/docker-compose.yml"
    fi

    create_compose_if_needed
    docker compose up -d

    if [ "$BACKUP_PERFORMED" = "true" ]; then
        recover_backup
    fi

    check_service_status
    echo "${GREEN}[完成]${NC} 重新安裝完成。"
    echo
    pause
}

action_backup() {
    do_backup
    if [ "$BACKUP_PERFORMED" = "true" ]; then
        echo
        echo "${YELLOW}[資訊]${NC} 備份路徑：$WORKDIR/$BACKUP_DIR"
    fi
    echo
    pause
}

action_restore() {
    read -p "請輸入備份目錄名稱 (如 backup_YYYYMMDD-HHMMSS): " RESTORE_DIR

    if [ -z "$RESTORE_DIR" ]; then
        echo "目錄名稱不可為空，請重試。"
        pause
        return
    fi

    if [ ! -d "$WORKDIR/$RESTORE_DIR" ]; then
        echo "${RED}[錯誤]${NC} 找不到備份目錄：$RESTORE_DIR"
        pause
        return
    fi

    do_restore "$RESTORE_DIR"
    echo
    pause
}

action_update_version() {
    echo "${YELLOW}[操作]${NC} 指定版本更新服務…"
    echo
    echo "${YELLOW}[提示]${NC} 請輸入語義化版本號（純數字格式，如 2.2.3, 1.123.9, 2.3.1）"

    while true; do
        read -p "請輸入版本號: " VERSION

        if [ -z "$VERSION" ]; then
            echo "版本號不可為空，請重試。"
            continue
        fi

        if ! validate_version "$VERSION"; then
            echo "${RED}[錯誤]${NC} 版本號格式不正確！"
            echo "${YELLOW}[提示]${NC} 請輸入語義化版本號（純數字格式，如 2.2.3, 1.123.9）"
            continue
        fi

        break
    done

    echo "${YELLOW}[確認]${NC} 將更新至版本：$VERSION"
    echo "${YELLOW}[步驟1]${NC} 更新 docker-compose.yml 中的映像標籤…"

    if ! update_compose_image "$VERSION"; then
        echo "${RED}[錯誤]${NC} 更新 docker-compose.yml 失敗！"
        echo
        pause
        return
    fi

    echo "${YELLOW}[步驟2]${NC} 拉取指定版本映像…"
    cd "$WORKDIR" || exit 1

    if ! docker compose pull; then
        echo "${RED}[錯誤]${NC} 拉取映像失敗！請確認版本號是否正確。"
        echo
        pause
        return
    fi

    echo "${YELLOW}[步驟3]${NC} 停止舊版本服務…"
    docker compose down

    echo "${YELLOW}[步驟4]${NC} 啟動新版本服務…"
    start_and_check_service

    echo "${GREEN}[完成]${NC} 已更新至版本 $VERSION 並重啟。"
    echo
    pause
}

action_exit() {
    echo "${YELLOW}[操作]${NC} 程式結束前，先檢查並關閉服務（如有啟動）..."
    cd "$WORKDIR" || exit 1
    docker compose down >/dev/null 2>&1
    echo "${GREEN}[完成]${NC} 服務已關閉！"
    echo "${YELLOW}[操作]${NC} 程式結束。"
    exit 0
}

# ==================================================================
# 主程序
# ==================================================================

main() {
    # 檢查Docker
    check_docker

    # 創建工作目錄
    if [ ! -d "$WORKDIR" ]; then
        echo "建立工作目錄：$WORKDIR"
        mkdir -p "$WORKDIR"
    fi

    cd "$WORKDIR" || exit 1
    create_compose_if_needed

    # 檢查服務是否已在運行
    echo
    echo "${YELLOW}[檢查]${NC} 正在檢查 n8n 服務狀態..."
    if curl -s --fail http://localhost:5678 >/dev/null 2>&1; then
        echo "${YELLOW}[提示]${NC} n8n 服務已在運行中。"
        echo "${YELLOW}[提示]${NC} 可透過選單進行管理操作。"
    else
        echo "${YELLOW}[提示]${NC} n8n 服務尚未啟動，正在啟動服務..."
        start_and_check_service
    fi

    # 主循環
    while true; do
        show_menu
        read -p "請輸入操作 [0-7]: " cmd

        case $cmd in
            1)
                action_start
                ;;
            2)
                action_stop
                ;;
            3)
                action_update_version
                ;;
            4)
                action_reinstall
                ;;
            5)
                action_backup
                ;;
            6)
                action_restore
                ;;
            7)
                action_update_latest
                ;;
            0)
                action_exit
                ;;
            *)
                echo
                echo "無效選項，請重新輸入…"
                pause
                ;;
        esac
    done
}

# 執行主程序
main
