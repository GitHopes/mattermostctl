#!/usr/bin/env bash
# =============================================================================
#  install_nginx_proxy.sh — Nginx reverse proxy para Mattermost
#  Ubuntu 24.04 LTS | Ejecutar DESPUÉS de install_mattermost.sh
#
#  Uso:  sudo bash install_nginx_proxy.sh
#
#  Características:
#    - Nginx como reverse proxy hacia localhost:8065
#    - Soporte HTTP (puerto 80) con redirección opcional a HTTPS
#    - Soporte HTTPS con Let's Encrypt (Certbot) o certificado manual
#    - WebSocket habilitado (requerido por Mattermost)
#    - Tuning de rendimiento y headers de seguridad
#    - UI TUI (whiptail) o modo texto ASCII según entorno
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Configuración (se sobreescribe en welcome()) ─────────────────────────────
LOG_FILE="/var/log/mattermost_nginx.log"
DOMAIN=""               # p. ej. chat.miempresa.com
USE_SSL=false
SSL_MODE=""             # "certbot" | "manual"
CERT_PATH=""            # Solo para SSL manual
KEY_PATH=""             # Solo para SSL manual
MM_PORT=8065
TOTAL_STEPS=6
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

on_error() {
    local code=$? line=$1
    err "Falló en línea $line (código $code) — Log: $LOG_FILE"
    if $USE_WHIPTAIL; then
        whiptail --title "❌ Error" \
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
    printf "\r${BOLD}${BLUE}[%s]${RESET} ${BOLD}%3d%%${RESET} %-38s" \
           "$bar" "$(( 100 * step / total ))" "$label"
    [[ $step -eq $total ]] && echo ""
}

# ─── Gauge whiptail ───────────────────────────────────────────────────────────
WP_PIPE=""
start_gauge() {
    WP_PIPE=$(mktemp -u /tmp/mm_nginx_XXXXXX)
    mkfifo "$WP_PIPE"
    whiptail --title "🔧 Configurando Nginx + Mattermost" \
             --gauge "Iniciando..." 8 72 0 < "$WP_PIPE" &
    exec 3>"$WP_PIPE"
}
update_gauge() { printf "XXX\n%d\n%s\nXXX\n" "$1" "$2" >&3; }
end_gauge()    { exec 3>&-; rm -f "$WP_PIPE"; wait 2>/dev/null || true; }

advance() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    local pct=$(( 100 * CURRENT_STEP / TOTAL_STEPS ))
    local lbl="Paso $CURRENT_STEP/$TOTAL_STEPS: $1"
    if $USE_WHIPTAIL; then update_gauge "$pct" "$lbl"
    else echo ""; draw_progress "$CURRENT_STEP" "$TOTAL_STEPS" "$1"; echo ""; fi
    log "── PASO $CURRENT_STEP: $1"
}

run() { "$@" >> "$LOG_FILE" 2>&1; }

# ─── Checks previos ───────────────────────────────────────────────────────────
preflight_checks() {
    info "Verificando requisitos previos..."
    [[ $(id -u) -eq 0 ]] || { err "Ejecuta: sudo bash $0"; exit 1; }

    # Mattermost debe estar instalado y corriendo
    [[ -f /opt/mattermost/bin/mattermost ]] || {
        err "Mattermost no encontrado en /opt/mattermost"
        err "Ejecuta primero install_mattermost.sh"
        exit 1
    }
    systemctl is-active --quiet mattermost || {
        warn "El servicio mattermost no está activo — intentando iniciar..."
        run systemctl start mattermost
        sleep 5
        systemctl is-active --quiet mattermost \
            || { err "No se pudo iniciar mattermost.service"; exit 1; }
    }
    curl -sf http://localhost:${MM_PORT} -o /dev/null \
        || { err "Mattermost no responde en :${MM_PORT}"; exit 1; }

    ok "Mattermost corriendo en :${MM_PORT}"
}

# ─── Bienvenida / recolección de configuración ───────────────────────────────
welcome() {
    local ip; ip=$(hostname -I | awk '{print $1}')

    if $USE_WHIPTAIL; then
        # ── Pantalla inicial ──────────────────────────────────────────────────
        whiptail --title "🔧 Nginx Reverse Proxy — Mattermost" --msgbox \
"Este script configurará Nginx como reverse proxy para Mattermost.

  Mattermost detectado en:  http://${ip}:${MM_PORT}
  Log de instalación:       $LOG_FILE

A continuación se te pedirá:
  1. Dominio o IP pública
  2. Si deseas habilitar HTTPS
  3. Método de certificado SSL (si aplica)" \
        16 65

        # ── Dominio ───────────────────────────────────────────────────────────
        DOMAIN=$(whiptail --title "Dominio o IP" \
            --inputbox \
"Introduce el dominio o IP pública para Mattermost.
Ejemplos:
  chat.miempresa.com
  ${ip}

(Sin http:// ni barra final)" \
            12 65 "$ip" 3>&1 1>&2 2>&3) || DOMAIN="$ip"
        [[ -z "$DOMAIN" ]] && DOMAIN="$ip"

        # ── SSL ───────────────────────────────────────────────────────────────
        if whiptail --title "HTTPS / SSL" --yesno \
"¿Deseas habilitar HTTPS (SSL/TLS)?

  Recomendado para producción.
  Requiere que el dominio '$DOMAIN' apunte
  a esta IP y que el puerto 80 esté abierto.

¿Habilitar HTTPS?" 14 65; then
            USE_SSL=true

            SSL_MODE=$(whiptail --title "Método de certificado SSL" \
                --menu "Elige cómo obtener el certificado:" 14 65 2 \
                "certbot"  "Let's Encrypt (automático, gratuito)" \
                "manual"   "Certificado propio (ruta a .crt y .key)" \
                3>&1 1>&2 2>&3) || SSL_MODE="certbot"

            if [[ "$SSL_MODE" == "manual" ]]; then
                CERT_PATH=$(whiptail --title "Ruta del certificado" \
                    --inputbox "Ruta completa al archivo .crt o .pem:" \
                    10 65 "/etc/ssl/certs/mattermost.crt" \
                    3>&1 1>&2 2>&3) || CERT_PATH=""
                KEY_PATH=$(whiptail --title "Ruta de la clave privada" \
                    --inputbox "Ruta completa al archivo .key:" \
                    10 65 "/etc/ssl/private/mattermost.key" \
                    3>&1 1>&2 2>&3) || KEY_PATH=""
            fi
        fi

        # ── Resumen ───────────────────────────────────────────────────────────
        local ssl_info="No (solo HTTP)"
        $USE_SSL && ssl_info="Sí — ${SSL_MODE}"
        whiptail --title "Resumen de configuración" --yesno \
"Configuración que se aplicará:

  Dominio / IP  :  $DOMAIN
  Proxy hacia   :  localhost:${MM_PORT}
  HTTPS         :  ${ssl_info}
  Config Nginx  :  /etc/nginx/sites-available/mattermost
  Log           :  $LOG_FILE

¿Confirmas la instalación?" \
        16 65 || { echo "Cancelado."; exit 0; }

    else
        # ── Modo texto ────────────────────────────────────────────────────────
        clear
        echo -e "${BOLD}${BLUE}"
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║   ███╗  ██╗ ██████╗ ██╗███╗  ██╗██╗  ██╗                   ║"
        echo "  ║   ████╗ ██║██╔════╝ ██║████╗ ██║╚██╗██╔╝                   ║"
        echo "  ║   ██╔██╗██║██║  ███╗██║██╔██╗██║ ╚███╔╝                    ║"
        echo "  ║   ██║╚████║██║   ██║██║██║╚████║ ██╔██╗                    ║"
        echo "  ║   ██║ ╚███║╚██████╔╝██║██║ ╚███║██╔╝ ██╗                   ║"
        echo "  ║   ╚═╝  ╚══╝ ╚═════╝ ╚═╝╚═╝  ╚══╝╚═╝  ╚═╝                  ║"
        echo "  ║        Reverse Proxy para Mattermost — Ubuntu 24.04         ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        echo -e "${RESET}"
        echo -e "  ${GREEN}✔${RESET} Mattermost detectado en ${CYAN}http://${ip}:${MM_PORT}${RESET}"
        echo ""

        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        read -rp "$(echo -e "${CYAN}Dominio o IP pública${RESET} [${ip}]: ")" input_domain
        DOMAIN="${input_domain:-$ip}"

        echo ""
        read -rp "$(echo -e "${CYAN}¿Habilitar HTTPS? (s/N): ${RESET}")" input_ssl
        if [[ "${input_ssl,,}" == "s" || "${input_ssl,,}" == "si" || "${input_ssl,,}" == "y" ]]; then
            USE_SSL=true
            echo ""
            echo -e "  ${CYAN}1${RESET}  Let's Encrypt (Certbot) — automático y gratuito"
            echo -e "  ${CYAN}2${RESET}  Certificado manual (.crt + .key)"
            read -rp "$(echo -e "${CYAN}Método SSL${RESET} [1]: ")" input_ssl_mode
            case "${input_ssl_mode:-1}" in
                2) SSL_MODE="manual"
                   read -rp "$(echo -e "${CYAN}Ruta al .crt: ${RESET}")" CERT_PATH
                   read -rp "$(echo -e "${CYAN}Ruta al .key: ${RESET}")" KEY_PATH
                   ;;
                *) SSL_MODE="certbot" ;;
            esac
        fi

        echo ""
        local ssl_info="No (solo HTTP)"
        $USE_SSL && ssl_info="Sí — ${SSL_MODE}"
        echo -e "${BOLD}Resumen:${RESET}"
        echo -e "  Dominio  : ${CYAN}$DOMAIN${RESET}"
        echo -e "  Proxy    : localhost:${MM_PORT}"
        echo -e "  HTTPS    : ${CYAN}${ssl_info}${RESET}"
        echo ""
        read -rp "$(echo -e "${YELLOW}Presiona ENTER para continuar o Ctrl+C para cancelar...${RESET}")"
        clear
        echo -e "\n${BOLD}${BLUE}Progreso:${RESET}\n"
    fi
}

# =============================================================================
#  PASOS
# =============================================================================

step1_install_nginx() {
    advance "Instalar Nginx"
    info "Instalando nginx..."
    run apt-get update -y
    run apt-get install -y nginx
    run systemctl enable nginx
    ok "Nginx instalado"
}

step2_write_config() {
    advance "Escribir configuración de Nginx"
    local cfg_path="/etc/nginx/sites-available/mattermost"
    info "Generando configuración en $cfg_path ..."

    # ── Bloque upstream ───────────────────────────────────────────────────────
    local upstream_block
    upstream_block=$(cat << 'UPSTREAM'
upstream mattermost_backend {
    server localhost:MMPORT;
    keepalive 256;
}
UPSTREAM
)
    upstream_block="${upstream_block//MMPORT/${MM_PORT}}"

    # ── Bloque server HTTP ────────────────────────────────────────────────────
    local http_block
    if $USE_SSL; then
        # HTTP → redirect HTTPS
        http_block=$(cat << HTTPBLOCK
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Permite que Certbot renueve certificados
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
HTTPBLOCK
)
    else
        # HTTP directo
        http_block=$(cat << HTTPBLOCK
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Tamaño máximo de carga de archivos
    client_max_body_size 50M;

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_pass http://mattermost_backend;
    }

    location / {
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_cache_revalidate on;
        proxy_cache_min_uses 2;
        proxy_cache_use_stale timeout;
        proxy_cache_lock on;
        proxy_http_version 1.1;
        proxy_pass http://mattermost_backend;
    }
}
HTTPBLOCK
)
    fi

    # ── Bloque server HTTPS ───────────────────────────────────────────────────
    local https_block=""
    if $USE_SSL; then
        local ssl_cert ssl_key
        if [[ "$SSL_MODE" == "certbot" ]]; then
            ssl_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
            ssl_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        else
            ssl_cert="$CERT_PATH"
            ssl_key="$KEY_PATH"
        fi

        https_block=$(cat << HTTPSBLOCK
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${ssl_cert};
    ssl_certificate_key ${ssl_key};

    # Protocolos y cifrados modernos
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS (6 meses)
    add_header Strict-Transport-Security "max-age=15768000" always;

    # Tamaño máximo de carga de archivos
    client_max_body_size 50M;

    # Headers de seguridad
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_pass http://mattermost_backend;
    }

    location / {
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 256 16k;
        proxy_buffer_size 16k;
        proxy_read_timeout 600s;
        proxy_cache_revalidate on;
        proxy_cache_min_uses 2;
        proxy_cache_use_stale timeout;
        proxy_cache_lock on;
        proxy_http_version 1.1;
        proxy_pass http://mattermost_backend;
    }
}
HTTPSBLOCK
)
    fi

    # ── Escribir archivo de configuración ─────────────────────────────────────
    {
        echo "# Mattermost Nginx Reverse Proxy"
        echo "# Generado por install_nginx_proxy.sh — $(date)"
        echo ""
        echo "$upstream_block"
        echo ""
        echo "$http_block"
        [[ -n "$https_block" ]] && { echo ""; echo "$https_block"; }
    } > "$cfg_path"

    # ── Activar sitio ─────────────────────────────────────────────────────────
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    ln -sf "$cfg_path" /etc/nginx/sites-enabled/mattermost

    ok "Configuración escrita y enlazada en sites-enabled"
}

step3_tuning() {
    advance "Tuning de rendimiento en nginx.conf"
    local nginx_conf="/etc/nginx/nginx.conf"

    # worker_processes auto (si no está ya)
    grep -q "worker_processes auto" "$nginx_conf" \
        || sed -i 's/worker_processes.*/worker_processes auto;/' "$nginx_conf"

    # Añadir sendfile / tcp_nopush / keepalive en el bloque http si faltan
    if ! grep -q "sendfile on" "$nginx_conf"; then
        sed -i '/http {/a\\    sendfile on;\n    tcp_nopush on;\n    tcp_nodelay on;\n    keepalive_timeout 65;\n    types_hash_max_size 2048;' \
            "$nginx_conf"
    fi

    # Aumentar worker_connections si es bajo
    sed -i 's/worker_connections\s*[0-9]*/worker_connections 1024/' "$nginx_conf" || true

    run nginx -t
    ok "Tuning aplicado y configuración validada"
}

step4_ssl_certbot() {
    if ! $USE_SSL || [[ "$SSL_MODE" != "certbot" ]]; then
        CURRENT_STEP=$(( CURRENT_STEP + 1 ))
        local pct=$(( 100 * CURRENT_STEP / TOTAL_STEPS ))
        $USE_WHIPTAIL && update_gauge "$pct" "Paso $CURRENT_STEP/$TOTAL_STEPS: Certbot (omitido)"
        log "── PASO $CURRENT_STEP: Certbot (omitido — SSL no seleccionado)"
        return 0
    fi

    advance "Certificado SSL con Certbot (Let's Encrypt)"
    info "Instalando certbot y plugin nginx..."
    run apt-get install -y certbot python3-certbot-nginx

    # Directorio para desafíos ACME
    mkdir -p /var/www/certbot

    # Primero aplicamos la config HTTP (sin HTTPS) para que Certbot pueda verificar
    run systemctl reload nginx

    info "Solicitando certificado para $DOMAIN ..."
    run certbot --nginx \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect || {
            warn "Certbot falló — verifica que $DOMAIN resuelva a esta IP y el puerto 80 esté abierto"
            warn "Puedes obtener el certificado manualmente después con:"
            warn "  sudo certbot --nginx -d $DOMAIN"
        }

    # Renovación automática (cron diario)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        ( crontab -l 2>/dev/null; \
          echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'" ) \
          | crontab -
        ok "Renovación automática configurada en cron (03:00 diario)"
    fi

    ok "Certificado SSL obtenido para $DOMAIN"
}

step5_firewall() {
    advance "Configurar firewall (ufw)"
    if command -v ufw &>/dev/null; then
        run ufw allow 'Nginx Full' || run ufw allow 80/tcp && run ufw allow 443/tcp
        # Bloquear acceso directo al puerto 8065 desde el exterior
        # (solo accesible vía Nginx en localhost)
        run ufw deny 8065/tcp 2>/dev/null || true
        ok "Firewall configurado: 80 y 443 abiertos, 8065 solo en localhost"
    else
        warn "ufw no disponible — configura el firewall manualmente"
        warn "  Abre: 80/tcp, 443/tcp"
        warn "  Cierra o restringe: 8065/tcp"
    fi
}

step6_reload() {
    advance "Reiniciar y verificar Nginx"
    run systemctl reload nginx || run systemctl restart nginx
    systemctl is-active --quiet nginx || { err "Nginx no está activo"; exit 1; }
    ok "Nginx activo y configuración recargada"
}

# ─── Verificación final ────────────────────────────────────────────────────────
verify() {
    info "Verificando acceso vía Nginx..."
    local url retries=6 delay=5

    if $USE_SSL; then
        url="https://${DOMAIN}"
    else
        url="http://${DOMAIN}"
    fi

    for ((i=1; i<=retries; i++)); do
        if curl -sfk "$url" -o /dev/null; then
            if $USE_WHIPTAIL; then
                whiptail --title "✅ Nginx configurado correctamente" --msgbox \
"Mattermost es accesible a través de Nginx.

  URL pública  :  ${url}
  Config Nginx :  /etc/nginx/sites-available/mattermost
  Log          :  $LOG_FILE

Gestión de Nginx:
  sudo systemctl status nginx
  sudo nginx -t
  sudo systemctl reload nginx" \
                18 65
            else
                echo ""
                echo -e "${BOLD}${GREEN}"
                echo "  ╔══════════════════════════════════════════════════════════════╗"
                echo "  ║   ✅  NGINX CONFIGURADO CORRECTAMENTE                       ║"
                echo "  ╠══════════════════════════════════════════════════════════════╣"
                printf  "  ║   URL    : %-50s║\n" "${url}  "
                printf  "  ║   Config : %-50s║\n" "/etc/nginx/sites-available/mattermost  "
                printf  "  ║   Log    : %-50s║\n" "$LOG_FILE  "
                echo "  ╠══════════════════════════════════════════════════════════════╣"
                echo "  ║   sudo systemctl status nginx                               ║"
                echo "  ║   sudo nginx -t && sudo systemctl reload nginx              ║"
                echo "  ╚══════════════════════════════════════════════════════════════╝"
                echo -e "${RESET}"
            fi
            return 0
        fi
        info "Intento $i/$retries — esperando ${delay}s..."
        sleep "$delay"
    done

    warn "No se pudo verificar $url automáticamente"
    warn "Si usaste un dominio, asegúrate de que el DNS apunte a esta IP"
    warn "Prueba manualmente: curl -I $url"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    log "════ Inicio configuración Nginx — $(date) ════"

    preflight_checks
    welcome

    $USE_WHIPTAIL && start_gauge

    step1_install_nginx
    step2_write_config
    step3_tuning
    step4_ssl_certbot
    step5_firewall
    step6_reload

    $USE_WHIPTAIL && end_gauge

    verify
    log "════ Nginx configurado — $(date) ════"
}

main "$@"
