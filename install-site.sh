#!/bin/bash
# =============================================================================
# CDPNI — Portal Flask v1.0
# Execute como root: sudo bash cdpni-flask-install.sh
# Portal: https://192.168.0.11  |  Painel admin: https://192.168.0.11:8443
# =============================================================================
set -euo pipefail
IFS=$'\n\t'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
error()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}"; exit 1; }
header() { echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════${NC}";
           echo -e "${BOLD}${BLUE}  $*${NC}";
           echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}\n"; }
[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash $0"

APP_DIR="/opt/cdpni-portal"
VENV="${APP_DIR}/venv"
DATA_DIR="${APP_DIR}/data"
UPLOAD_DIR="${DATA_DIR}/uploads"
SSL_DIR="/etc/nginx/ssl"
SAMBA_ROOT="/mnt/raid/shares"
SAMBA_IP="192.168.0.11"
DOMAIN="cdpni.local"
PANEL_DIR="/var/www/samba-panel"
SERVICE="cdpni-portal"
PORT="5000"

# ===========================================================================
# 1. DEPENDÊNCIAS
# ===========================================================================
header "1. Instalando dependências"
apt-get update -qq
for pkg in python3 python3-pip python3-venv python3-pam nginx acl; do
    dpkg -l "$pkg" &>/dev/null && log "$pkg OK" || {
        warn "Instalando $pkg..."; apt-get install -y "$pkg"
    }
done

# ===========================================================================
# 2. SSL
# ===========================================================================
header "2. Certificado SSL"
mkdir -p "${SSL_DIR}"
if [[ ! -f "${SSL_DIR}/cdpni.crt" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${SSL_DIR}/cdpni.key" -out "${SSL_DIR}/cdpni.crt" \
        -subj "/C=BR/ST=SP/O=CDPNI/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},IP:${SAMBA_IP}" 2>/dev/null
    chmod 600 "${SSL_DIR}/cdpni.key"
    log "Certificado SSL gerado"
else
    log "Certificado existente mantido"
fi

# ===========================================================================
# 3. ESTRUTURA
# ===========================================================================
header "3. Criando estrutura"
mkdir -p "${APP_DIR}" "${DATA_DIR}" "${UPLOAD_DIR}"
log "Diretório: ${APP_DIR}"

# ===========================================================================
# 4. VIRTUALENV + PACOTES
# ===========================================================================
header "4. Ambiente Python"
if [[ ! -d "${VENV}" ]]; then
    python3 -m venv --system-site-packages "${VENV}" 2>/dev/null         || python3 -m venv "${VENV}"
    log "Virtualenv criado"
fi
"${VENV}/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
"${VENV}/bin/pip" install --quiet flask python-pam 2>/dev/null || true

# Verificar pam no venv — copiar se necessário
"${VENV}/bin/python3" -c "import pam" 2>/dev/null || {
    warn "pam não encontrado no venv — copiando do sistema..."
    PAM_FILE=$(python3 -c "import pam; print(pam.__file__)" 2>/dev/null || true)
    SITE=$("${VENV}/bin/python3" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
    [[ -n "$PAM_FILE" && -n "$SITE" ]] && cp "$PAM_FILE" "$SITE/" 2>/dev/null || true
    PAM_SO=$(find /usr/lib/python3 -name "_pam*.so" 2>/dev/null | head -1)
    [[ -n "$PAM_SO" && -n "$SITE" ]] && cp "$PAM_SO" "$SITE/" 2>/dev/null || true
}
"${VENV}/bin/python3" -c "import pam" 2>/dev/null     && log "Flask + pam instalados"     || warn "pam indisponível no venv — autenticação pode falhar"

# ===========================================================================
# 5. GRUPO SHADOW PARA O USUÁRIO DO SERVIÇO
# ===========================================================================
header "5. Permissões PAM e Shadow"

# Garantir que grupo shadow existe e cdpni tem acesso
for SHADOW_GRP in shadow _shadow; do
    getent group "$SHADOW_GRP" &>/dev/null && break
done
[[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null || true; SHADOW_GRP="shadow"; }
usermod -aG "$SHADOW_GRP" cdpni 2>/dev/null || true
usermod -aG "$SHADOW_GRP" www-data 2>/dev/null || true
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
log "Shadow: grupo $SHADOW_GRP configurado"

header "5b. PAM"
# Criar usuário do serviço se não existir
if ! id cdpni &>/dev/null; then
    useradd -r -s /bin/false -d "${APP_DIR}" cdpni
    log "Usuário cdpni criado"
fi
# Adicionar ao grupo shadow para PAM funcionar
SHADOW_GRP=""
for g in shadow _shadow; do getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }; done
if [[ -z "$SHADOW_GRP" ]]; then
    groupadd shadow 2>/dev/null || true
    SHADOW_GRP="shadow"
fi
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
usermod -aG "${SHADOW_GRP}" cdpni && log "cdpni → grupo ${SHADOW_GRP}"

# ===========================================================================
# 6. SUDOERS — pdbedit e smbpasswd sem senha
# ===========================================================================
header "6. Sudoers"
cat > /etc/sudoers.d/cdpni-portal << 'SUDOEOF'
cdpni ALL=(ALL) NOPASSWD: /usr/bin/pdbedit
cdpni ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/useradd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/usermod
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/userdel
cdpni ALL=(ALL) NOPASSWD: /usr/bin/gpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/bin/chpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/chpasswd
SUDOEOF
chmod 440 /etc/sudoers.d/cdpni-portal
visudo -c -f /etc/sudoers.d/cdpni-portal && log "sudoers OK" || warn "Verifique sudoers"

# ===========================================================================
# 7. PAM
# ===========================================================================
header "7. PAM"
cat > /etc/pam.d/cdpni-portal << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF
log "Serviço PAM: cdpni-portal"

# ===========================================================================
# 8. APP FLASK — app.py
# ===========================================================================
header "8. Criando aplicação Flask"

cat > "${APP_DIR}/app.py" << 'PYEOF'
#!/usr/bin/env python3
"""CDPNI — Portal de Arquivos v1.0 — Flask + PAM"""
import os, json, shutil, subprocess, mimetypes
from pathlib import Path
from datetime import datetime
from functools import wraps
import pam
from flask import (Flask, request, session, redirect, url_for,
                   send_file, jsonify, render_template_string, abort)

app = Flask(__name__)
app.secret_key = os.urandom(32)
app.config['MAX_CONTENT_LENGTH'] = 512 * 1024 * 1024  # 512 MB

# ── Configurações ─────────────────────────────────────────────────────────
SAMBA_IP   = "192.168.0.11"
SAMBA_HOST = "cdpni.local"
SAMBA_ROOT = Path("/mnt/raid/shares")
DATA_FILE  = Path("/opt/cdpni-portal/data/portal_data.json")
UPLOAD_DIR = Path("/opt/cdpni-portal/data/uploads")
ADMIN_USER = "jpfagiani"
VERSION    = "1.0"
ROOT_USERS = {"sambadmin", "jpfagiani", "rcborges", "cpd", "supervisao"}

# ── Mapa de compartilhamentos ─────────────────────────────────────────────
# nome_exibição: (pasta_no_disco, grupo_linux, ícone_tabler)
SHARES = {
    "Administrativo":   ("Administrativo",    "grp_administrativo",    "ti-users"),
    "AEVP":             ("Aevp",              "grp_aevp",              "ti-certificate"),
    "Almoxarifado":     ("Almoxarifado",       "grp_almoxarifado",      "ti-package"),
    "Cadastro":         ("Cadastro",           "grp_cadastro",          "ti-id-badge"),
    "Canil":            ("Canil",              "grp_canil",             "ti-paw"),
    "Chefia Turno I":   ("Chefia_Turno_I",     "grp_chefia_1",          "ti-shield-star"),
    "Chefia Turno II":  ("Chefia_Turno_II",    "grp_chefia_2",          "ti-shield-star"),
    "Chefia Turno III": ("Chefia_Turno_III",   "grp_chefia_3",          "ti-shield-star"),
    "Chefia Turno IV":  ("Chefia_Turno_IV",    "grp_chefia_4",          "ti-shield-star"),
    "CIPA":             ("Cipa",               "grp_cipa",              "ti-heart-handshake"),
    "Conexão Familiar": ("Conexao_Familiar",   "grp_conexao_familiar",  "ti-friends"),
    "CPD":              ("CPD",                "grp_cpd",               "ti-server"),
    "CSD":              ("csd",                "grp_csd",               "ti-building"),
    "Diretoria Geral":  ("Diretoria_Geral",    "grp_diretoria",         "ti-crown"),
    "Educação":         ("Educacao",           "grp_educacao",          "ti-school"),
    "Finanças":         ("Financas",           "grp_financas",          "ti-cash"),
    "Inclusão":         ("Inclusao",           "grp_inclusao",          "ti-user-plus"),
    "Infraestrutura":   ("Infraestrutura",     "grp_infraestrutura",    "ti-tool"),
    "Núcleo de Pessoal":("Nucleo_de_Pessoal",  "grp_nucleo_pessoal",    "ti-file-text"),
    "Papel de Parede":  ("Papel_de_Parede",    "grp_papel_parede",      "ti-photo"),
    "Planilhas":        ("Planilhas",          "grp_planilhas",         "ti-table"),
    "Portaria I":       ("Portaria_Turno_I",   "grp_portaria",          "ti-door"),
    "Portaria II":      ("Portaria_Turno_II",  "grp_portaria",          "ti-door"),
    "Portaria III":     ("Portaria_Turno_III", "grp_portaria",          "ti-door"),
    "Portaria IV":      ("Portaria_Turno_IV",  "grp_portaria",          "ti-door"),
    "Público":          ("Publico",            "grp_publico",           "ti-folder-open"),
    "Rol de Visitas":   ("Rol_de_Visitas",     "grp_rol_visitas",       "ti-eye"),
    "Saúde":            ("Saude",              "grp_saude",             "ti-first-aid-kit"),
    "Scanner":          ("Scanner",            "grp_scanner",           "ti-scan"),
    "SIMIC":            ("Simic",              "grp_simic",             "ti-database"),
    "Sindicância":      ("Sindicancia",        "grp_sindicancia",       "ti-gavel"),
    "Supervisão":       ("Supervisao",         "grp_supervisao",        "ti-shield-check"),
}

# ── Helpers ───────────────────────────────────────────────────────────────
def get_user_groups(user: str) -> set:
    try:
        out = subprocess.check_output(["id", "-Gn", user],
                                      stderr=subprocess.DEVNULL, text=True)
        return set(out.strip().split())
    except Exception:
        return set()

def can_access(user: str, share_name: str) -> bool:
    if user in ROOT_USERS:
        return True
    info = SHARES.get(share_name)
    if not info:
        return False
    needed_group = info[1]
    return needed_group in get_user_groups(user)

def auth_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated

def is_admin() -> bool:
    return session.get("user") == ADMIN_USER

def load_data() -> dict:
    default = {"banners": [], "notices": [], "right_info": []}
    try:
        if DATA_FILE.exists():
            d = json.loads(DATA_FILE.read_text())
            return {**default, **d}
    except Exception:
        pass
    return default

def save_data(data: dict):
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    DATA_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2))

def fmt_size(n: int) -> str:
    if n == 0: return "—"
    for unit in ["B","KB","MB","GB","TB"]:
        if n < 1024: return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"

def fmt_date(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%d/%m/%Y %H:%M")

def file_icon(ext: str) -> str:
    return {
        "pdf": "ti-file-type-pdf",
        "doc": "ti-file-type-docx", "docx": "ti-file-type-docx",
        "xls": "ti-file-spreadsheet", "xlsx": "ti-file-spreadsheet",
        "csv": "ti-file-spreadsheet",
        "ppt": "ti-presentation", "pptx": "ti-presentation",
        "jpg": "ti-photo", "jpeg": "ti-photo", "png": "ti-photo",
        "gif": "ti-photo", "webp": "ti-photo", "bmp": "ti-photo",
        "mp4": "ti-video", "avi": "ti-video", "mkv": "ti-video",
        "mp3": "ti-music", "wav": "ti-music",
        "zip": "ti-file-zip", "rar": "ti-file-zip", "7z": "ti-file-zip",
        "txt": "ti-file-text", "log": "ti-file-text",
    }.get(ext.lower(), "ti-file")

def safe_path(share_name: str, rel: str = "") -> tuple:
    """Retorna (base, full_path) ou levanta ValueError se fora do share."""
    info = SHARES.get(share_name)
    if not info:
        raise ValueError("Share inválido")
    base = (SAMBA_ROOT / info[0]).resolve()
    if rel:
        full = (base / rel.lstrip("/")).resolve()
    else:
        full = base
    if not str(full).startswith(str(base)):
        raise ValueError("Caminho inválido")
    return base, full

# ── HTML Template ─────────────────────────────────────────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>CDPNI — Portal de Arquivos</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--tb:#1c3557;--bd:#d0d7de;--bds:#b0bec8;--bg:#f4f6f8;--bgw:#fff;
  --tx:#1a2a3a;--txs:#4a5a6a;--txm:#7a8a9a;--ac:#1c5fad;--acb:#e8f0fb;
  --gn:#2a7a3a;--gnb:#e8f5ec;--gnd:#9ad0aa;
  --rd:#a03030;--rdb:#fef0f0;--rdd:#f0b0b0;
  --am:#8a5a00;--amb:#fff8e6;--f:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
html,body{height:100%;font-family:var(--f);background:var(--bg);color:var(--tx)}
body{display:flex;flex-direction:column;overflow:hidden}

/* LOGIN */
.login-wrap{min-height:100vh;background:linear-gradient(150deg,#0d2340 0%,#1a3a5c 100%);display:flex;align-items:center;justify-content:center;padding:20px}
.login-box{background:#ffffff;border-radius:14px;padding:40px 36px;width:400px;box-shadow:0 20px 60px rgba(0,0,0,.4);border:1px solid #d0d7de}
.login-logo{text-align:center;margin-bottom:28px}
.login-logo .crest{width:68px;height:68px;background:#e8f0fb;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;border:2px solid #b5d4f4;margin-bottom:14px}
.login-logo .crest i{font-size:30px;color:#1c5fad}
.login-logo h1{font-size:15px;font-weight:600;line-height:1.4;color:#1a2a3a}
.login-logo p{font-size:12px;color:#7a8a9a;margin-top:6px}
.login-box label{display:block;font-size:12px;font-weight:600;color:#4a5a6a;margin:16px 0 5px}
.login-box input{width:100%;border:1.5px solid #c0ccd8;border-radius:8px;padding:11px 13px;font-size:14px;color:#1a2a3a;font-family:var(--f);outline:none;background:#fafbfc}
.login-box input:focus{border-color:#1c5fad;box-shadow:0 0 0 3px rgba(28,95,173,.15);background:#fff}
.login-btn{width:100%;margin-top:22px;padding:12px;background:#1c3557;color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;font-family:var(--f);letter-spacing:.3px}
.login-btn:hover{background:#244e7a}
.login-btn:active{background:#1a2f4a}
.login-err{margin-top:12px;font-size:12px;color:#a03030;text-align:center;min-height:18px;background:#fef0f0;border-radius:6px;padding:6px 10px;display:none}
.login-err.show{display:block}

/* TOPBAR */
.topbar{background:var(--tb);height:48px;padding:0 16px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.tb-left{display:flex;align-items:center;gap:10px;min-width:0}
.tb-logo{width:32px;height:32px;border-radius:8px;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;flex-shrink:0}
.tb-logo i{color:#fff;font-size:16px}
.tb-info{min-width:0}
.tb-info .t1{font-size:11px;font-weight:500;color:#e8f0f8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tb-info .t2{font-size:9px;color:#7a9ec0}
.tb-right{display:flex;align-items:center;gap:6px;flex-shrink:0}
.tb-pill{display:flex;align-items:center;gap:4px;background:rgba(255,255,255,.1);border:0.5px solid rgba(255,255,255,.2);border-radius:20px;padding:4px 10px;color:#c0d8f0;font-size:11px}
.tb-pill i{font-size:12px}
.tb-btn{display:flex;align-items:center;gap:3px;padding:4px 9px;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;color:#a0c4e0;font-size:10px;cursor:pointer;background:transparent;text-decoration:none;font-family:var(--f)}
.tb-btn:hover{background:rgba(255,255,255,.1)}
.tb-btn i{font-size:12px}

/* LAYOUT */
.app-body{display:flex;flex:1;overflow:hidden}

/* SIDEBAR */
.sidebar{width:195px;min-width:195px;background:var(--bgw);border-right:0.5px solid var(--bd);display:flex;flex-direction:column;overflow:hidden;flex-shrink:0}
.sl-hdr{padding:10px 12px 8px;border-bottom:0.5px solid #eef0f2;display:flex;align-items:center;justify-content:space-between}
.sl-hdr span{font-size:9px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.8px}
.sl-search{padding:7px 10px;border-bottom:0.5px solid #eef0f2}
.sl-search input{width:100%;background:var(--bg);border:0.5px solid var(--bd);border-radius:6px;padding:5px 8px;font-size:11px;color:var(--tx);font-family:var(--f);outline:none}
.sl-list{flex:1;overflow-y:auto;padding:4px 0}
.sl-item{display:flex;align-items:center;gap:8px;padding:7px 12px;cursor:pointer;border-left:2px solid transparent;text-decoration:none}
.sl-item:hover{background:var(--bg)}
.sl-item.active{background:var(--acb);border-left-color:var(--ac)}
.sl-item i.ico{font-size:13px;color:var(--txm);flex-shrink:0}
.sl-item.active i.ico{color:var(--ac)}
.sl-item .nm{font-size:11px;color:var(--txs);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sl-item.active .nm{color:var(--ac);font-weight:500}
.sl-item .lk{font-size:10px;color:#c0d0e0}
.sl-item.noaccess .nm{color:var(--txm)}
.sl-item.noaccess i.ico{color:#c0d0e0}

/* CENTRO */
.center{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}

/* BANNER ROTATIVO */
.banner-outer{background:var(--bgw);border-bottom:0.5px solid var(--bd);flex-shrink:0;position:relative;overflow:hidden;height:138px}
.banner-track{display:flex;transition:transform .45s ease;height:138px}
.banner-slide{min-width:100%;display:flex;flex-direction:row;overflow:hidden}
.slide-photo{width:200px;min-width:200px;height:138px;overflow:hidden;display:flex;align-items:center;justify-content:center;background:#eef0f2;flex-shrink:0}
.slide-photo img{width:100%;height:100%;object-fit:cover}
.slide-photo .ph{display:flex;flex-direction:column;align-items:center;gap:6px}
.slide-photo .ph i{font-size:28px;color:#b0c0d0}
.slide-photo .ph span{font-size:10px;color:#9aaab8}
.slide-txt{flex:1;padding:12px 14px;display:flex;flex-direction:column;min-width:0;overflow:hidden}
.slide-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}
.slide-badge{display:inline-flex;align-items:center;gap:4px;background:var(--acb);color:var(--ac);font-size:9px;font-weight:500;padding:3px 9px;border-radius:20px;text-transform:uppercase;letter-spacing:.4px}
.slide-badge i{font-size:11px}
.slide-nav{display:flex;align-items:center;gap:5px}
.slide-nav button{background:var(--bg);border:0.5px solid var(--bd);border-radius:4px;padding:2px 7px;cursor:pointer;font-size:13px;color:var(--txs);font-family:var(--f);line-height:1}
.slide-counter{font-size:10px;color:var(--txm)}
.slide-title{font-size:14px;font-weight:500;color:var(--tx);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-bottom:4px}
.slide-body{font-size:11px;color:var(--txs);line-height:1.5;flex:1;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.slide-footer{display:flex;align-items:center;justify-content:space-between;margin-top:8px}
.slide-date{font-size:10px;color:var(--txm)}
.slide-dots{display:flex;gap:5px}
.slide-dot{width:6px;height:6px;border-radius:50%;background:var(--bd);cursor:pointer;transition:background .2s;border:none;padding:0}
.slide-dot.active{background:var(--ac)}
.banner-manage{position:absolute;bottom:8px;right:12px;display:flex;align-items:center;gap:4px;background:#1c3557;color:#fff;border:none;border-radius:5px;padding:3px 9px;font-size:9px;cursor:pointer;font-family:var(--f);text-decoration:none}
.banner-manage i{font-size:11px}
.banner-empty{display:flex;align-items:center;justify-content:center;height:100%;color:var(--txm);font-size:12px;gap:8px}
.banner-empty i{font-size:18px}

/* FILE MANAGER */
.fm{flex:1;padding:12px 14px;display:flex;flex-direction:column;gap:8px;overflow:hidden;min-height:0}
.fm-hdr{display:flex;align-items:flex-start;justify-content:space-between;flex-shrink:0;gap:8px;flex-wrap:wrap}
.fm-title{display:flex;align-items:center;gap:8px;min-width:0}
.fm-title i{font-size:18px;color:var(--ac);flex-shrink:0}
.fm-title-txt{min-width:0}
.fm-title-txt h3{font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fm-path{font-size:10px;color:var(--txm);font-family:monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block;cursor:pointer;title:"Clique para copiar"}
.fm-path:hover{color:var(--ac)}
.fm-btns{display:flex;gap:5px;flex-wrap:wrap;flex-shrink:0}
.fmbtn{display:inline-flex;align-items:center;gap:4px;background:var(--bgw);border:0.5px solid var(--bds);border-radius:5px;padding:5px 10px;font-size:11px;color:var(--txs);cursor:pointer;font-family:var(--f);white-space:nowrap;text-decoration:none}
.fmbtn:hover{background:var(--bg)}
.fmbtn i{font-size:12px}
.fmbtn.prim{background:#1c3557;border-color:#1c3557;color:#fff}
.fmbtn.prim:hover{background:#244e7a}
.fmbtn.grn{background:var(--gnb);border-color:var(--gnd);color:var(--gn)}
.fmbtn.red{background:var(--rdb);border-color:var(--rdd);color:var(--rd)}
.fmbtn:disabled{opacity:.4;cursor:default}
.fm-wrap{flex:1;background:var(--bgw);border:0.5px solid var(--bd);border-radius:6px;overflow-y:auto;min-height:0}
table.fm{width:100%;border-collapse:collapse;font-size:12px}
table.fm th{background:var(--bg);padding:7px 10px;text-align:left;font-size:10px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.4px;border-bottom:0.5px solid var(--bd);position:sticky;top:0;z-index:1}
table.fm td{padding:6px 10px;border-bottom:0.5px solid #eef0f2;vertical-align:middle}
table.fm tr:last-child td{border-bottom:none}
table.fm tr:hover td{background:#fafbfc}
table.fm tr.selected td{background:var(--acb)}
.f-ico i{font-size:15px;color:#4a8ad4}
.f-ico.folder i{color:#d4931a}
.f-name{cursor:pointer;color:var(--tx);font-size:12px}
.f-name:hover{color:var(--ac);text-decoration:underline}
.f-size{color:var(--txm);text-align:right;font-family:monospace;font-size:11px}
.f-date{color:var(--txm);text-align:right;font-size:11px}
.f-acts{text-align:right;white-space:nowrap}
.fact{display:inline-flex;align-items:center;gap:2px;background:var(--bg);border:none;border-radius:4px;padding:3px 6px;font-size:10px;color:var(--txs);cursor:pointer;margin-left:2px;font-family:var(--f)}
.fact:hover{background:var(--bd)}
.fact.g{background:var(--gnb);color:var(--gn)}
.fact.r{background:var(--rdb);color:var(--rd)}
.fact i{font-size:11px}
.fm-empty{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;gap:10px;color:var(--txm);padding:40px;text-align:center}
.fm-empty i{font-size:40px}
.no-access{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;gap:12px;padding:40px;text-align:center}
.no-access i{font-size:48px;color:#c0d0e0}
.no-access h3{font-size:15px;font-weight:500}
.no-access p{font-size:12px;color:var(--txs);max-width:300px;line-height:1.5}
.no-access .na-path{font-size:11px;background:var(--bg);border:0.5px solid var(--bds);border-radius:5px;padding:4px 10px;font-family:monospace;color:var(--txm)}
.drop-zone{border:2px dashed var(--bds);border-radius:6px;padding:14px;text-align:center;font-size:11px;color:var(--txm);display:none;flex-shrink:0}
.drop-zone.active{background:var(--acb);border-color:var(--ac)}

/* SIDEBAR DIREITA */
.right-col{width:180px;min-width:180px;background:var(--bgw);border-left:0.5px solid var(--bd);overflow-y:auto;flex-shrink:0;padding:10px}
.rc{background:var(--bg);border:0.5px solid var(--bd);border-radius:8px;padding:10px;margin-bottom:10px}
.rc-title{font-size:9px;font-weight:500;color:var(--txm);text-transform:uppercase;letter-spacing:.8px;margin-bottom:8px;display:flex;align-items:center;gap:4px}
.rc-title i{font-size:12px}
.rc-row{display:flex;justify-content:space-between;align-items:center;margin-bottom:4px;gap:6px}
.rc-lbl{font-size:10px;color:var(--txm);flex-shrink:0}
.rc-val{font-size:10px;font-weight:500;text-align:right;word-break:break-word}
.dot-on{width:6px;height:6px;border-radius:50%;background:var(--gn);display:inline-block;margin-right:3px}
.notice{display:flex;gap:6px;margin-bottom:6px;padding-bottom:6px;border-bottom:0.5px solid #e8ecf0}
.notice:last-child{border-bottom:none;margin-bottom:0;padding-bottom:0}
.notice i{font-size:12px;color:#4a8ad4;flex-shrink:0;margin-top:1px}
.notice.w i{color:#c07820}
.notice.ok i{color:var(--gn)}
.notice-txt{font-size:10px;color:var(--txs);line-height:1.4}
.notice-dt{font-size:9px;color:var(--txm);margin-top:2px}
.acct-btn{display:flex;align-items:center;gap:5px;background:var(--bgw);border:0.5px solid var(--bds);border-radius:5px;padding:6px 8px;font-size:10px;color:var(--txs);cursor:pointer;width:100%;margin-bottom:5px;font-family:var(--f);text-decoration:none}
.acct-btn:hover{background:var(--bg)}
.acct-btn i{font-size:12px}

/* STATUSBAR — sempre na base */
.statusbar{background:var(--bgw);border-top:0.5px solid var(--bd);height:28px;padding:0 16px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.statusbar span{font-size:9px;color:var(--txm)}
.st-on{display:flex;align-items:center;gap:4px;font-size:9px;color:var(--gn)}

/* MODAL */
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:900;display:flex;align-items:center;justify-content:center;padding:16px}
.modal{background:var(--bgw);border-radius:12px;padding:24px;width:480px;max-width:100%;max-height:90vh;overflow-y:auto;border:0.5px solid var(--bd)}
.modal h2{font-size:15px;font-weight:500;margin-bottom:16px;display:flex;align-items:center;gap:8px}
.modal h2 i{font-size:18px;color:var(--ac)}
.modal label{display:block;font-size:11px;font-weight:500;color:var(--txs);margin:12px 0 4px}
.modal input,.modal textarea,.modal select{width:100%;border:0.5px solid var(--bds);border-radius:6px;padding:8px 10px;font-size:13px;color:var(--tx);font-family:var(--f);outline:none;background:var(--bgw)}
.modal input:focus,.modal textarea:focus{border-color:#378ADD}
.modal textarea{resize:vertical;min-height:70px}
.modal-footer{display:flex;justify-content:flex-end;gap:8px;margin-top:20px}
.modal-footer button{padding:8px 16px;border-radius:6px;font-size:12px;cursor:pointer;border:none;font-family:var(--f)}
.btn-cancel{background:var(--bg);color:var(--txs)}
.btn-ok{background:#1c3557;color:#fff}
.btn-ok:hover{background:#244e7a}
.btn-del{background:var(--rdb);color:var(--rd);border:0.5px solid var(--rdd)!important}
.admin-item{background:var(--bg);border:0.5px solid var(--bd);border-radius:6px;padding:10px;margin-bottom:8px;position:relative}
.admin-item-acts{position:absolute;top:8px;right:8px;display:flex;gap:4px}
.img-preview{width:80px;height:50px;object-fit:cover;border-radius:4px;border:0.5px solid var(--bd);margin-top:6px}
.upload-label{display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:5px 10px;font-size:11px;cursor:pointer;margin-top:6px}

/* TOAST */
#toast-container{position:fixed;bottom:36px;right:20px;z-index:9999;display:flex;flex-direction:column;gap:6px;pointer-events:none}
.toast{background:var(--bgw);border:0.5px solid var(--bd);border-radius:8px;padding:10px 14px;font-size:12px;display:flex;align-items:center;gap:8px;min-width:220px;pointer-events:auto;animation:slideIn .2s ease}
.toast.ok{border-left:2px solid var(--gn)}.toast.ok i{color:var(--gn)}
.toast.err{border-left:2px solid var(--rd)}.toast.err i{color:var(--rd)}
.toast.w{border-left:2px solid #c07820}.toast.w i{color:#c07820}
@keyframes slideIn{from{transform:translateX(20px);opacity:0}to{transform:translateX(0);opacity:1}}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--bds);border-radius:3px}
</style>
</head>
<body>
{% if not session.get('user') %}
<div class="login-wrap">
  <div class="login-box">
    <div class="login-logo">
      <div class="crest"><i class="ti ti-building-prison" aria-hidden="true"></i></div>
      <h1>Centro de Detenção Provisória<br>de Nova Independência</h1>
      <p>Sistema de Acesso a Arquivos — CDPNI</p>
    </div>
    <form method="post" action="/login">
      <label>Usuário</label>
      <input type="text" name="user" placeholder="Login do sistema" autocomplete="username" required>
      <label>Senha</label>
      <input type="password" name="pass" placeholder="Senha" autocomplete="current-password" required>
      <button type="submit" class="login-btn">Entrar</button>
    </form>
    {% if error %}<div class="login-err show">{{ error }}</div>{% endif %}
  </div>
</div>
{% else %}
<div class="topbar">
  <div class="tb-left">
    <div class="tb-logo"><i class="ti ti-building-prison" aria-hidden="true"></i></div>
    <div class="tb-info">
      <div class="t1">Centro de Detenção Provisória de Nova Independência</div>
      <div class="t2">Portal de Arquivos — CDPNI · {{ SAMBA_IP }}</div>
    </div>
  </div>
  <div class="tb-right">
    <div class="tb-pill"><i class="ti ti-user-circle" aria-hidden="true"></i>{{ session.user }}</div>
    {% if is_admin %}<a href="/admin" class="tb-btn"><i class="ti ti-settings" aria-hidden="true"></i>Admin</a>{% endif %}
    <a href="/change-pass" class="tb-btn" onclick="openChangePass(event)"><i class="ti ti-lock" aria-hidden="true"></i>Senha</a>
    <a href="/logout" class="tb-btn"><i class="ti ti-logout" aria-hidden="true"></i>Sair</a>
  </div>
</div>

<div class="app-body">
  <div class="sidebar">
    <div class="sl-hdr">
      <span>Compartilhamentos</span>
      <i class="ti ti-folders" style="font-size:13px;color:#b0c0d0" aria-hidden="true"></i>
    </div>
    <div class="sl-search">
      <input type="text" id="share-search" placeholder="Filtrar pastas..." oninput="filterShares(this.value)">
    </div>
    <div class="sl-list" id="share-list">
      {% for name, info in shares.items() %}
      <a href="/browse/{{ info.disk }}" class="sl-item {% if active_share == info.disk %}active{% endif %} {% if not info.can %}noaccess{% endif %}"
         data-name="{{ name }}" onclick="return handleShareClick(event, this, {{ 'true' if info.can else 'false' }})">
        <i class="ti {{ info.icon }} ico" aria-hidden="true"></i>
        <span class="nm">{{ name }}</span>
        {% if not info.can %}<i class="ti ti-lock lk" aria-hidden="true"></i>{% endif %}
      </a>
      {% endfor %}
    </div>
  </div>

  <div class="center">
    <!-- BANNER ROTATIVO -->
    <div class="banner-outer">
      {% if banners %}
      <div class="banner-track" id="banner-track">
        {% for b in banners %}
        <div class="banner-slide">
          <div class="slide-photo">
            {% if b.img %}
            <img src="/banner-img/{{ b.img }}" alt="{{ b.title }}">
            {% else %}
            <div class="ph"><i class="ti ti-photo" aria-hidden="true"></i><span>Sem imagem</span></div>
            {% endif %}
          </div>
          <div class="slide-txt">
            <div class="slide-top">
              <span class="slide-badge"><i class="ti ti-speakerphone" aria-hidden="true"></i>Aviso</span>
              <div class="slide-nav">
                <button onclick="prevSlide()" aria-label="Anterior">‹</button>
                <span class="slide-counter" id="slide-counter">{{ loop.index }} / {{ banners|length }}</span>
                <button onclick="nextSlide()" aria-label="Próximo">›</button>
              </div>
            </div>
            <div class="slide-title">{{ b.title }}</div>
            <div class="slide-body">{{ b.body }}</div>
            <div class="slide-footer">
              <span class="slide-date">{{ b.date }}</span>
              <div class="slide-dots">
                {% for _ in banners %}
                <button class="slide-dot {% if loop.index == 1 %}active{% endif %}"
                        onclick="goSlide({{ loop.index0 }})" aria-label="Slide {{ loop.index }}"></button>
                {% endfor %}
              </div>
            </div>
          </div>
        </div>
        {% endfor %}
      </div>
      {% else %}
      <div class="banner-empty">
        <i class="ti ti-photo" aria-hidden="true"></i>
        <span>{% if is_admin %}Clique em "Admin" para adicionar avisos{% else %}Nenhum aviso no momento{% endif %}</span>
      </div>
      {% endif %}
      {% if is_admin %}<a href="/admin?tab=banners" class="banner-manage"><i class="ti ti-edit" aria-hidden="true"></i>Gerenciar</a>{% endif %}
    </div>

    <!-- GERENCIADOR DE ARQUIVOS -->
    <div class="fm" id="fm-area">
      {% if not active_share %}
      <div class="fm-empty">
        <i class="ti ti-folder-open" aria-hidden="true"></i>
        <p>Selecione uma pasta na lista ao lado</p>
      </div>
      {% elif not has_access %}
      <div class="no-access">
        <i class="ti ti-lock-access" aria-hidden="true"></i>
        <h3>Acesso não autorizado</h3>
        <p>Você não tem permissão para acessar esta pasta. Entre em contato com o administrador do sistema.</p>
        <span class="na-path">\\{{ SAMBA_IP }}\{{ active_share }}</span>
      </div>
      {% else %}
      <div class="fm-hdr">
        <div class="fm-title">
          <i class="ti {{ active_icon }}" aria-hidden="true"></i>
          <div class="fm-title-txt">
            <h3>{{ active_label }}</h3>
            <span class="fm-path" onclick="copyPath(this)" title="Clique para copiar">\\{{ SAMBA_IP }}\{{ active_share }}{% if rel %}\{{ rel.replace('/', '\\') }}{% endif %}</span>
          </div>
        </div>
        <div class="fm-btns">
          <label class="fmbtn prim" style="cursor:pointer">
            <i class="ti ti-upload" aria-hidden="true"></i>Enviar
            <input type="file" multiple style="display:none" onchange="uploadFiles(this)">
          </label>
          <button class="fmbtn" onclick="openMkdir()"><i class="ti ti-folder-plus" aria-hidden="true"></i>Nova pasta</button>
          <button class="fmbtn grn" onclick="openExplorer()"><i class="ti ti-external-link" aria-hidden="true"></i>Abrir Explorer</button>
          <button class="fmbtn red" id="btn-delete" disabled onclick="deleteSelected()"><i class="ti ti-trash" aria-hidden="true"></i>Excluir</button>
        </div>
      </div>
      <div class="fm-wrap">
        <table class="fm">
          <thead><tr>
            <th style="width:32px"><input type="checkbox" id="sel-all" onchange="toggleAll(this)"></th>
            <th style="width:22px"></th>
            <th>Nome</th>
            <th style="width:80px;text-align:right">Tamanho</th>
            <th style="width:110px;text-align:right">Modificado</th>
            <th style="width:175px;text-align:right">Ações</th>
          </tr></thead>
          <tbody>
            {% if rel %}
            <tr>
              <td></td>
              <td><div class="f-ico folder"><i class="ti ti-corner-left-up" aria-hidden="true"></i></div></td>
              <td colspan="4">
                <a href="/browse/{{ active_share }}{% if rel.count('/') > 0 %}/{{ rel.rsplit('/', 1)[0] }}{% endif %}" class="f-name">..</a>
              </td>
            </tr>
            {% endif %}
            {% for item in items %}
            <tr data-name="{{ item.name }}">
              <td><input type="checkbox" class="row-check" onchange="updateDelete()"></td>
              <td><div class="f-ico {% if item.is_dir %}folder{% endif %}">
                <i class="ti {% if item.is_dir %}ti-folder{% else %}{{ item.icon }}{% endif %}" aria-hidden="true"></i>
              </div></td>
              <td>
                {% if item.is_dir %}
                <a href="/browse/{{ active_share }}/{{ (rel + '/' if rel else '') + item.name }}" class="f-name">{{ item.name }}</a>
                {% else %}
                <span class="f-name" onclick="downloadFile('{{ item.name }}')">{{ item.name }}</span>
                {% endif %}
              </td>
              <td class="f-size">{{ item.size_fmt }}</td>
              <td class="f-date">{{ item.date_fmt }}</td>
              <td class="f-acts">
                {% if not item.is_dir %}
                <button class="fact" onclick="downloadFile('{{ item.name }}')"><i class="ti ti-download" aria-hidden="true"></i>Baixar</button>
                {% endif %}
                <button class="fact g" onclick="openItem('{{ item.name }}', {{ 'true' if item.is_dir else 'false' }})"><i class="ti ti-external-link" aria-hidden="true"></i>Abrir</button>
                <button class="fact" onclick="openRename('{{ item.name }}')"><i class="ti ti-edit" aria-hidden="true"></i></button>
                <button class="fact r" onclick="deleteItem('{{ item.name }}')"><i class="ti ti-trash" aria-hidden="true"></i></button>
              </td>
            </tr>
            {% else %}
            {% if not rel %}
            <tr><td colspan="6"><div class="fm-empty" style="padding:24px"><i class="ti ti-folder-open" aria-hidden="true"></i><p>Pasta vazia</p></div></td></tr>
            {% endif %}
            {% endfor %}
          </tbody>
        </table>
      </div>
      <div class="drop-zone" id="drop-zone">
        <i class="ti ti-cloud-upload" style="font-size:24px;display:block;margin-bottom:6px" aria-hidden="true"></i>
        Arraste arquivos aqui para enviar
      </div>
      {% endif %}
    </div>
  </div>

  <!-- SIDEBAR DIREITA -->
  <div class="right-col">
    <div class="rc">
      <div class="rc-title"><i class="ti ti-server" aria-hidden="true"></i>Servidor</div>
      <div class="rc-row"><span class="rc-lbl">Status</span><span class="rc-val"><span class="dot-on"></span>Online</span></div>
      <div class="rc-row"><span class="rc-lbl">IP</span><span class="rc-val">{{ SAMBA_IP }}</span></div>
      <div class="rc-row"><span class="rc-lbl">RAID 5</span><span class="rc-val">Ativo</span></div>
      <div class="rc-row"><span class="rc-lbl">Espaço</span><span class="rc-val">~8 TB</span></div>
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-bell" aria-hidden="true"></i>Lembretes</div>
      {% for n in notices %}
      <div class="notice {{ n.type }}">
        <i class="ti {% if n.type == 'ok' %}ti-check{% elif n.type == 'w' %}ti-alert-triangle{% else %}ti-info-circle{% endif %}" aria-hidden="true"></i>
        <div><div class="notice-txt">{{ n.text }}</div>{% if n.date %}<div class="notice-dt">{{ n.date }}</div>{% endif %}</div>
      </div>
      {% else %}
      <div style="font-size:10px;color:var(--txm)">Nenhum lembrete</div>
      {% endfor %}
      {% if is_admin %}<a href="/admin?tab=notices" class="acct-btn" style="margin-top:8px"><i class="ti ti-edit" aria-hidden="true"></i>Editar lembretes</a>{% endif %}
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-info-circle" aria-hidden="true"></i>Informações</div>
      {% for r in right_info %}
      <div class="rc-row"><span class="rc-lbl">{{ r.label }}</span><span class="rc-val">{{ r.value }}</span></div>
      {% else %}
      <div style="font-size:10px;color:var(--txm)">Sem informações</div>
      {% endfor %}
      {% if is_admin %}<a href="/admin?tab=rightinfo" class="acct-btn" style="margin-top:8px"><i class="ti ti-edit" aria-hidden="true"></i>Editar informações</a>{% endif %}
    </div>
    <div class="rc">
      <div class="rc-title"><i class="ti ti-key" aria-hidden="true"></i>Minha conta</div>
      <button class="acct-btn" onclick="openChangePass(null)"><i class="ti ti-lock" aria-hidden="true"></i>Trocar minha senha</button>
      {% if is_admin %}<a href="/admin?tab=users" class="acct-btn"><i class="ti ti-users" aria-hidden="true"></i>Gerenciar usuários</a>{% endif %}
    </div>
  </div>
</div>

<div class="statusbar">
  <span>CDPNI — Centro de Detenção Provisória de Nova Independência</span>
  <span class="st-on"><span class="dot-on"></span>Samba ativo — {{ SAMBA_HOST }}</span>
  <span>Portal v{{ VERSION }} · Python Flask</span>
</div>
{% endif %}

<div id="toast-container"></div>

<script>
const SHARE = "{{ active_share or '' }}";
const REL   = "{{ rel or '' }}";
const SAMBA_IP = "{{ SAMBA_IP }}";

function toast(msg, type='ok', ms=3200) {
  const icons = {ok:'ti-check', err:'ti-alert-circle', w:'ti-alert-triangle'};
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.innerHTML = `<i class="ti ${icons[type]||'ti-info-circle'}"></i><span>${msg}</span>`;
  document.getElementById('toast-container').appendChild(el);
  setTimeout(() => el.remove(), ms);
}

function filterShares(q) {
  q = q.toLowerCase();
  document.querySelectorAll('.sl-item').forEach(el => {
    el.style.display = el.dataset.name.toLowerCase().includes(q) ? '' : 'none';
  });
}

function handleShareClick(e, el, canAccess) {
  if (!canAccess) {
    e.preventDefault();
    toast('Você não tem permissão para acessar esta pasta', 'err');
    return false;
  }
  return true;
}

function copyPath(el) {
  const path = '\\\\' + SAMBA_IP + '\\' + SHARE + (REL ? '\\' + REL.replace(/\//g,'\\') : '');
  navigator.clipboard.writeText(path).then(() => toast('Caminho copiado!'));
}

function toggleAll(cb) {
  document.querySelectorAll('.row-check').forEach(c => c.checked = cb.checked);
  updateDelete();
}
function updateDelete() {
  const any = [...document.querySelectorAll('.row-check')].some(c => c.checked);
  const btn = document.getElementById('btn-delete');
  if (btn) btn.disabled = !any;
}

async function uploadFiles(input) {
  for (const file of input.files) {
    toast(`Enviando ${file.name}...`, 'w');
    const fd = new FormData();
    fd.append('file', file);
    const r = await fetch(`/upload/${SHARE}/${REL}`, {method:'POST', body:fd});
    const d = await r.json();
    if (d.ok) toast(`${file.name} enviado!`, 'ok');
    else toast(d.msg || 'Falha no upload', 'err');
  }
  setTimeout(() => location.reload(), 500);
}

function downloadFile(name) {
  const path = REL ? `${REL}/${name}` : name;
  window.open(`/download/${SHARE}/${path}`, '_blank');
}

function openItem(name, isDir) {
  const rel = REL ? `${REL}\\${name}` : name;
  const path = '\\\\' + SAMBA_IP + '\\' + SHARE + '\\' + rel.replace(/\//g, '\\');
  window.location.href = 'file://' + path.replace(/\\/g, '/');
  toast('Abrindo no Explorer...', 'ok');
}

function openExplorer() {
  const path = '\\\\' + SAMBA_IP + '\\' + SHARE + (REL ? '\\' + REL.replace(/\//g,'\\') : '');
  window.location.href = 'file://' + path.replace(/\\/g, '/');
  toast('Abrindo no Explorer...', 'ok');
}

function openMkdir() {
  openModal('Nova pasta', 'ti-folder-plus',
    '<label>Nome da pasta</label><input type="text" id="mkdir-name" placeholder="Ex: Relatórios 2025">',
    async () => {
      const name = document.getElementById('mkdir-name').value.trim();
      if (!name) { toast('Informe o nome', 'err'); return false; }
      const r = await fetch(`/mkdir/${SHARE}`, {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({name, rel: REL})});
      const d = await r.json();
      if (d.ok) { toast('Pasta criada!'); location.reload(); }
      else toast(d.msg || 'Erro', 'err');
    }
  );
}

function openRename(name) {
  openModal('Renomear', 'ti-edit',
    `<label>Novo nome</label><input type="text" id="rename-val" value="${name}">`,
    async () => {
      const newname = document.getElementById('rename-val').value.trim();
      if (!newname || newname === name) return false;
      const oldpath = REL ? `${REL}/${name}` : name;
      const r = await fetch(`/rename/${SHARE}`, {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({old: oldpath, newname})});
      const d = await r.json();
      if (d.ok) { toast('Renomeado!'); location.reload(); }
      else toast(d.msg || 'Erro', 'err');
    }
  );
}

function deleteItem(name) {
  openConfirm(`Excluir "${name}"?`, 'Esta ação não pode ser desfeita.', async () => {
    const path = REL ? `${REL}/${name}` : name;
    const r = await fetch(`/delete/${SHARE}/${path}`, {method:'DELETE'});
    const d = await r.json();
    if (d.ok) { toast('Excluído!'); location.reload(); }
    else toast(d.msg || 'Erro', 'err');
  });
}

function deleteSelected() {
  const names = [...document.querySelectorAll('.row-check:checked')]
    .map(c => c.closest('tr').dataset.name);
  if (!names.length) return;
  openConfirm(`Excluir ${names.length} item(ns)?`, 'Esta ação não pode ser desfeita.', async () => {
    for (const name of names) {
      const path = REL ? `${REL}/${name}` : name;
      await fetch(`/delete/${SHARE}/${path}`, {method:'DELETE'});
    }
    toast('Excluídos!'); location.reload();
  });
}

function openChangePass(e) {
  if (e) e.preventDefault();
  openModal('Trocar senha', 'ti-lock',
    `<label>Senha atual</label><input type="password" id="cp-old" placeholder="Senha atual">
     <label>Nova senha</label><input type="password" id="cp-new" placeholder="Nova senha (mín. 4 caracteres)">
     <label>Confirmar</label><input type="password" id="cp-new2" placeholder="Repita a nova senha">`,
    async () => {
      const old_p = document.getElementById('cp-old').value;
      const new_p = document.getElementById('cp-new').value;
      const new_p2 = document.getElementById('cp-new2').value;
      if (new_p !== new_p2) { toast('Senhas não coincidem', 'err'); return false; }
      if (new_p.length < 4) { toast('Senha muito curta', 'err'); return false; }
      const r = await fetch('/change-pass', {method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({old: old_p, new: new_p})});
      const d = await r.json();
      if (d.ok) toast('Senha alterada com sucesso!');
      else { toast(d.msg || 'Erro ao alterar senha', 'err'); return false; }
    }
  );
}

// Banner rotativo
let bannerIdx = 0;
const bannerTotal = {{ banners|length }};
function goSlide(n) {
  bannerIdx = n;
  const track = document.getElementById('banner-track');
  if (track) track.style.transform = `translateX(-${n * 100}%)`;
  document.querySelectorAll('.slide-dot').forEach((d, i) => d.classList.toggle('active', i === n));
  const counter = document.getElementById('slide-counter');
  if (counter) counter.textContent = `${n + 1} / ${bannerTotal}`;
}
function nextSlide() { if (bannerTotal > 0) goSlide((bannerIdx + 1) % bannerTotal); }
function prevSlide() { if (bannerTotal > 0) goSlide((bannerIdx - 1 + bannerTotal) % bannerTotal); }
if (bannerTotal > 1) setInterval(nextSlide, 5000);

// Drag & drop
const dropZone = document.getElementById('drop-zone');
const fmWrap = document.querySelector('.fm-wrap');
if (fmWrap && dropZone) {
  fmWrap.addEventListener('dragover', e => { e.preventDefault(); dropZone.style.display='block'; dropZone.classList.add('active'); });
  dropZone.addEventListener('dragleave', () => { dropZone.classList.remove('active'); dropZone.style.display='none'; });
  dropZone.addEventListener('drop', async e => {
    e.preventDefault(); dropZone.style.display='none'; dropZone.classList.remove('active');
    const inp = {files: e.dataTransfer.files};
    await uploadFiles(inp);
  });
}

// Modais genéricos
function openModal(title, icon, body, onOk) {
  const m = document.createElement('div');
  m.className = 'modal-bg';
  m.innerHTML = `<div class="modal">
    <h2><i class="ti ti-${icon}" aria-hidden="true"></i>${title}</h2>
    <div>${body}</div>
    <div class="modal-footer">
      <button class="btn-cancel" onclick="this.closest('.modal-bg').remove()">Cancelar</button>
      <button class="btn-ok" id="modal-ok">Confirmar</button>
    </div>
  </div>`;
  document.body.appendChild(m);
  m.querySelector('#modal-ok').onclick = async () => {
    const r = await onOk();
    if (r !== false) m.remove();
  };
  setTimeout(() => m.querySelector('input,textarea')?.focus(), 50);
}
function openConfirm(title, msg, onOk) {
  const m = document.createElement('div');
  m.className = 'modal-bg';
  m.innerHTML = `<div class="modal" style="width:360px">
    <h2><i class="ti ti-alert-triangle" style="color:#c07820" aria-hidden="true"></i>${title}</h2>
    <p style="font-size:13px;color:var(--txs)">${msg}</p>
    <div class="modal-footer">
      <button class="btn-cancel" onclick="this.closest('.modal-bg').remove()">Cancelar</button>
      <button class="btn-del" id="modal-ok">Confirmar</button>
    </div>
  </div>`;
  document.body.appendChild(m);
  m.querySelector('#modal-ok').onclick = () => { m.remove(); onOk(); };
}
</script>
</body>
</html>"""

# ── Template Admin ────────────────────────────────────────────────────────
ADMIN_HTML = r"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>CDPNI — Administração</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
:root{--tb:#1c3557;--bd:#d0d7de;--bds:#b0bec8;--bg:#f4f6f8;--bgw:#fff;--tx:#1a2a3a;--txs:#4a5a6a;--txm:#7a8a9a;--ac:#1c5fad;--acb:#e8f0fb;--gn:#2a7a3a;--gnb:#e8f5ec;--rd:#a03030;--rdb:#fef0f0;--rdd:#f0b0b0}
body{background:var(--bg);min-height:100vh}
.topbar{background:var(--tb);height:48px;padding:0 20px;display:flex;align-items:center;justify-content:space-between}
.tb-brand{display:flex;align-items:center;gap:8px;color:#e8f0f8;font-size:12px;font-weight:500}
.tb-brand i{font-size:16px}
.tb-back{display:flex;align-items:center;gap:4px;padding:4px 10px;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;color:#a0c4e0;font-size:11px;text-decoration:none}
.tb-back:hover{background:rgba(255,255,255,.1)}
.tb-back i{font-size:13px}
.container{max-width:900px;margin:24px auto;padding:0 20px}
.tabs{display:flex;gap:8px;margin-bottom:20px;flex-wrap:wrap}
.tab{padding:8px 16px;border-radius:6px;font-size:12px;cursor:pointer;border:0.5px solid var(--bds);background:var(--bgw);color:var(--txs);text-decoration:none}
.tab:hover{background:var(--bg)}
.tab.active{background:#1c3557;border-color:#1c3557;color:#fff}
.section{background:var(--bgw);border:0.5px solid var(--bd);border-radius:10px;padding:20px;margin-bottom:20px}
.section-hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:16px}
.section-title{font-size:14px;font-weight:500}
.btn-add{display:inline-flex;align-items:center;gap:4px;background:#1c3557;color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;cursor:pointer}
.btn-add i{font-size:14px}
.item-card{background:var(--bg);border:0.5px solid var(--bd);border-radius:8px;padding:12px;margin-bottom:8px;position:relative}
.item-card-acts{position:absolute;top:10px;right:10px;display:flex;gap:6px}
.btn-edit{background:var(--bgw);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:4px 8px;font-size:11px;cursor:pointer}
.btn-del{background:var(--rdb);border:0.5px solid var(--rdd);color:var(--rd);border-radius:5px;padding:4px 8px;font-size:11px;cursor:pointer}
.item-img{width:90px;height:58px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-bottom:8px}
.item-title{font-size:13px;font-weight:500}
.item-body{font-size:12px;color:var(--txs);margin-top:4px}
.item-date{font-size:11px;color:var(--txm);margin-top:4px}
.user-card{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;background:var(--bg);border:0.5px solid var(--bd);border-radius:8px;margin-bottom:6px}
.user-info .u-name{font-size:13px;font-weight:500}
.user-info .u-groups{font-size:11px;color:var(--txm);margin-top:2px;max-width:500px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
form.modal-form label{display:block;font-size:12px;font-weight:500;color:var(--txs);margin:12px 0 4px}
form.modal-form input,form.modal-form textarea,form.modal-form select{width:100%;border:0.5px solid var(--bds);border-radius:6px;padding:8px 10px;font-size:13px;color:var(--tx);outline:none;background:var(--bgw)}
form.modal-form input:focus,form.modal-form textarea:focus{border-color:#378ADD}
form.modal-form textarea{resize:vertical;min-height:80px}
.form-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.btn-cancel{background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:6px;padding:8px 16px;font-size:12px;cursor:pointer}
.btn-ok{background:#1c3557;border:none;color:#fff;border-radius:6px;padding:8px 16px;font-size:12px;cursor:pointer}
.btn-ok:hover{background:#244e7a}
.upload-label{display:inline-flex;align-items:center;gap:4px;background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:6px 12px;font-size:12px;cursor:pointer;margin-top:6px}
.upload-label i{font-size:14px}
.img-preview{width:90px;height:58px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-top:8px;display:none}
.flash{padding:10px 14px;border-radius:6px;font-size:13px;margin-bottom:16px;display:flex;align-items:center;gap:8px}
.flash.ok{background:var(--gnb);color:var(--gn)}
.flash.err{background:var(--rdb);color:var(--rd)}
</style>
</head>
<body>
<div class="topbar">
  <div class="tb-brand"><i class="ti ti-building-prison" aria-hidden="true"></i>CDPNI — Administração do Portal</div>
  <a href="/" class="tb-back"><i class="ti ti-arrow-left" aria-hidden="true"></i>Voltar ao portal</a>
</div>
<div class="container">
  {% if msg %}<div class="flash {{ msg_type }}"><i class="ti ti-{{ 'check' if msg_type == 'ok' else 'alert-circle' }}" aria-hidden="true"></i>{{ msg }}</div>{% endif %}

  <div class="tabs">
    <a href="/admin?tab=banners"  class="tab {{ 'active' if tab == 'banners' }}"><i class="ti ti-speakerphone" aria-hidden="true"></i> Avisos/Banners</a>
    <a href="/admin?tab=notices"  class="tab {{ 'active' if tab == 'notices' }}"><i class="ti ti-bell" aria-hidden="true"></i> Lembretes</a>
    <a href="/admin?tab=rightinfo"class="tab {{ 'active' if tab == 'rightinfo' }}"><i class="ti ti-info-circle" aria-hidden="true"></i> Coluna Direita</a>
    <a href="/admin?tab=users"    class="tab {{ 'active' if tab == 'users' }}"><i class="ti ti-users" aria-hidden="true"></i> Usuários</a>
  </div>

  {% if tab == 'banners' %}
  <div class="section">
    <div class="section-hdr">
      <div class="section-title">Avisos e Banners rotativos</div>
      <a href="/admin/banner/new" class="btn-add"><i class="ti ti-plus" aria-hidden="true"></i>Novo aviso</a>
    </div>
    {% for b in banners %}
    <div class="item-card">
      <div class="item-card-acts">
        <a href="/admin/banner/edit/{{ loop.index0 }}" class="btn-edit"><i class="ti ti-edit" aria-hidden="true"></i>Editar</a>
        <form method="post" action="/admin/banner/delete/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover aviso?')">
          <button type="submit" class="btn-del"><i class="ti ti-trash" aria-hidden="true"></i>Remover</button>
        </form>
      </div>
      {% if b.img %}<img src="/banner-img/{{ b.img }}" class="item-img" alt="{{ b.title }}">{% endif %}
      <div class="item-title">{{ b.title }}</div>
      <div class="item-body">{{ b.body }}</div>
      {% if b.date %}<div class="item-date">{{ b.date }}</div>{% endif %}
    </div>
    {% else %}
    <p style="color:var(--txm);font-size:13px">Nenhum aviso cadastrado.</p>
    {% endfor %}
  </div>

  {% elif tab == 'notices' %}
  <div class="section">
    <div class="section-hdr">
      <div class="section-title">Lembretes (coluna direita)</div>
      <a href="/admin/notice/new" class="btn-add"><i class="ti ti-plus" aria-hidden="true"></i>Novo lembrete</a>
    </div>
    {% for n in notices %}
    <div class="item-card">
      <div class="item-card-acts">
        <a href="/admin/notice/edit/{{ loop.index0 }}" class="btn-edit"><i class="ti ti-edit" aria-hidden="true"></i>Editar</a>
        <form method="post" action="/admin/notice/delete/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover?')">
          <button type="submit" class="btn-del"><i class="ti ti-trash" aria-hidden="true"></i>Remover</button>
        </form>
      </div>
      <div class="item-title">{{ n.text }}</div>
      {% if n.date %}<div class="item-date">{{ n.date }}</div>{% endif %}
      <div style="font-size:11px;color:var(--txm);margin-top:4px">Tipo: {{ n.type or 'info' }}</div>
    </div>
    {% else %}
    <p style="color:var(--txm);font-size:13px">Nenhum lembrete cadastrado.</p>
    {% endfor %}
  </div>

  {% elif tab == 'rightinfo' %}
  <div class="section">
    <div class="section-hdr">
      <div class="section-title">Informações da coluna direita</div>
      <a href="/admin/rightinfo/new" class="btn-add"><i class="ti ti-plus" aria-hidden="true"></i>Nova informação</a>
    </div>
    {% for r in right_info %}
    <div class="item-card">
      <div class="item-card-acts">
        <a href="/admin/rightinfo/edit/{{ loop.index0 }}" class="btn-edit"><i class="ti ti-edit" aria-hidden="true"></i>Editar</a>
        <form method="post" action="/admin/rightinfo/delete/{{ loop.index0 }}" style="display:inline" onsubmit="return confirm('Remover?')">
          <button type="submit" class="btn-del"><i class="ti ti-trash" aria-hidden="true"></i>Remover</button>
        </form>
      </div>
      <div class="item-title">{{ r.label }}: <span style="font-weight:400;color:var(--txs)">{{ r.value }}</span></div>
    </div>
    {% else %}
    <p style="color:var(--txm);font-size:13px">Nenhuma informação cadastrada.</p>
    {% endfor %}
  </div>

  {% elif tab == 'users' %}
  <div class="section">
    <div class="section-hdr">
      <div class="section-title">Usuários Samba ({{ users|length }})</div>
    </div>
    {% for u in users %}
    <div class="user-card">
      <div class="user-info">
        <div class="u-name">{{ u.name }}</div>
        <div class="u-groups">{{ u.groups }}</div>
      </div>
      <a href="/admin/user-pass/{{ u.name }}" class="btn-edit"><i class="ti ti-key" aria-hidden="true"></i>Resetar senha</a>
    </div>
    {% endfor %}
  </div>
  {% endif %}
</div>
</body>
</html>"""

FORM_HTML = r"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"><title>CDPNI — Admin</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
:root{--tb:#1c3557;--bd:#d0d7de;--bds:#b0bec8;--bg:#f4f6f8;--bgw:#fff;--tx:#1a2a3a;--txs:#4a5a6a;--txm:#7a8a9a;--rd:#a03030;--rdb:#fef0f0;--rdd:#f0b0b0}
body{background:var(--bg);min-height:100vh}
.topbar{background:var(--tb);height:48px;padding:0 20px;display:flex;align-items:center;justify-content:space-between}
.tb-brand{color:#e8f0f8;font-size:12px;font-weight:500;display:flex;align-items:center;gap:8px}
.tb-brand i{font-size:16px}
.tb-back{display:flex;align-items:center;gap:4px;padding:4px 10px;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;color:#a0c4e0;font-size:11px;text-decoration:none}
.container{max-width:600px;margin:32px auto;padding:0 20px}
.form-card{background:var(--bgw);border:0.5px solid var(--bd);border-radius:10px;padding:24px}
.form-title{font-size:16px;font-weight:500;margin-bottom:20px;display:flex;align-items:center;gap:8px}
.form-title i{font-size:20px;color:#1c5fad}
label{display:block;font-size:12px;font-weight:500;color:var(--txs);margin:14px 0 4px}
input,textarea,select{width:100%;border:0.5px solid var(--bds);border-radius:6px;padding:9px 11px;font-size:13px;color:var(--tx);outline:none;background:var(--bgw)}
input:focus,textarea:focus{border-color:#378ADD;box-shadow:0 0 0 3px rgba(55,138,221,.1)}
textarea{resize:vertical;min-height:80px}
.upload-lbl{display:inline-flex;align-items:center;gap:5px;background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:5px;padding:7px 14px;font-size:12px;cursor:pointer;margin-top:6px}
.img-cur{width:120px;height:75px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-top:8px;display:block}
.img-pre{width:120px;height:75px;object-fit:cover;border-radius:6px;border:0.5px solid var(--bd);margin-top:8px;display:none}
.form-acts{display:flex;justify-content:flex-end;gap:8px;margin-top:20px}
.btn-cancel{background:var(--bg);border:0.5px solid var(--bds);color:var(--txs);border-radius:6px;padding:9px 18px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center}
.btn-save{background:#1c3557;border:none;color:#fff;border-radius:6px;padding:9px 18px;font-size:13px;cursor:pointer}
.btn-save:hover{background:#244e7a}
</style>
</head>
<body>
<div class="topbar">
  <div class="tb-brand"><i class="ti ti-settings" aria-hidden="true"></i>CDPNI — Administração</div>
  <a href="/admin?tab={{ back_tab }}" class="tb-back"><i class="ti ti-arrow-left" aria-hidden="true"></i>Voltar</a>
</div>
<div class="container">
  <div class="form-card">
    <div class="form-title"><i class="ti {{ form_icon }}" aria-hidden="true"></i>{{ form_title }}</div>
    <form method="post" enctype="multipart/form-data">
      {{ form_body|safe }}
      <div class="form-acts">
        <a href="/admin?tab={{ back_tab }}" class="btn-cancel">Cancelar</a>
        <button type="submit" class="btn-save">Salvar</button>
      </div>
    </form>
  </div>
</div>
<script>
function previewImg(input) {
  const file = input.files[0]; if (!file) return;
  const reader = new FileReader();
  reader.onload = e => { const p = document.querySelector('.img-pre'); if(p){p.src=e.target.result;p.style.display='block';} };
  reader.readAsDataURL(file);
}
</script>
</body>
</html>"""

# ── Rotas ─────────────────────────────────────────────────────────────────

def render_portal(**kwargs):
    d = load_data()
    user = session.get("user", "")
    shares_info = {}
    for name, (disk, group, icon) in SHARES.items():
        shares_info[name] = {
            "disk": disk, "icon": icon,
            "can": user in ROOT_USERS or group in get_user_groups(user)
        }
    return render_template_string(HTML,
        SAMBA_IP=SAMBA_IP, SAMBA_HOST=SAMBA_HOST, VERSION=VERSION,
        shares=shares_info, is_admin=is_admin(),
        banners=d["banners"], notices=d["notices"], right_info=d["right_info"],
        active_share=None, rel="", has_access=False,
        active_label="", active_icon="ti-folder-open", items=[],
        **kwargs)

@app.route("/")
@auth_required
def index():
    return render_portal()

@app.route("/login", methods=["GET","POST"])
def login():
    error = ""
    if request.method == "POST":
        user = request.form.get("user","").strip()
        passwd = request.form.get("pass","")
        if user and passwd:
            p = pam.pam()
            if p.authenticate(user, passwd, service="cdpni-portal"):
                session["user"] = user
                return redirect(url_for("index"))
            else:
                # Fallback serviço padrão
                p2 = pam.pam()
                if p2.authenticate(user, passwd):
                    session["user"] = user
                    return redirect(url_for("index"))
                else:
                    error = "Usuário ou senha inválidos"
        else:
            error = "Preencha todos os campos"
    return render_template_string(HTML,
        SAMBA_IP=SAMBA_IP, SAMBA_HOST=SAMBA_HOST, VERSION=VERSION,
        shares={}, is_admin=False, banners=[], notices=[], right_info=[],
        active_share=None, rel="", has_access=False,
        active_label="", active_icon="ti-folder", items=[], error=error)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/browse/<path:path>")
@auth_required
def browse(path):
    parts = path.split("/", 1)
    disk_name = parts[0]
    rel = parts[1] if len(parts) > 1 else ""
    # Encontrar nome amigável e ícone
    label = disk_name; icon = "ti-folder-open"
    for name, (disk, group, ic) in SHARES.items():
        if disk == disk_name:
            label = name; icon = ic; break
    user = session["user"]
    has_access = user in ROOT_USERS or any(
        info[1] in get_user_groups(user)
        for n, info in SHARES.items() if info[0] == disk_name
    )
    items = []
    if has_access:
        try:
            base, full = safe_path(label, rel)
            if full.is_dir():
                for entry in sorted(full.iterdir(), key=lambda e: (not e.is_dir(), e.name.lower())):
                    ext = entry.suffix.lstrip(".").lower() if entry.is_file() else ""
                    items.append(type("Item", (), {
                        "name": entry.name,
                        "is_dir": entry.is_dir(),
                        "size_fmt": fmt_size(entry.stat().st_size) if entry.is_file() else "—",
                        "date_fmt": fmt_date(entry.stat().st_mtime),
                        "icon": file_icon(ext),
                    })())
        except Exception:
            pass
    d = load_data()
    shares_info = {}
    for name, (disk, group, ic2) in SHARES.items():
        shares_info[name] = {
            "disk": disk, "icon": ic2,
            "can": user in ROOT_USERS or group in get_user_groups(user)
        }
    return render_template_string(HTML,
        SAMBA_IP=SAMBA_IP, SAMBA_HOST=SAMBA_HOST, VERSION=VERSION,
        shares=shares_info, is_admin=is_admin(),
        banners=d["banners"], notices=d["notices"], right_info=d["right_info"],
        active_share=disk_name, rel=rel, has_access=has_access,
        active_label=label, active_icon=icon, items=items, error="")

@app.route("/download/<path:path>")
@auth_required
def download(path):
    parts = path.split("/", 1)
    disk = parts[0]; rel = parts[1] if len(parts) > 1 else ""
    label = next((n for n,(d,_,__) in SHARES.items() if d==disk), disk)
    user = session["user"]
    if not (user in ROOT_USERS or any(
        info[1] in get_user_groups(user) for n,info in SHARES.items() if info[0]==disk)):
        abort(403)
    try:
        _, full = safe_path(label, rel)
        if not full.is_file(): abort(404)
        return send_file(full, as_attachment=True, download_name=full.name)
    except Exception:
        abort(404)

@app.route("/upload/<disk>/<path:rel>", methods=["POST"])
@app.route("/upload/<disk>", methods=["POST"])
@auth_required
def upload(disk, rel=""):
    label = next((n for n,(d,_,__) in SHARES.items() if d==disk), disk)
    user = session["user"]
    if not (user in ROOT_USERS or any(
        info[1] in get_user_groups(user) for n,info in SHARES.items() if info[0]==disk)):
        return jsonify(ok=False, msg="Sem permissão")
    f = request.files.get("file")
    if not f: return jsonify(ok=False, msg="Sem arquivo")
    try:
        base, full_dir = safe_path(label, rel)
        dest = full_dir / f.filename
        f.save(dest)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/mkdir/<disk>", methods=["POST"])
@auth_required
def mkdir(disk):
    data = request.json or {}
    label = next((n for n,(d,_,__) in SHARES.items() if d==disk), disk)
    user = session["user"]
    if not (user in ROOT_USERS or any(
        info[1] in get_user_groups(user) for n,info in SHARES.items() if info[0]==disk)):
        return jsonify(ok=False, msg="Sem permissão")
    try:
        base, full_dir = safe_path(label, data.get("rel",""))
        new_dir = full_dir / data.get("name","")
        new_dir.mkdir(parents=True, exist_ok=False)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/rename/<disk>", methods=["POST"])
@auth_required
def rename(disk):
    data = request.json or {}
    label = next((n for n,(d,_,__) in SHARES.items() if d==disk), disk)
    user = session["user"]
    if not (user in ROOT_USERS or any(
        info[1] in get_user_groups(user) for n,info in SHARES.items() if info[0]==disk)):
        return jsonify(ok=False, msg="Sem permissão")
    try:
        base, old_full = safe_path(label, data.get("old",""))
        new_full = old_full.parent / data.get("newname","")
        old_full.rename(new_full)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/delete/<path:path>", methods=["DELETE"])
@auth_required
def delete(path):
    parts = path.split("/", 1)
    disk = parts[0]; rel = parts[1] if len(parts) > 1 else ""
    label = next((n for n,(d,_,__) in SHARES.items() if d==disk), disk)
    user = session["user"]
    if not (user in ROOT_USERS or any(
        info[1] in get_user_groups(user) for n,info in SHARES.items() if info[0]==disk)):
        return jsonify(ok=False, msg="Sem permissão")
    try:
        base, full = safe_path(label, rel)
        if full.is_dir(): shutil.rmtree(full)
        else: full.unlink()
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, msg=str(e))

@app.route("/change-pass", methods=["POST"])
@auth_required
def change_pass():
    data = request.json or {}
    user = session["user"]
    old_p = data.get("old","")
    new_p = data.get("new","")
    if len(new_p) < 4:
        return jsonify(ok=False, msg="Senha muito curta")
    # Trocar senha Samba
    try:
        cmd = f'printf "%s\n%s\n%s\n" {old_p!r} {new_p!r} {new_p!r} | smbpasswd -s -U {user} 2>&1'
        out = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT)
    except Exception:
        out = ""
    if "Changed password" in out or "Password changed" in out:
        # Sincronizar Linux
        subprocess.run(f"echo '{user}:{new_p}' | sudo chpasswd", shell=True)
        return jsonify(ok=True)
    # Admin pode forçar
    if is_admin():
        try:
            cmd2 = f'printf "%s\n%s\n" {new_p!r} {new_p!r} | sudo smbpasswd -s {user} 2>&1'
            out2 = subprocess.check_output(cmd2, shell=True, text=True)
            if "Changed password" in out2 or "Password changed" in out2:
                subprocess.run(f"echo '{user}:{new_p}' | sudo chpasswd", shell=True)
                return jsonify(ok=True)
        except Exception:
            pass
    return jsonify(ok=False, msg="Senha atual incorreta")

@app.route("/banner-img/<filename>")
@auth_required
def banner_img(filename):
    path = UPLOAD_DIR / filename
    if not path.exists(): abort(404)
    mime = mimetypes.guess_type(str(path))[0] or "image/jpeg"
    return send_file(path, mimetype=mime)

# ── Admin ──────────────────────────────────────────────────────────────────
def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not is_admin(): return redirect(url_for("index"))
        return f(*args, **kwargs)
    return decorated

@app.route("/admin")
@auth_required
@admin_required
def admin():
    d = load_data()
    tab = request.args.get("tab","banners")
    msg = request.args.get("msg","")
    msg_type = request.args.get("msg_type","ok")
    users = []
    if tab == "users":
        try:
            raw = subprocess.check_output(["sudo","pdbedit","-L"], text=True, stderr=subprocess.DEVNULL)
            for line in raw.splitlines():
                if ":" in line:
                    name = line.split(":")[0]
                    groups = " ".join(get_user_groups(name))
                    users.append({"name": name, "groups": groups})
        except Exception:
            pass
    return render_template_string(ADMIN_HTML,
        tab=tab, msg=msg, msg_type=msg_type,
        banners=d["banners"], notices=d["notices"],
        right_info=d["right_info"], users=users)

def admin_form_route(tab, icon, title, form_body_fn, save_fn, back_tab):
    """Helper para gerar rotas de formulário do admin."""
    pass

@app.route("/admin/banner/new", methods=["GET","POST"])
@auth_required
@admin_required
def banner_new():
    if request.method == "POST":
        d = load_data()
        img = ""
        if "img" in request.files and request.files["img"].filename:
            f = request.files["img"]
            ext = Path(f.filename).suffix
            fname = f"banner_{os.urandom(6).hex()}{ext}"
            f.save(UPLOAD_DIR / fname)
            img = fname
        d["banners"].append({
            "title": request.form.get("title",""),
            "body":  request.form.get("body",""),
            "date":  request.form.get("date",""),
            "img":   img
        })
        save_data(d)
        return redirect("/admin?tab=banners&msg=Aviso+adicionado&msg_type=ok")
    form = """
    <label>Título</label><input type="text" name="title" placeholder="Título do aviso" required>
    <label>Texto</label><textarea name="body" placeholder="Conteúdo do aviso"></textarea>
    <label>Data</label><input type="text" name="date" placeholder="Ex: 03/06/2025">
    <label>Imagem (opcional)</label>
    <label class="upload-lbl"><i class="ti ti-photo" aria-hidden="true"></i>Selecionar imagem<input type="file" name="img" accept="image/*" style="display:none" onchange="previewImg(this)"></label>
    <img class="img-pre" alt="Preview">
    """
    return render_template_string(FORM_HTML, back_tab="banners",
        form_icon="ti-speakerphone", form_title="Novo aviso", form_body=form)

@app.route("/admin/banner/edit/<int:idx>", methods=["GET","POST"])
@auth_required
@admin_required
def banner_edit(idx):
    d = load_data()
    if idx >= len(d["banners"]): return redirect("/admin?tab=banners")
    b = d["banners"][idx]
    if request.method == "POST":
        b["title"] = request.form.get("title","")
        b["body"]  = request.form.get("body","")
        b["date"]  = request.form.get("date","")
        if "img" in request.files and request.files["img"].filename:
            f = request.files["img"]
            ext = Path(f.filename).suffix
            fname = f"banner_{os.urandom(6).hex()}{ext}"
            f.save(UPLOAD_DIR / fname)
            b["img"] = fname
        save_data(d)
        return redirect("/admin?tab=banners&msg=Aviso+atualizado&msg_type=ok")
    cur_img = f'<img src="/banner-img/{b["img"]}" class="img-cur" alt="Imagem atual">' if b.get("img") else ""
    form = f"""
    <label>Título</label><input type="text" name="title" value="{b['title']}" required>
    <label>Texto</label><textarea name="body">{b['body']}</textarea>
    <label>Data</label><input type="text" name="date" value="{b['date']}">
    <label>Nova imagem (opcional — deixe vazio para manter)</label>
    {cur_img}
    <label class="upload-lbl"><i class="ti ti-photo" aria-hidden="true"></i>Selecionar imagem<input type="file" name="img" accept="image/*" style="display:none" onchange="previewImg(this)"></label>
    <img class="img-pre" alt="Preview">
    """
    return render_template_string(FORM_HTML, back_tab="banners",
        form_icon="ti-edit", form_title="Editar aviso", form_body=form)

@app.route("/admin/banner/delete/<int:idx>", methods=["POST"])
@auth_required
@admin_required
def banner_delete(idx):
    d = load_data()
    if 0 <= idx < len(d["banners"]): d["banners"].pop(idx)
    save_data(d)
    return redirect("/admin?tab=banners&msg=Aviso+removido&msg_type=ok")

@app.route("/admin/notice/new", methods=["GET","POST"])
@auth_required
@admin_required
def notice_new():
    if request.method == "POST":
        d = load_data()
        d["notices"].append({"text":request.form.get("text",""),
            "date":request.form.get("date",""),"type":request.form.get("type","")})
        save_data(d)
        return redirect("/admin?tab=notices&msg=Lembrete+adicionado&msg_type=ok")
    form = """
    <label>Texto</label><input type="text" name="text" placeholder="Texto do lembrete" required>
    <label>Data</label><input type="text" name="date" placeholder="Ex: 30/06/2025">
    <label>Tipo</label>
    <select name="type"><option value="">Informação</option><option value="ok">Concluído</option><option value="w">Alerta</option></select>
    """
    return render_template_string(FORM_HTML, back_tab="notices",
        form_icon="ti-bell", form_title="Novo lembrete", form_body=form)

@app.route("/admin/notice/edit/<int:idx>", methods=["GET","POST"])
@auth_required
@admin_required
def notice_edit(idx):
    d = load_data()
    if idx >= len(d["notices"]): return redirect("/admin?tab=notices")
    n = d["notices"][idx]
    if request.method == "POST":
        n["text"]=request.form.get("text",""); n["date"]=request.form.get("date",""); n["type"]=request.form.get("type","")
        save_data(d); return redirect("/admin?tab=notices&msg=Lembrete+atualizado&msg_type=ok")
    form = f"""
    <label>Texto</label><input type="text" name="text" value="{n['text']}" required>
    <label>Data</label><input type="text" name="date" value="{n['date']}">
    <label>Tipo</label>
    <select name="type"><option value="" {'selected' if not n['type'] else ''}>Informação</option>
    <option value="ok" {'selected' if n['type']=='ok' else ''}>Concluído</option>
    <option value="w" {'selected' if n['type']=='w' else ''}>Alerta</option></select>
    """
    return render_template_string(FORM_HTML, back_tab="notices",
        form_icon="ti-edit", form_title="Editar lembrete", form_body=form)

@app.route("/admin/notice/delete/<int:idx>", methods=["POST"])
@auth_required
@admin_required
def notice_delete(idx):
    d = load_data()
    if 0 <= idx < len(d["notices"]): d["notices"].pop(idx)
    save_data(d); return redirect("/admin?tab=notices&msg=Lembrete+removido&msg_type=ok")

@app.route("/admin/rightinfo/new", methods=["GET","POST"])
@auth_required
@admin_required
def rightinfo_new():
    if request.method == "POST":
        d = load_data()
        d["right_info"].append({"label":request.form.get("label",""),"value":request.form.get("value","")})
        save_data(d); return redirect("/admin?tab=rightinfo&msg=Informação+adicionada&msg_type=ok")
    form = """
    <label>Rótulo</label><input type="text" name="label" placeholder="Ex: Responsável TI" required>
    <label>Valor</label><input type="text" name="value" placeholder="Ex: jpfagiani" required>
    """
    return render_template_string(FORM_HTML, back_tab="rightinfo",
        form_icon="ti-info-circle", form_title="Nova informação", form_body=form)

@app.route("/admin/rightinfo/edit/<int:idx>", methods=["GET","POST"])
@auth_required
@admin_required
def rightinfo_edit(idx):
    d = load_data()
    if idx >= len(d["right_info"]): return redirect("/admin?tab=rightinfo")
    r = d["right_info"][idx]
    if request.method == "POST":
        r["label"]=request.form.get("label",""); r["value"]=request.form.get("value","")
        save_data(d); return redirect("/admin?tab=rightinfo&msg=Informação+atualizada&msg_type=ok")
    form = f"""
    <label>Rótulo</label><input type="text" name="label" value="{r['label']}" required>
    <label>Valor</label><input type="text" name="value" value="{r['value']}" required>
    """
    return render_template_string(FORM_HTML, back_tab="rightinfo",
        form_icon="ti-edit", form_title="Editar informação", form_body=form)

@app.route("/admin/rightinfo/delete/<int:idx>", methods=["POST"])
@auth_required
@admin_required
def rightinfo_delete(idx):
    d = load_data()
    if 0 <= idx < len(d["right_info"]): d["right_info"].pop(idx)
    save_data(d); return redirect("/admin?tab=rightinfo&msg=Informação+removida&msg_type=ok")

@app.route("/admin/user-pass/<username>", methods=["GET","POST"])
@auth_required
@admin_required
def user_pass(username):
    msg = ""
    if request.method == "POST":
        new_p = request.form.get("new_pass","")
        if len(new_p) < 4:
            msg = "Senha muito curta"
        else:
            try:
                cmd = f'printf "%s\n%s\n" {new_p!r} {new_p!r} | sudo smbpasswd -s {username}'
                subprocess.run(cmd, shell=True, check=True)
                subprocess.run(f"echo '{username}:{new_p}' | sudo chpasswd", shell=True)
                return redirect(f"/admin?tab=users&msg=Senha+de+{username}+alterada&msg_type=ok")
            except Exception as e:
                msg = f"Erro: {e}"
    form = f"""
    <p style="font-size:13px;color:#4a5a6a;margin-bottom:4px">Usuário: <strong>{username}</strong></p>
    {'<p style="color:#a03030;font-size:12px;margin-bottom:8px">'+msg+'</p>' if msg else ''}
    <label>Nova senha</label><input type="password" name="new_pass" placeholder="Nova senha (mín. 4 caracteres)" required>
    <label>Confirmar</label><input type="password" name="confirm_pass" placeholder="Repita a senha" required>
    """
    return render_template_string(FORM_HTML, back_tab="users",
        form_icon="ti-key", form_title=f"Resetar senha — {username}", form_body=form)

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
PYEOF

log "app.py criado ($(wc -l < "${APP_DIR}/app.py") linhas)"

# ===========================================================================
# 9. DADOS INICIAIS
# ===========================================================================
header "9. Dados iniciais"
if [[ ! -f "${DATA_DIR}/portal_data.json" ]]; then
cat > "${DATA_DIR}/portal_data.json" << 'JSONEOF'
{
  "banners": [
    {
      "title": "Bem-vindo ao Portal CDPNI",
      "body": "Acesse seus compartilhamentos diretamente pelo navegador. Selecione uma pasta na lista à esquerda. Pastas com cadeado requerem autorização do administrador.",
      "date": "",
      "img": ""
    }
  ],
  "notices": [
    { "text": "Sistema de arquivos operacional.", "date": "", "type": "ok" }
  ],
  "right_info": [
    { "label": "Suporte TI", "value": "jpfagiani" },
    { "label": "Servidor",   "value": "CDPNI" },
    { "label": "RAID 5",     "value": "5 × 2TB (~8TB)" }
  ]
}
JSONEOF
    log "portal_data.json criado"
else
    warn "portal_data.json já existe — mantido"
fi

# ===========================================================================
# 10. PERMISSÕES
# ===========================================================================
header "10. Permissões"
chown -R cdpni:cdpni "${APP_DIR}"
chmod -R 750 "${APP_DIR}"
chmod 770 "${DATA_DIR}" "${UPLOAD_DIR}"
[[ -f "${DATA_DIR}/portal_data.json" ]] && chmod 660 "${DATA_DIR}/portal_data.json"
[[ -d "${SAMBA_ROOT}" ]] && {
    # Pastas Samba têm 777 — cdpni precisa acessar
    command -v setfacl &>/dev/null && setfacl -R -m u:cdpni:rwx "${SAMBA_ROOT}" 2>/dev/null || chmod -R o+rwx "${SAMBA_ROOT}" 2>/dev/null ||
        warn "Não foi possível definir ACL nas pastas Samba — verifique manualmente"
    log "Permissões Samba OK"
} || warn "SAMBA_ROOT não encontrado: ${SAMBA_ROOT}"

# ===========================================================================
# 11. SYSTEMD SERVICE
# ===========================================================================
header "11. Serviço systemd"
cat > "/etc/systemd/system/${SERVICE}.service" << SVCEOF
[Unit]
Description=CDPNI Portal de Arquivos — Flask
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${APP_DIR}
ExecStart=${VENV}/bin/python ${APP_DIR}/app.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "${SERVICE}" && log "Serviço habilitado" || warn "Falha ao habilitar serviço"
systemctl restart "${SERVICE}" 2>/dev/null || true
sleep 3

if systemctl is-active "${SERVICE}" &>/dev/null; then
    log "Portal Flask ativo: http://${SAMBA_IP}:${PORT}"
else
    warn "Portal nao iniciou — verificando..."
    journalctl -u "${SERVICE}" --no-pager -n 10 2>/dev/null | tail -8 || true
    systemctl restart "${SERVICE}" 2>/dev/null || true
    sleep 2
    systemctl is-active "${SERVICE}" &>/dev/null         && log "Portal ativo (2a tentativa)"         || warn "Portal inativo — execute: journalctl -u ${SERVICE} -f"
fi&& log "Serviço iniciado"
sleep 2
systemctl is-active "${SERVICE}" && log "Serviço rodando OK" || {
    warn "Serviço com problema — verificando logs..."
    journalctl -u "${SERVICE}" --no-pager -n 20
}

# ===========================================================================
# 12. NGINX — proxy reverso
# ===========================================================================
header "12. Nginx"

# Portal de arquivos — 80/443 → Flask 5000
cat > /etc/nginx/sites-available/cdpni-portal << NGINXEOF
server {
    listen 80;
    server_name ${SAMBA_IP} ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${SAMBA_IP} ${DOMAIN};
    ssl_certificate     ${SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    client_max_body_size 512M;
    client_body_timeout  300s;
    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINXEOF

# Painel admin Samba — porta 8443 (sem mudança)
cat > /etc/nginx/sites-available/samba-panel << NGINXEOF
server {
    listen 8443 ssl;
    server_name ${SAMBA_IP} ${DOMAIN};
    ssl_certificate     ${SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    root  ${PANEL_DIR}/public;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
    location ~ /\.                   { deny all; }
    location ~* \.(sh|conf|log|key)$ { deny all; }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/cdpni-portal /etc/nginx/sites-enabled/cdpni-portal
ln -sf /etc/nginx/sites-available/samba-panel  /etc/nginx/sites-enabled/samba-panel

nginx -t && systemctl reload nginx && log "Nginx recarregado" || error "Erro no Nginx"

# ===========================================================================
# 13. FIREWALL
# ===========================================================================
header "13. Firewall"
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp 443/tcp 8443/tcp 2>/dev/null
    log "UFW: 80, 443, 8443 liberadas"
fi

# ===========================================================================
# 14. SINCRONIZAR SENHAS
# ===========================================================================
header "14. Senhas"
warn "IMPORTANTE: para cada usuário, sincronize as senhas Linux e Samba:"
echo ""
echo "  smbpasswd -a jpfagiani        # define/reseta senha Samba"
echo "  echo 'jpfagiani:SENHA' | chpasswd  # sincroniza senha Linux"
echo ""

# ===========================================================================
# RESUMO
# ===========================================================================
header "INSTALAÇÃO CONCLUÍDA"
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐"
echo -e "│  Portal de arquivos  →  https://${SAMBA_IP}              │"
echo -e "│  Painel admin Samba  →  https://${SAMBA_IP}:8443         │"
echo -e "├─────────────────────────────────────────────────────────────┤"
echo -e "│  Stack: Python 3 + Flask + PAM nativo                        │"
echo -e "│  Sem smbclient — autenticação direta via PAM Linux         │"
echo -e "│  Serviço: ${SERVICE} (systemd)                 │"
echo -e "├─────────────────────────────────────────────────────────────┤"
echo -e "│  Próximos passos:                                           │"
echo -e "│  1. Sincronize senhas (Linux = Samba):                      │"
echo -e "│     smbpasswd -a jpfagiani                                  │"
echo -e "│     echo 'jpfagiani:SENHA' | chpasswd                       │"
echo -e "│  2. Acesse https://${SAMBA_IP}                          │"
echo -e "│  3. Login: jpfagiani / sua senha                            │"
echo -e "│  4. Clique 'Admin' para gerenciar avisos e banners          │"
echo -e "└─────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}Para verificar logs do portal:${NC}"
echo -e "  journalctl -u ${SERVICE} -f"
echo ""