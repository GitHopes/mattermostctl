#!/usr/bin/env bash
# =============================================================================
#  install_mattermost.sh — Instalador automático de Mattermost desde fuente
#  Ubuntu 24.04 LTS
#
#  Uso:   sudo bash install_mattermost.sh
#
#  UI automática:
#    - Terminal interactiva + whiptail disponible → UI gráfica TUI (cuadros,
#      barras de progreso whiptail, diálogos de confirmación/contraseña)
#    - Cualquier otro caso                        → modo texto con barra ASCII
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Configuración ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/mattermost_install.log"
DB_PASSWORD="SECURE_PASSWORD"          # Se sobreescribe en welcome()
GO_VERSION="1.23.1"
NODE_VERSION="20.11.1"
NVM_VERSION="0.40.1"
TOTAL_STEPS=12
CURRENT_STEP=0

# ─── Detección de modo UI ─────────────────────────────────────────────────────
USE_WHIPTAIL=false
if command -v whiptail &>/dev/null && [[ -t 0 ]]; then
    USE_WHIPTAIL=true
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
info() { echo -e "${CYAN}➜ $*${RESET}";  log "INFO: $*"; }
ok()   { echo -e "${GREEN}✔ $*${RESET}"; log "OK:   $*"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; log "WARN: $*"; }
err()  { echo -e "${RED}✖ ERROR: $*${RESET}" >&2; log "ERR:  $*"; }

# ─── Manejo global de errores ─────────────────────────────────────────────────
on_error() {
    local code=$? line=$1
    err "Falló en línea $line (código $code)"
    err "Log completo: $LOG_FILE"
    if $USE_WHIPTAIL; then
        whiptail --title "❌ Error de instalación" \
            --msgbox "Error en línea $line (código $code).\n\nLog:\n$LOG_FILE" 12 65
    fi
    exit "$code"
}
trap 'on_error $LINENO' ERR

# ─── Barra de progreso texto ──────────────────────────────────────────────────
draw_progress() {
    local step=$1 total=$2 label=$3
    local width=46 filled=$(( 46 * step / total )) bar="" i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<width; i++)); do bar+="░"; done
    local pct=$(( 100 * step / total ))
    printf "\r${BOLD}${BLUE}[%s]${RESET} ${BOLD}%3d%%${RESET} %-35s" \
           "$bar" "$pct" "$label"
    [[ $step -eq $total ]] && echo ""
}

# ─── Gauge whiptail ───────────────────────────────────────────────────────────
WP_PIPE=""
start_gauge() {
    WP_PIPE=$(mktemp -u /tmp/mm_gauge_XXXXXX)
    mkfifo "$WP_PIPE"
    whiptail --title "🚀 Instalando Mattermost" \
             --gauge "Iniciando..." 8 72 0 < "$WP_PIPE" &
    exec 3>"$WP_PIPE"
}
update_gauge() { printf "XXX\n%d\n%s\nXXX\n" "$1" "$2" >&3; }
end_gauge()    { exec 3>&-; rm -f "$WP_PIPE"; wait 2>/dev/null || true; }

# ─── Avance de paso ───────────────────────────────────────────────────────────
advance() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    local pct=$(( 100 * CURRENT_STEP / TOTAL_STEPS ))
    local lbl="Paso $CURRENT_STEP/$TOTAL_STEPS: $1"
    if $USE_WHIPTAIL; then
        update_gauge "$pct" "$lbl"
    else
        echo ""; draw_progress "$CURRENT_STEP" "$TOTAL_STEPS" "$1"; echo ""
    fi
    log "── PASO $CURRENT_STEP: $1"
}

run() { "$@" >> "$LOG_FILE" 2>&1; }

# ─── Checks previos ───────────────────────────────────────────────────────────
preflight_checks() {
    info "Verificando requisitos previos..."
    [[ $(id -u) -eq 0 ]] || { err "Ejecuta: sudo bash $0"; exit 1; }
    local rel; rel=$(lsb_release -rs 2>/dev/null || echo "?")
    [[ "$rel" == "24.04" ]] || warn "Ubuntu $rel — recomendado 24.04"
    local ram_kb; ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    (( ram_kb >= 7000000 )) || warn "RAM: $((ram_kb/1024)) MB — recomendado ≥ 8 GB"
    local cpus; cpus=$(nproc)
    (( cpus >= 4 )) || warn "CPUs: $cpus — recomendado ≥ 4"
    local free_gb; free_gb=$(df /opt --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G')
    (( free_gb >= 20 )) || warn "Espacio libre en /opt: ${free_gb}GB — recomendado ≥ 20 GB"
    ok "Preflight OK — Ubuntu $rel | $((ram_kb/1024)) MB | ${cpus} CPUs | ${free_gb}GB"
}

# ─── Bienvenida ───────────────────────────────────────────────────────────────
welcome() {
    if $USE_WHIPTAIL; then
        whiptail --title "🚀 Instalador de Mattermost" --yesno \
"Instalará Mattermost desde código fuente en Ubuntu 24.04.

  DB      : PostgreSQL 17
  Backend : Go $GO_VERSION
  Frontend: Node.js $NODE_VERSION  (NVM $NVM_VERSION)
  Destino : /opt/mattermost
  Log     : $LOG_FILE

Duración estimada: 20-40 minutos.

¿Deseas continuar?" 18 65 || { echo "Cancelado."; exit 0; }

        local pass
        pass=$(whiptail --title "Contraseña DB" \
            --passwordbox \
"Contraseña para el usuario 'mmuser' de PostgreSQL.
(ENTER para usar 'SECURE_PASSWORD')" \
            10 65 3>&1 1>&2 2>&3) || pass=""
        [[ -n "$pass" ]] && DB_PASSWORD="$pass"
    else
        clear
        echo -e "${BOLD}${BLUE}"
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║   ███╗   ███╗ █████╗ ████████╗████████╗███████╗██████╗      ║"
        echo "  ║   ████╗ ████║██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗    ║"
        echo "  ║   ██╔████╔██║███████║   ██║      ██║   █████╗  ██████╔╝     ║"
        echo "  ║   ██║╚██╔╝██║██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗     ║"
        echo "  ║   ██║ ╚═╝ ██║██║  ██║   ██║      ██║   ███████╗██║  ██║     ║"
        echo "  ║   ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝    ║"
        echo "  ║        Instalador desde código fuente — Ubuntu 24.04         ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        echo -e "${RESET}"
        echo -e "${BOLD}Pasos:${RESET}"
        printf "  ${CYAN}%2s${RESET} %-35s  ${CYAN}%2s${RESET} %s\n" \
            1 "Dependencias del sistema"   7  "Clonar repositorio" \
            2 "libwebkit2gtk (Jammy)"      8  "Compilar WebApp" \
            3 "Límite descriptores"        9  "Compilar Servidor Go" \
            4 "Usuario 'mattermost'"      10  "Instalar en /opt" \
            5 "PostgreSQL 17"             11  "Configurar base de datos" \
            6 "Go + Node.js"              12  "Servicio systemd"
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        read -rp "$(echo -e "${CYAN}Contraseña mmuser [SECURE_PASSWORD]: ${RESET}")" input_pass
        [[ -n "${input_pass:-}" ]] && DB_PASSWORD="$input_pass"
        echo ""; read -rp "$(echo -e "${YELLOW}Presiona ENTER para iniciar...${RESET}")"
        clear
        echo -e "\n${BOLD}${BLUE}Progreso:${RESET}\n"
    fi
}

# =============================================================================
#  PASOS
# =============================================================================

step1_dependencies() {
    advance "Dependencias del sistema"
    info "Actualizando paquetes..."
    run apt-get update -y
    run apt-get upgrade -y
    run apt-get install -y build-essential git make g++ python3 curl wget \
        libpng-dev libx11-dev libxtst-dev
    ok "Dependencias instaladas"
}

step2_webkit() {
    advance "libwebkit2gtk-4.0-dev (Jammy)"
    info "Agregando repositorio Ubuntu 22.04 temporalmente..."
    echo "deb http://gb.archive.ubuntu.com/ubuntu jammy main" \
        > /etc/apt/sources.list.d/jammy-temp.list
    run apt-get update -y
    run apt-get install -y libwebkit2gtk-4.0-dev \
        || warn "libwebkit2gtk no instalado — puede omitirse en servidores headless"
    rm -f /etc/apt/sources.list.d/jammy-temp.list
    run apt-get update -y
    ok "libwebkit2gtk completado"
}

step3_ulimit() {
    advance "Límite de descriptores (nofile=8096)"
    ulimit -n 8096 2>/dev/null || warn "ulimit no modificable en esta sesión"
    grep -q "nofile 8096" /etc/security/limits.conf 2>/dev/null \
        || echo "* soft nofile 8096" >> /etc/security/limits.conf
    ok "Límite nofile=8096 configurado"
}

step4_user() {
    advance "Usuario sistema 'mattermost'"
    if id mattermost &>/dev/null; then
        warn "Usuario ya existe — omitiendo"
    else
        useradd --system --user-group mattermost
        ok "Usuario 'mattermost' creado"
    fi
}

step5_postgres() {
    advance "PostgreSQL 17"
    info "Instalando PostgreSQL 17..."
    install -d /usr/share/postgresql-common/pgdg
    run curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main' \
> /etc/apt/sources.list.d/pgdg.list"
    run apt-get update -y
    run apt-get install -y postgresql-17
    run systemctl enable --now postgresql

    info "Configurando base de datos..."
    sudo -u postgres psql >> "$LOG_FILE" 2>&1 << SQL
CREATE DATABASE mattermost
  WITH ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8';
CREATE USER mmuser WITH PASSWORD '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON DATABASE mattermost TO mmuser;
\c mattermost
ALTER SCHEMA public OWNER TO mmuser;
GRANT ALL ON SCHEMA public TO mmuser;
SQL
    ok "PostgreSQL 17 listo"
}

step6_go_node() {
    advance "Go $GO_VERSION y Node.js $NODE_VERSION"
    export HOME="${HOME:-/root}"

    # Go
    if command -v go &>/dev/null \
        && go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
        warn "Go $GO_VERSION ya instalado"
    else
        info "Descargando Go $GO_VERSION..."
        run wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
            -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        run tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        grep -q '/usr/local/go/bin' /etc/profile 2>/dev/null \
            || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    export PATH=$PATH:/usr/local/go/bin

    # NVM + Node
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
        info "Instalando NVM $NVM_VERSION..."
        run bash -c "curl -o- \
https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash"
    else
        warn "NVM ya instalado"
    fi
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    run nvm install "$NODE_VERSION"
    run nvm use "$NODE_VERSION"

    ok "Go $(go version | awk '{print $3}') | Node $(node --version 2>/dev/null)"
}

step7_clone() {
    advance "Clonar repositorio Mattermost"
    if [[ -d /root/mattermost/.git ]]; then
        warn "Repositorio ya clonado — git pull"
        run git -C /root/mattermost pull
    else
        info "Clonando repositorio..."
        run git clone https://github.com/mattermost/mattermost.git /root/mattermost
    fi
    ok "Repositorio en /root/mattermost"
}

step8_webapp() {
    advance "Compilar WebApp (frontend)"
    export NVM_DIR="${HOME:-/root}/.nvm"
    source "$NVM_DIR/nvm.sh" 2>/dev/null || true
    nvm use "$NODE_VERSION" >> "$LOG_FILE" 2>&1 || true
    info "npm install en webapp/ ..."
    cd /root/mattermost/webapp
    run npm install || {
        warn "Reintentando tras limpiar caché npm..."
        run npm cache clean --force
        run npm install
    }
    ok "WebApp compilada"
}

step9_server() {
    advance "Compilar Servidor Go"
    export PATH=$PATH:/usr/local/go/bin
    source "${HOME:-/root}/.nvm/nvm.sh" 2>/dev/null || true
    info "make build && make package — puede tardar 10-20 min..."
    cd /root/mattermost/server
    run make build
    run make package
    local pkg; pkg=$(ls dist/mattermost-*.tar.gz 2>/dev/null | head -1)
    [[ -n "$pkg" ]] || { err "Paquete no generado"; exit 1; }
    ok "Paquete generado: $(basename "$pkg")"
}

step10_install() {
    advance "Instalar en /opt/mattermost"
    local pkg; pkg=$(ls /root/mattermost/server/dist/mattermost-*.tar.gz 2>/dev/null | head -1)
    [[ -n "$pkg" ]] || { err "Paquete no encontrado"; exit 1; }
    info "Extrayendo en /opt ..."
    run tar -xzf "$pkg" -C /opt
    mkdir -p /opt/mattermost/data
    chown -R mattermost:mattermost /opt/mattermost
    chmod -R g+w /opt/mattermost
    ok "Instalado en /opt/mattermost"
}

step11_config() {
    advance "Configurar base de datos en config.json"
    local cfg="/opt/mattermost/config/config.json"
    [[ -f "$cfg" ]] || { err "config.json no encontrado"; exit 1; }
    cp "$cfg" "${cfg}.bak.$(date +%s)"
    sed -i 's/"DriverName": ".*"/"DriverName": "postgres"/' "$cfg"
    sed -i "s|\"DataSource\": \".*\"|\"DataSource\": \"postgres://mmuser:${DB_PASSWORD}@localhost:5432/mattermost?sslmode=disable\&connect_timeout=10\"|" "$cfg"
    ok "config.json actualizado (backup creado)"
}

step12_service() {
    advance "Servicio systemd mattermost"
    cat > /etc/systemd/system/mattermost.service << 'UNIT'
[Unit]
Description=Mattermost
After=network.target postgresql.service
BindsTo=postgresql.service

[Service]
Type=notify
ExecStart=/opt/mattermost/bin/mattermost
TimeoutStartSec=3600
KillMode=mixed
Restart=always
RestartSec=10
WorkingDirectory=/opt/mattermost
User=mattermost
Group=mattermost
LimitNOFILE=49152

[Install]
WantedBy=multi-user.target
UNIT
    run systemctl daemon-reload
    run systemctl enable --now mattermost
    ok "mattermost.service habilitado e iniciado"
}

# ─── Verificación final ────────────────────────────────────────────────────────
verify_install() {
    info "Verificando respuesta en :8065..."
    local retries=12 delay=10 ip
    ip=$(hostname -I | awk '{print $1}')

    for ((i=1; i<=retries; i++)); do
        if curl -sf http://localhost:8065 -o /dev/null; then
            if $USE_WHIPTAIL; then
                whiptail --title "✅ Instalación completada" --msgbox \
"Mattermost está corriendo correctamente.

  URL   :  http://${ip}:8065
  Log   :  $LOG_FILE

Gestión:
  sudo systemctl status mattermost
  sudo journalctl -u mattermost -f" \
                    16 65
            else
                echo ""
                echo -e "${BOLD}${GREEN}"
                echo "  ╔══════════════════════════════════════════════════════════════╗"
                echo "  ║   ✅  INSTALACIÓN COMPLETADA                                ║"
                echo "  ╠══════════════════════════════════════════════════════════════╣"
                printf  "  ║   URL  : http://%-44s║\n" "${ip}:8065    "
                printf  "  ║   Log  : %-51s║\n" "$LOG_FILE  "
                echo "  ╠══════════════════════════════════════════════════════════════╣"
                echo "  ║   sudo systemctl status mattermost                          ║"
                echo "  ║   sudo journalctl -u mattermost -f                          ║"
                echo "  ╚══════════════════════════════════════════════════════════════╝"
                echo -e "${RESET}"
            fi
            return 0
        fi
        info "Esperando inicio del servicio... ($i/$retries)"
        sleep "$delay"
    done
    err "El servidor no respondió tras $((retries * delay))s"
    err "Diagnóstico: journalctl -u mattermost -n 50 --no-pager"
    exit 1
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    log "════ Inicio instalación Mattermost — $(date) ════"

    preflight_checks
    welcome

    $USE_WHIPTAIL && start_gauge

    step1_dependencies
    step2_webkit
    step3_ulimit
    step4_user
    step5_postgres
    step6_go_node
    step7_clone
    step8_webapp
    step9_server
    step10_install
    step11_config
    step12_service

    $USE_WHIPTAIL && end_gauge

    verify_install
    log "════ Instalación finalizada — $(date) ════"
}

main "$@"
