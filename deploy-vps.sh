#!/usr/bin/env bash
# ============================================================
#  Grok2API VPS 一键部署脚本
#  适用于 Debian 12 / Ubuntu 22+ (已安装 Docker)
#
#  用法:
#    curl -fsSL https://raw.githubusercontent.com/iT1000s/grok2api/main/deploy-vps.sh | bash
#    或:
#    bash deploy-vps.sh
#
#  可通过环境变量自定义:
#    BUILD_LOCAL=1            本地构建镜像（默认，避免拉取慢）
#    BUILD_LOCAL=0            从 ghcr.io 拉取预构建镜像
#    GROK2API_PORT=8000       服务端口
#    ADMIN_USER=admin         管理后台用户名
#    ADMIN_PASS=<random>      管理后台密码
#    API_KEY=<random>         API 密钥
#    DEPLOY_DIR=/opt/grok2api 部署目录
# ============================================================

set -euo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- 参数默认值 ----
DEPLOY_DIR="${DEPLOY_DIR:-/opt/grok2api}"
GROK2API_PORT="${GROK2API_PORT:-8000}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 12 | tr -d '/+=')}"
API_KEY="${API_KEY:-sk-$(openssl rand -hex 16)}"
BUILD_LOCAL="${BUILD_LOCAL:-1}"
GROK2API_REPO="https://github.com/iT1000s/grok2api.git"

# ---- 前置检查 ----
check_prereqs() {
    info "检查前置条件..."

    if ! command -v docker &>/dev/null; then
        err "未找到 Docker，请先安装:"
        err "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi

    # 检查 docker compose (v2)
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        err "未找到 Docker Compose，请安装 Docker Compose V2"
        exit 1
    fi

    # 本地构建模式需要 git
    if [ "$BUILD_LOCAL" = "1" ] && ! command -v git &>/dev/null; then
        warn "本地构建模式需要 git，正在安装..."
        apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1 || true
    fi

    info "Docker: $(docker --version | head -1)"
    info "Compose: $($COMPOSE_CMD version 2>/dev/null | head -1)"
    [ "$BUILD_LOCAL" = "1" ] && info "模式: 本地构建" || info "模式: 拉取镜像"
}

# ---- 创建部署目录 ----
setup_dirs() {
    info "创建部署目录: ${DEPLOY_DIR}"
    mkdir -p "${DEPLOY_DIR}"/{data,logs}
    cd "${DEPLOY_DIR}"
}

# ---- Clone 仓库（本地构建模式）----
clone_repo() {
    if [ "$BUILD_LOCAL" != "1" ]; then
        return
    fi

    local repo_dir="${DEPLOY_DIR}/repo"
    if [ -d "${repo_dir}/.git" ]; then
        info "更新仓库代码..."
        git -C "${repo_dir}" pull --quiet 2>/dev/null || true
    else
        info "克隆仓库: ${GROK2API_REPO}"
        git clone --depth 1 "${GROK2API_REPO}" "${repo_dir}"
    fi
}

# ---- 生成 .env ----
generate_env() {
    info "生成 .env 配置..."
    cat > "${DEPLOY_DIR}/.env" <<EOF
# Grok2API VPS 部署配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# 服务端口
GROK2API_PORT=${GROK2API_PORT}
SERVER_PORT=${GROK2API_PORT}

# 时区
TZ=Asia/Shanghai

# 日志级别 (DEBUG / INFO / WARNING)
LOG_LEVEL=INFO

# 存储类型 (local / redis / pgsql / mysql)
SERVER_STORAGE_TYPE=local
EOF
    info "  .env 已生成"
}

# ---- 生成 docker-compose.yml ----
generate_compose() {
    info "生成 docker-compose.yml..."
    if [ "$BUILD_LOCAL" = "1" ]; then
        # 本地构建模式
        cat > "${DEPLOY_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  grok2api:
    container_name: grok2api
    build:
      context: ./repo
      dockerfile: Dockerfile
    image: grok2api:local
    ports:
      - "${GROK2API_PORT:-8000}:${SERVER_PORT:-8000}"
    environment:
      TZ: ${TZ:-Asia/Shanghai}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      SERVER_HOST: ${SERVER_HOST:-0.0.0.0}
      SERVER_PORT: ${SERVER_PORT:-8000}
      SERVER_WORKERS: ${SERVER_WORKERS:-1}
      SERVER_STORAGE_TYPE: ${SERVER_STORAGE_TYPE:-local}
      SERVER_STORAGE_URL: "${SERVER_STORAGE_URL:-}"
      STORAGE_WAIT_TIMEOUT: ${STORAGE_WAIT_TIMEOUT:-60}
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    shm_size: "1gb"
    init: true
    restart: unless-stopped
    depends_on:
      flaresolverr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import os,urllib.request; p=os.getenv('SERVER_PORT','8000'); urllib.request.urlopen(f'http://127.0.0.1:{p}/health', timeout=2).read();"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 40s

  flaresolverr:
    container_name: grok2api-flaresolverr
    image: ghcr.io/flaresolverr/flaresolverr:latest
    environment:
      TZ: ${TZ:-Asia/Shanghai}
      LOG_LEVEL: info
      LOG_HTML: "false"
      CAPTCHA_SOLVER: none
    ports:
      - "127.0.0.1:8191:8191"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8191/health"]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 20s
COMPOSE_EOF
    else
        # 拉取镜像模式
        cat > "${DEPLOY_DIR}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  grok2api:
    container_name: grok2api
    image: ${GROK2API_IMAGE:-ghcr.io/tqzhr/grok2api:latest}
    ports:
      - "${GROK2API_PORT:-8000}:${SERVER_PORT:-8000}"
    environment:
      TZ: ${TZ:-Asia/Shanghai}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      SERVER_HOST: ${SERVER_HOST:-0.0.0.0}
      SERVER_PORT: ${SERVER_PORT:-8000}
      SERVER_WORKERS: ${SERVER_WORKERS:-1}
      SERVER_STORAGE_TYPE: ${SERVER_STORAGE_TYPE:-local}
      SERVER_STORAGE_URL: "${SERVER_STORAGE_URL:-}"
      STORAGE_WAIT_TIMEOUT: ${STORAGE_WAIT_TIMEOUT:-60}
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    shm_size: "1gb"
    init: true
    restart: unless-stopped
    depends_on:
      flaresolverr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import os,urllib.request; p=os.getenv('SERVER_PORT','8000'); urllib.request.urlopen(f'http://127.0.0.1:{p}/health', timeout=2).read();"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 40s

  flaresolverr:
    container_name: grok2api-flaresolverr
    image: ghcr.io/flaresolverr/flaresolverr:latest
    environment:
      TZ: ${TZ:-Asia/Shanghai}
      LOG_LEVEL: info
      LOG_HTML: "false"
      CAPTCHA_SOLVER: none
    ports:
      - "127.0.0.1:8191:8191"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8191/health"]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 20s
COMPOSE_EOF
    fi
    info "  docker-compose.yml 已生成"
}

# ---- 生成初始配置 ----
generate_config() {
    if [ -f "${DEPLOY_DIR}/data/config.toml" ]; then
        warn "config.toml 已存在，跳过生成（保留现有配置）"
        return
    fi

    info "生成初始 config.toml..."
    cat > "${DEPLOY_DIR}/data/config.toml" <<EOF
[grok]
temporary = true
stream = true
thinking = true
dynamic_statsig = true
filter_tags = ["xaiartifact","xai:tool_usage_card","grok:render"]
timeout = 120
base_proxy_url = ""
asset_proxy_url = ""
cf_clearance = ""
max_retry = 3
retry_status_codes = [401,429,403]
image_generation_method = "legacy"

[app]
app_url = "http://0.0.0.0:${GROK2API_PORT}"
admin_username = "${ADMIN_USER}"
app_key = "${ADMIN_PASS}"
api_key = "${API_KEY}"
image_format = "url"
video_format = "url"

[token]
auto_refresh = true
refresh_interval_hours = 8
fail_threshold = 5
nsfw_refresh_concurrency = 10
nsfw_refresh_retries = 3

[cache]
enable_auto_clean = true
limit_mb = 1024

[performance]
assets_max_concurrent = 25
media_max_concurrent = 50

[register]
worker_domain = ""
email_domain = ""
admin_password = ""
yescaptcha_key = ""
solver_url = "http://127.0.0.1:5072"
solver_browser_type = "camoufox"
solver_threads = 5
register_threads = 10
default_count = 100
auto_start_solver = true

[cf_refresh]
# FlareSolverr 地址（Docker Compose 内通过服务名互通）
flaresolverr_url = "http://flaresolverr:8191"
# 刷新超时（秒）
timeout = 60
# 自动刷新间隔（秒），0 为禁用
auto_refresh_interval = 3600
EOF
    info "  config.toml 已生成"
}

# ---- 构建/拉取镜像并启动 ----
deploy() {
    cd "${DEPLOY_DIR}"

    if [ "$BUILD_LOCAL" = "1" ]; then
        info "本地构建 grok2api 镜像（首次可能需要几分钟）..."
        $COMPOSE_CMD build --no-cache grok2api
        # FlareSolverr 仍需拉取
        info "拉取 FlareSolverr 镜像..."
        $COMPOSE_CMD pull flaresolverr
    else
        info "拉取最新镜像..."
        $COMPOSE_CMD pull
    fi

    info "启动服务..."
    $COMPOSE_CMD up -d

    info "等待服务启动..."
    sleep 10

    # 检查健康状态
    local retries=0
    local max_retries=12
    while [ $retries -lt $max_retries ]; do
        if curl -sf "http://127.0.0.1:${GROK2API_PORT}/health" >/dev/null 2>&1; then
            info "✅ 服务已就绪!"
            break
        fi
        retries=$((retries + 1))
        if [ $retries -ge $max_retries ]; then
            warn "服务启动超时，请检查日志: $COMPOSE_CMD logs"
            $COMPOSE_CMD ps
            return 1
        fi
        sleep 5
    done
}

# ---- 打印信息 ----
print_info() {
    local public_ip
    public_ip=$(curl -sf https://api.ipify.org 2>/dev/null || echo "<YOUR_VPS_IP>")

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  Grok2API 部署完成!${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  部署目录:    ${DEPLOY_DIR}"
    echo -e "  管理面板:    ${GREEN}http://${public_ip}:${GROK2API_PORT}/login${NC}"
    echo -e "  API 地址:    ${GREEN}http://${public_ip}:${GROK2API_PORT}/v1${NC}"
    echo ""
    echo -e "  管理账号:    ${YELLOW}${ADMIN_USER}${NC}"
    echo -e "  管理密码:    ${YELLOW}${ADMIN_PASS}${NC}"
    echo -e "  API Key:     ${YELLOW}${API_KEY}${NC}"
    echo ""
    echo -e "  FlareSolverr: http://127.0.0.1:8191 (仅本机访问)"
    echo ""
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "  常用命令:"
    echo -e "    查看状态:  cd ${DEPLOY_DIR} && $COMPOSE_CMD ps"
    echo -e "    查看日志:  cd ${DEPLOY_DIR} && $COMPOSE_CMD logs -f"
    echo -e "    重启服务:  cd ${DEPLOY_DIR} && $COMPOSE_CMD restart"
    echo -e "    停止服务:  cd ${DEPLOY_DIR} && $COMPOSE_CMD down"
    if [ "$BUILD_LOCAL" = "1" ]; then
        echo -e "    更新版本:  cd ${DEPLOY_DIR} && git -C repo pull && $COMPOSE_CMD build grok2api && $COMPOSE_CMD up -d"
    else
        echo -e "    更新版本:  cd ${DEPLOY_DIR} && $COMPOSE_CMD pull && $COMPOSE_CMD up -d"
    fi
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠️ 请将以上凭据保存到安全位置!${NC}"
    echo -e "  ${YELLOW}⚠️ 如果在 1Panel 中操作，请在防火墙中放行端口 ${GROK2API_PORT}${NC}"
    echo ""

    # 保存凭据到文件
    cat > "${DEPLOY_DIR}/.credentials" <<EOF
# Grok2API 凭据 (请妥善保管)
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
API_KEY=${API_KEY}
PANEL_URL=http://${public_ip}:${GROK2API_PORT}/login
API_URL=http://${public_ip}:${GROK2API_PORT}/v1
EOF
    chmod 600 "${DEPLOY_DIR}/.credentials"
    info "凭据已保存到 ${DEPLOY_DIR}/.credentials"
}

# ---- 主流程 ----
main() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  Grok2API VPS 一键部署${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    check_prereqs
    setup_dirs
    clone_repo
    generate_env
    generate_compose
    generate_config
    deploy
    print_info
}

main "$@"
