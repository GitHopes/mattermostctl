# 🚀 Instalador automático de Mattermost desde código fuente

Instala Mattermost completamente desde fuente en **Ubuntu 24.04 LTS** con un solo comando.  
Incluye interfaz TUI gráfica (whiptail) o barra de progreso ASCII, manejo de errores y log detallado.

---

## 📋 Requisitos del servidor

| Recurso | Mínimo | Recomendado |
|---------|--------|-------------|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disco (`/opt`) | 10 GB | 20 GB |
| SO | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Red | Acceso a Internet | Bridge / NAT |

> El script verifica estos requisitos antes de iniciar y advierte si no se cumplen.

---

## ⚡ Uso rápido
```bash
chmod +x install_mattermost.sh
sudo bash install_mattermost.sh
```

Al iniciarse, el script detecta automáticamente el entorno y elige la mejor interfaz disponible.

---

## 🖥️ Modos de interfaz

### Modo TUI gráfico (whiptail)
Se activa automáticamente cuando `whiptail` está instalado y hay una terminal interactiva.
- Diálogo de bienvenida con resumen de la instalación
- Cuadro de contraseña enmascarado para `mmuser`
- Barra de progreso animada paso a paso
- Diálogo final de éxito o error

### Modo texto ASCII
Fallback automático en entornos sin whiptail (SSH sin TTY, CI/CD, etc.).
- Banner ASCII al inicio
- Barra de bloques `█░` en tiempo real
- Recuadro de resultado final con URL de acceso

---

## 📦 Qué instala el script

| Paso | Componente | Detalle |
|------|-----------|---------|
| 1 | Dependencias del sistema | `build-essential`, `git`, `make`, `g++`, `curl`, `wget`… |
| 2 | libwebkit2gtk-4.0-dev | Desde repositorio Ubuntu 22.04 (Jammy) temporal |
| 3 | Límite de descriptores | `nofile = 8096` en `/etc/security/limits.conf` |
| 4 | Usuario sistema | `mattermost` (sin shell, sin home) |
| 5 | PostgreSQL 17 | Repositorio oficial pgdg + base de datos + usuario |
| 6 | Go 1.23.1 | Desde `go.dev/dl` en `/usr/local/go` |
| 6 | Node.js 20.11.1 | Vía NVM 0.40.1 |
| 7 | Repositorio | `git clone github.com/mattermost/mattermost` |
| 8 | WebApp | `npm install` en `webapp/` |
| 9 | Servidor | `make build && make package` en `server/` |
| 10 | Instalación | Extracción en `/opt/mattermost` + permisos |
| 11 | Configuración | `config.json` actualizado con conexión PostgreSQL |
| 12 | Servicio | `mattermost.service` registrado en systemd |

---

## ⚙️ Variables configurables

Edita las variables al inicio del script antes de ejecutarlo:
```bash
DB_PASSWORD="SECURE_PASSWORD"   # ⚠️ Cambia esto obligatoriamente
GO_VERSION="1.23.1"
NODE_VERSION="20.11.1"
NVM_VERSION="0.40.1"
LOG_FILE="/var/log/mattermost_install.log"
```

> También puedes introducir la contraseña de forma interactiva al ejecutar —
> el modo TUI muestra un cuadro enmascarado y el modo texto lo pide por consola.

---

## 📁 Estructura tras la instalación
```
/opt/mattermost/
├── bin/mattermost              ← Binario principal
├── config/
│   ├── config.json             ← Configuración activa
│   └── config.json.bak.*       ← Backup automático
├── data/                       ← Archivos de usuario
├── logs/                       ← Logs de Mattermost
└── plugins/

/etc/systemd/system/
└── mattermost.service

/var/log/
└── mattermost_install.log      ← Log completo de la instalación
```

---

## 🔧 Gestión del servicio
```bash
sudo systemctl status mattermost          # Estado
sudo journalctl -u mattermost -f          # Logs en tiempo real
sudo systemctl restart mattermost         # Reiniciar
sudo systemctl stop|start mattermost      # Detener / iniciar
```

---

## 🌐 Acceso

Una vez finalizada la instalación, abre en el navegador:
```
http://<IP-del-servidor>:8065
```

La primera vez aparece el asistente para crear equipo y usuario administrador.

---

## 🔍 Diagnóstico de errores
```bash
# Log de instalación
tail -100 /var/log/mattermost_install.log

# Errores del servicio
sudo journalctl -u mattermost -n 50 --no-pager

# Verificar que responde
curl -v http://localhost:8065
```

### Problemas comunes

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `npm install` falla | Red inestable / caché corrompida | El script reintenta automáticamente |
| `make build` falla | Go no en PATH | `source /etc/profile` y reintenta |
| Servicio no arranca | Contraseña BD incorrecta | Verifica `config.json` y estado de PostgreSQL |
| Puerto 8065 no responde | Firewall activo | `sudo ufw allow 8065/tcp` |
| Error de descriptores | `nofile` insuficiente | Reinicia sesión y vuelve a ejecutar |

---

## 🔒 Seguridad post-instalación
```bash
# Cambiar contraseña de mmuser
sudo -u postgres psql -c "ALTER USER mmuser WITH PASSWORD 'nueva-clave';"

# Actualizar config.json con la nueva clave
sudo nano /opt/mattermost/config/config.json

# Configurar firewall (exponer solo HTTPS vía proxy inverso)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw deny 8065/tcp
sudo ufw enable
```

> En producción, Mattermost **nunca debe exponerse directamente** sin TLS.
> Usa Nginx o Caddy como proxy inverso.

---

## 📝 Notas

- **Idempotente** — detecta si Go, NVM o el usuario `mattermost` ya existen y omite esos pasos.
- **Backup automático** de `config.json` antes de cada modificación (`config.json.bak.<timestamp>`).
- El repositorio Jammy se agrega y **elimina automáticamente** tras instalar `libwebkit2gtk`.
- En servidores headless, la ausencia de `libwebkit2gtk` se advierte pero no bloquea la instalación.
- Duración estimada: **20–40 minutos** según velocidad de red y CPU.

---

## 📄 Licencia

Script de automatización de referencia.  
Mattermost es software libre bajo licencia [MIT / Apache 2.0](https://github.com/mattermost/mattermost/blob/master/LICENSE.txt).
