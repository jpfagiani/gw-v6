#!/bin/bash
# =============================================================================
# CDPNI — Painel Web de Administração (Flask — porta 5000)
# Instala e configura o painel web do gateway separadamente
# Execute como root: sudo bash gateway-panel.sh
# Pré-requisito: gateway já instalado (gw-v6.sh executado antes)
# =============================================================================
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "${GRN}[OK]${NC}   $*"; }
err()     { echo -e "${RED}[ERRO]${NC} $*" >&2; }
warn()    { echo -e "${YLW}[WARN]${NC} $*"; }
info()    { echo -e "${CYN}[INFO]${NC} $*"; }
hdr()     {
    echo -e "\n${BLD}${CYN}══════════════════════════════════════════════${NC}"
    echo -e "${BLD}${CYN}  $*${NC}"
    echo -e "${BLD}${CYN}══════════════════════════════════════════════${NC}"
}

[[ $EUID -ne 0 ]] && { err "Execute como root: sudo bash $0"; exit 1; }

GW_CONF="/etc/gateway"
LIST_DIR="$GW_CONF/lists"

# Carregar configuração do gateway (gerada pelo gw-v6.sh)
if [[ ! -f "$GW_CONF/config" ]]; then
    err "Configuração do gateway não encontrada em $GW_CONF/config"
    err "Execute primeiro: sudo bash gw-v6.sh"
    exit 1
fi
# shellcheck source=/dev/null
source "$GW_CONF/config"

# Validar variáveis essenciais
for var in LAN_IP NET_INT; do
    [[ -z "${!var}" ]] && { err "Variável $var não definida em $GW_CONF/config"; exit 1; }
done

hdr "PAINEL WEB — CDPNI Gateway v1.0"
info "LAN : $LAN_IP | NET: $NET_INT"
info "Início: $(date '+%d/%m/%Y %H:%M:%S')"


configure_panel() {
    local PANEL_DIR="/opt/gateway-panel"
    local VENV="${PANEL_DIR}/venv"
    local SERVICE="gateway-panel"

    # Dependências Python
    local PY_VER
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3.13")
    apt-get install -y python3 python3-pip python3-pam "python3${PY_VER}-venv" 2>/dev/null \
        || apt-get install -y python3 python3-pip python3-pam python3.13-venv 2>/dev/null || true

    # PAM
    local SHADOW_GRP=""
    for g in shadow _shadow; do
        getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }
    done
    [[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null || true; SHADOW_GRP="shadow"; }
    chmod g+r /etc/shadow 2>/dev/null || true
    chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
    cat > /etc/pam.d/gateway-panel << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF
    ok "PAM configurado"

    # Virtualenv
    mkdir -p "${PANEL_DIR}"
    if [[ -d "${VENV}" ]]; then
        rm -rf "${VENV}"
    fi
    python3 -m venv --system-site-packages "${VENV}" 2>/dev/null \
        || python3 -m venv "${VENV}" || { soft_err "Falha ao criar venv"; return 1; }

    "${VENV}/bin/pip" install --quiet flask 2>/dev/null || true
    "${VENV}/bin/pip" install --quiet python-pam 2>/dev/null || true

    # Verificar PAM no venv
    "${VENV}/bin/python3" -c "import pam" 2>/dev/null && ok "pam OK no venv" || {
        warn "pam não encontrado no venv — copiando do sistema..."
        local PAM_FILE SITE_PKG
        PAM_FILE=$(python3 -c "import pam; print(pam.__file__)" 2>/dev/null || true)
        SITE_PKG=$("${VENV}/bin/python3" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
        if [[ -n "$PAM_FILE" && -n "$SITE_PKG" ]]; then
            cp "$PAM_FILE" "$SITE_PKG/" 2>/dev/null || true
            local PAM_SO
            PAM_SO=$(find /usr/lib/python3 -name "_pam*.so" 2>/dev/null | head -1)
            [[ -n "$PAM_SO" ]] && cp "$PAM_SO" "$SITE_PKG/" 2>/dev/null || true
        fi
        "${VENV}/bin/python3" -c "import pam" 2>/dev/null \
            && ok "pam OK após cópia" \
            || warn "pam indisponível — autenticação usará fallback"
    }

    # Chave secreta persistente
    local SECRET_FILE="${GW_CONF}/panel_secret"
    [[ ! -f "${SECRET_FILE}" ]] && {
        python3 -c "import os; open('${SECRET_FILE}','wb').write(os.urandom(64))"
        chmod 600 "${SECRET_FILE}"
    }

    # Usuários permitidos no painel
    local ALLOWED_USERS='{"root", "jpfagiani", "rcborges", "sambadmin", "cpd", "supervisao"}'

    # app.py
    cat > "${PANEL_DIR}/app.py" << 'PYEOF'
#!/usr/bin/env python3
"""Gateway CDPNI — Painel v1.0"""
import os, re, subprocess, json
from functools import wraps
from pathlib import Path
from flask import Flask, request, session, redirect, url_for, render_template_string, jsonify

app = Flask(__name__)
# Chave secreta persistente (não muda ao reiniciar o serviço)
_key_file = Path("/etc/gateway/panel_secret")
if _key_file.exists():
    app.secret_key = _key_file.read_bytes()
else:
    _key = os.urandom(64)
    _key_file.write_bytes(_key)
    _key_file.chmod(0o600)
    app.secret_key = _key

app.config["PERMANENT_SESSION_LIFETIME"] = 28800  # 8 horas
app.config["SESSION_COOKIE_HTTPONLY"]    = True    # JS não acessa o cookie
app.config["SESSION_COOKIE_SAMESITE"]   = "Lax"   # Proteção CSRF

GW_CONF  = Path("/etc/gateway")
LIST_DIR = Path("/etc/squid/lists")
SQUID_CONF = Path("/etc/squid/squid.conf")

try:
    import pam as _pam
except ImportError:
    try:
        import _pam
    except ImportError:
        class _pam:
            class pam:
                def authenticate(self, user, passwd, service=None):
                    import subprocess
                    nl = chr(10)
                    r = subprocess.run(['su', '-c', 'true', user],
                        input=passwd+nl, capture_output=True, text=True, timeout=5)
                    return r.returncode == 0
import time, hashlib, hmac
from collections import defaultdict

# Usuários autorizados a acessar o painel (deve ser admin do sistema)
ALLOWED_USERS = {"root", "jpfagiani", "rcborges", "sambadmin", "cpd", "supervisao"}

# Proteção brute-force: bloqueia IP após 5 tentativas em 5 minutos
_fail_log = defaultdict(list)   # {ip: [timestamps]}
_blocked   = {}                 # {ip: unblock_timestamp}
MAX_TRIES  = 5
WINDOW     = 300   # 5 minutos
BLOCK_TIME = 900   # 15 minutos bloqueado

def get_client_ip():
    return request.headers.get("X-Real-IP") or            request.headers.get("X-Forwarded-For","").split(",")[0].strip() or            request.remote_addr or "unknown"

def is_blocked(ip):
    if ip in _blocked:
        if time.time() < _blocked[ip]:
            return True
        else:
            del _blocked[ip]
            _fail_log.pop(ip, None)
    return False

def record_fail(ip):
    now = time.time()
    _fail_log[ip] = [t for t in _fail_log[ip] if now - t < WINDOW]
    _fail_log[ip].append(now)
    if len(_fail_log[ip]) >= MAX_TRIES:
        _blocked[ip] = now + BLOCK_TIME
        _fail_log.pop(ip, None)
        run(f"logger -t gateway-panel 'BLOQUEADO: {ip} após {MAX_TRIES} tentativas falhas'")
        return True
    return False

def record_ok(ip):
    _fail_log.pop(ip, None)
    _blocked.pop(ip, None)

def pam_auth(user, passwd):
    """Autentica via PAM — usa credenciais do sistema Linux."""
    if not user or not passwd: return False
    if user not in ALLOWED_USERS: return False
    try:
        p = _pam.pam()
        ok = p.authenticate(user, passwd, service="gateway-panel")
        if not ok:
            # Fallback serviço padrão
            p2 = _pam.pam()
            ok = p2.authenticate(user, passwd)
        return ok
    except Exception:
        return False

def auth_required(f):
    @wraps(f)
    def d(*a, **k):
        if not session.get("auth"):
            return redirect(url_for("login"))
        # Verificar se a sessão expirou (8 horas)
        last = session.get("last_activity", 0)
        if time.time() - last > 28800:
            session.clear()
            return redirect(url_for("login"))
        session["last_activity"] = time.time()
        return f(*a, **k)
    return d

def run(cmd, t=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        return r.stdout.strip(), r.stderr.strip(), r.returncode
    except Exception as e:
        return "", str(e), 1

def svc_ok(name):
    _, _, rc = run(f"systemctl is-active {name}")
    return rc == 0

def read_list(name):
    for ext in [".acl", ".conf"]:
        p = LIST_DIR / f"{name}{ext}"
        if p.exists():
            return [l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith("#")]
    return []

def write_list(name, lines):
    p = LIST_DIR / f"{name}.acl"
    if not p.exists(): p = LIST_DIR / f"{name}.conf"
    p.write_text("\n".join(lines) + "\n")

def squid_reload():
    _, _, rc = run("squid -k reconfigure")
    return rc == 0

CSS = """
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
body{background:#f4f6f8;color:#1a2a3a;height:100vh;display:flex;flex-direction:column;overflow:hidden}
a{color:inherit;text-decoration:none}
/* TOPBAR */
.tb{background:#1c3557;display:flex;align-items:center;justify-content:space-between;padding:0 16px;height:48px;flex-shrink:0}
.tb-brand{display:flex;align-items:center;gap:10px}
.logo-box{width:32px;height:32px;border-radius:8px;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;flex-shrink:0}
.logo-box i{color:#fff;font-size:16px}
.tb-title{color:#e8f0f8;font-size:11px;font-weight:500;line-height:1.3}
.tb-sub{color:#7a9ec0;font-size:9px}
.tb-right{display:flex;align-items:center;gap:6px}
.pill{display:flex;align-items:center;gap:5px;background:rgba(255,255,255,.1);border:0.5px solid rgba(255,255,255,.2);border-radius:20px;padding:4px 10px;color:#c0d8f0;font-size:11px}
.pill i{font-size:12px}
.tb-btn{display:flex;align-items:center;gap:3px;padding:4px 9px;border:0.5px solid rgba(255,255,255,.2);border-radius:6px;color:#a0c4e0;font-size:10px;cursor:pointer;background:transparent;text-decoration:none}
.tb-btn:hover{background:rgba(255,255,255,.08)}
.tb-btn i{font-size:12px}
/* LAYOUT */
.layout{display:flex;flex:1;overflow:hidden}
/* SIDEBAR */
.sb{width:190px;min-width:190px;background:#fff;border-right:0.5px solid #d0d7de;display:flex;flex-direction:column;overflow:hidden;flex-shrink:0}
.sb-hdr{padding:10px 12px 8px;border-bottom:0.5px solid #e8ecf0;display:flex;align-items:center;justify-content:space-between}
.sb-hdr span{font-size:9px;font-weight:600;color:#7a8a9a;text-transform:uppercase;letter-spacing:.8px}
.ns{font-size:9px;font-weight:600;color:#7a8a9a;text-transform:uppercase;letter-spacing:.8px;padding:12px 12px 5px}
.sb-list{flex:1;overflow-y:auto;padding:4px 0}
.ni{display:flex;align-items:center;gap:8px;padding:7px 12px;cursor:pointer;border-left:2px solid transparent;font-size:11px;color:#4a5a6a}
.ni:hover{background:#f4f6f8}
.ni.on{background:#e8f0fb;border-left-color:#1c5fad;color:#1c5fad;font-weight:500}
.ni i{font-size:13px;color:#7a8a9a;flex-shrink:0}
.ni.on i{color:#1c5fad}
/* MAIN */
.main{flex:1;padding:16px 20px;overflow-y:auto;background:#f4f6f8}
.pt{font-size:14px;font-weight:500;margin-bottom:14px;display:flex;align-items:center;gap:8px;color:#1a2a3a}
.pt i{font-size:17px;color:#1c5fad}
/* CARDS */
.card{background:#fff;border:0.5px solid #d0d7de;border-radius:8px;padding:14px;margin-bottom:12px}
.ct{font-size:9px;font-weight:500;color:#7a8a9a;text-transform:uppercase;letter-spacing:.6px;
    margin-bottom:10px;display:flex;align-items:center;justify-content:space-between}
.ct span{display:flex;align-items:center;gap:6px}
.ct i{font-size:12px;color:#7a8a9a}
/* GRID */
.g3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:12px}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.stat{background:#f4f6f8;border:0.5px solid #d0d7de;border-radius:7px;padding:11px}
.sl{font-size:9px;color:#9aaab8;text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px}
/* BADGES */
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 9px;border-radius:20px;font-size:10px;font-weight:500}
.bon{background:#e8f5ec;color:#1a6a2a}
.boff{background:#fef0f0;color:#a03030}
.bwarn{background:#fff8e6;color:#8a5a00}
/* DOTS */
.dot{width:6px;height:6px;border-radius:50%;display:inline-block;margin-right:3px}
.don{background:#2a7a3a}.doff{background:#c04040}
/* TABLES */
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#f4f6f8;padding:7px 10px;text-align:left;font-size:10px;font-weight:500;
   color:#7a8a9a;text-transform:uppercase;letter-spacing:.4px;border-bottom:0.5px solid #d0d7de;position:sticky;top:0}
td{padding:7px 10px;border-bottom:0.5px solid #eef0f2;color:#1a2a3a;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:#f8f9fa}
/* BUTTONS */
.btn{display:inline-flex;align-items:center;gap:4px;padding:5px 10px;border-radius:5px;font-size:11px;
     cursor:pointer;border:0.5px solid #c8d4e0;background:#fff;color:#4a5a6a;font-family:inherit}
.btn:hover{background:#f4f6f8}
.bp{background:#1c3557;border-color:#1c3557;color:#fff}.bp:hover{background:#162944}
.bg{background:#e8f5ec;border-color:#9ad0aa;color:#2a6a3a}
.br{background:#fef0f0;border-color:#f0b0b0;color:#a03030}
.bs{padding:3px 8px;font-size:10px}
/* INPUTS */
input,textarea,select{width:100%;border:0.5px solid #c8d4e0;border-radius:5px;padding:7px 9px;
    font-size:12px;color:#1a2a3a;background:#fff;font-family:inherit;outline:none}
input:focus,textarea:focus{border-color:#1c5fad}
label{display:block;font-size:11px;font-weight:500;color:#5a6a7a;margin:10px 0 4px}
/* PRE */
pre{background:#f4f6f8;border:0.5px solid #d0d7de;border-radius:6px;padding:10px;
    font-size:10px;color:#4a5a6a;overflow:auto;max-height:250px;white-space:pre-wrap;font-family:monospace}
.mono{font-family:monospace;font-size:10px;color:#5a6a7a}
/* TAGS */
.tag{display:inline-flex;align-items:center;gap:3px;background:#e8f0fb;border:0.5px solid #b8d0f0;
     border-radius:4px;padding:2px 7px;font-size:11px;color:#1c5fad;margin:2px}
.tag button{background:none;border:none;color:#c04040;cursor:pointer;font-size:12px;padding:0;line-height:1}
.ip-wrap{display:flex;flex-wrap:wrap;min-height:36px;background:#fff;border:0.5px solid #c8d4e0;
         border-radius:5px;padding:4px 6px;gap:2px;cursor:text;align-items:center}
.ip-wrap input{border:none;outline:none;padding:2px 4px;min-width:130px;flex:1;background:transparent}
/* TABS */
.tabs{display:flex;gap:5px;margin-bottom:10px;flex-wrap:wrap}
.tab{padding:4px 11px;border-radius:5px;font-size:11px;cursor:pointer;border:0.5px solid #c8d4e0;
     background:#fff;color:#5a6a7a}
.tab.on{background:#1c3557;border-color:#1c3557;color:#fff}
.hbar{display:flex;gap:8px;align-items:center;margin-bottom:10px}
.hbar input{flex:1}
.pg{display:none}.pg.on{display:block}
/* MODAL */
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:900;display:flex;
          align-items:center;justify-content:center;padding:16px}
.modal{background:#fff;border:0.5px solid #d0d7de;border-radius:10px;padding:24px;
       width:460px;max-width:100%;max-height:90vh;overflow-y:auto;box-shadow:0 8px 32px rgba(0,0,0,.12)}
.modal h3{font-size:14px;font-weight:500;margin-bottom:14px;color:#1a2a3a}
.mf{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.mf button{padding:7px 16px;border-radius:5px;font-size:12px;cursor:pointer;border:none;font-family:inherit}
.mc{background:#f4f6f8;color:#5a6a7a;border:0.5px solid #c8d4e0}
.mo{background:#1c3557;color:#fff}
/* ALERTS */
.alert{padding:10px 14px;border-radius:6px;font-size:12px;margin-bottom:10px;border:0.5px solid}
.aok{background:#e8f5ec;color:#1a5a2a;border-color:#9ad0aa}
.aerr{background:#fef0f0;color:#a03030;border-color:#f0b0b0}
/* TOAST */
#toast{position:fixed;bottom:20px;right:20px;z-index:999;display:flex;flex-direction:column;gap:6px}
.ti{padding:10px 14px;border-radius:8px;font-size:12px;min-width:220px;background:#fff;
    border:0.5px solid #d0d7de;box-shadow:0 4px 12px rgba(0,0,0,.1);animation:si .2s ease}
.ti.ok{border-left:3px solid #2a7a3a;color:#1a5a2a}
.ti.err{border-left:3px solid #c04040;color:#a03030}
.ti.warn{border-left:3px solid #c07820;color:#8a5a00}
@keyframes si{from{transform:translateX(20px);opacity:0}to{opacity:1}}
/* STATUSBAR */
.statusbar{background:#fff;border-top:0.5px solid #d0d7de;padding:0 16px;height:26px;
           display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.statusbar span{font-size:9px;color:#9aaab8}
.st-on{display:flex;align-items:center;gap:4px;color:#2a7a3a}
"""

BASE = r"""<!DOCTYPE html><html lang="pt-BR"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gateway CDPNI — Painel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.0.0/dist/tabler-icons.min.css">
<style>{{ css }}</style></head><body>
{% if logged %}
<div class="tb">
  <div class="tb-brand">
    <div class="logo-box"><i class="ti ti-router"></i></div>
    <div>
      <div class="tb-title">Gateway CDPNI — Painel de Administração</div>
      <div class="tb-sub">{{ session.get("user","root") }}@gateway · {{ hora }}</div>
    </div>
  </div>
  <div class="tb-right">
    <a href="https://192.168.0.11" target="_blank" class="tb-btn"><i class="ti ti-external-link"></i>Portal Arquivos</a>
    <span class="pill"><i class="ti ti-user-circle"></i>{{ session.get("user","root") }}</span>
    <a href="/logout" class="tb-btn"><i class="ti ti-logout"></i>Sair</a>
  </div>
</div>
<div class="layout">
  <div class="sb">
    <div class="sb-hdr"><span>Menu</span><i class="ti ti-settings" style="font-size:13px"></i></div>
    <div class="sb-list">
      <div class="ns">Principal</div>
      <a href="/?p=dash"   class="ni {{ 'on' if p=='dash'   }}"><i class="ti ti-dashboard"></i>Dashboard</a>
      <a href="/?p=svc"    class="ni {{ 'on' if p=='svc'    }}"><i class="ti ti-settings-2"></i>Serviços</a>
      <div class="ns">Proxy / Squid</div>
      <a href="/?p=hor"    class="ni {{ 'on' if p=='hor'    }}"><i class="ti ti-clock"></i>Horários</a>
      <a href="/?p=ips"    class="ni {{ 'on' if p=='ips'    }}"><i class="ti ti-network"></i>Grupos de IPs</a>
      <a href="/?p=sites"  class="ni {{ 'on' if p=='sites'  }}"><i class="ti ti-world"></i>Listas de Sites</a>
      <div class="ns">Rede</div>
      <a href="/?p=nat"    class="ni {{ 'on' if p=='nat'    }}"><i class="ti ti-arrows-exchange"></i>NAT 1:1</a>
      <a href="/?p=dns"    class="ni {{ 'on' if p=='dns'    }}"><i class="ti ti-dns"></i>DNS</a>
      <div class="ns">Sistema</div>
      <a href="/?p=logs"   class="ni {{ 'on' if p=='logs'   }}"><i class="ti ti-file-text"></i>Logs</a>
      <a href="/?p=tools"  class="ni {{ 'on' if p=='tools'  }}"><i class="ti ti-tool"></i>Ferramentas</a>
      <a href="/?p=passwd" class="ni {{ 'on' if p=='passwd' }}"><i class="ti ti-key"></i>Senha</a>
    </div>
  </div>
  <div class="main">
    {% if msg %}<div class="alert {{ 'aok' if mt=='ok' else 'aerr' }}">{{ msg }}</div>{% endif %}
    {{ content|safe }}
  </div>
</div>
<div class="statusbar">
  <span>CDPNI — Gateway de Controle de Acesso</span>
  <span class="st-on"><span class="dot don"></span>{{ 'Horário Livre' if libre else 'Horário Restrito' }}</span>
  <span>Gateway v1.0 · Python Flask</span>
</div>
{% else %}
<div style="min-height:100vh;background:linear-gradient(135deg,#0d2340,#1c3557);display:flex;align-items:center;justify-content:center">
<div style="background:#fff;border:0.5px solid #d0d7de;border-radius:12px;padding:36px;width:360px;box-shadow:0 16px 48px rgba(0,0,0,.25)">
  <div style="text-align:center;margin-bottom:24px">
    <div style="width:60px;height:60px;background:#1c3557;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;margin-bottom:10px">
      <i class="ti ti-router" style="font-size:26px;color:#fff"></i>
    </div>
    <h1 style="font-size:15px;font-weight:600;color:#1a2a3a">Gateway CDPNI</h1>
    <p style="font-size:11px;color:#7a8a9a;margin-top:3px">Painel de Administração</p>
  </div>
  {% if error %}<div class="alert aerr" style="margin-bottom:10px">{{ error }}</div>{% endif %}
  <form method="post" action="/login">
    <label>Usuário</label>
    <input type="text" name="user" value="root" autocomplete="username" required>
    <label style="margin-top:10px">Senha</label>
    <input type="password" name="pass" placeholder="••••••" autofocus required autocomplete="current-password">
    <button type="submit" class="btn bp" style="width:100%;margin-top:14px;padding:10px;justify-content:center;font-size:13px">Entrar</button>
  </form>
  <p style="text-align:center;font-size:10px;color:#9aaab8;margin-top:16px;line-height:1.5">
    Use as credenciais do sistema Linux
  </p>
</div></div>
{% endif %}
<div id="toast"></div>
<script>
function toast(m,t='ok',ms=3000){const el=document.createElement('div');el.className=`ti ${t}`;el.textContent=m;document.getElementById('toast').appendChild(el);setTimeout(()=>el.remove(),ms);}
async function api(path,data,method='POST'){const r=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:data?JSON.stringify(data):undefined});return r.json();}
</script>
{{ scripts|safe }}
</body></html>"""


def render(p, content, scripts="", msg="", mt="ok"):
    from flask import render_template_string as rts
    import datetime
    now = datetime.datetime.now()
    libre = now.weekday() >= 5
    if not libre:
        for line in SQUID_CONF.read_text().splitlines() if SQUID_CONF.exists() else []:
            m = re.search(r'acl h_livre time MTWHF (\d+):(\d+)-(\d+):(\d+)', line)
            if m:
                h1,m1,h2,m2 = int(m.group(1)),int(m.group(2)),int(m.group(3)),int(m.group(4))
                if h1*60+m1 <= now.hour*60+now.minute <= h2*60+m2: libre = True; break
    svcs = [{"n":"squid","ok":svc_ok("squid")},{"n":"named","ok":svc_ok("named")},
            {"n":"nftables","ok":svc_ok("nftables")},{"n":"nginx","ok":svc_ok("nginx")},
            {"n":"chrony","ok":svc_ok("chrony")},{"n":"fail2ban","ok":svc_ok("fail2ban")},
            {"n":"gateway-panel","ok":True}]
    return rts(BASE, css=CSS, logged=True, p=p, content=content, scripts=scripts,
               msg=msg, mt=mt, svcs=svcs, libre=libre, hora=now.strftime("%H:%M"))

@app.route("/login", methods=["GET","POST"])
def login():
    from flask import render_template_string as rts
    err = ""
    ip  = get_client_ip()

    if is_blocked(ip):
        remaining = int((_blocked.get(ip, 0) - time.time()) / 60) + 1
        err = f"IP bloqueado por tentativas excessivas. Aguarde {remaining} minuto(s)."
        return rts(BASE, css=CSS, logged=False, p="", content="", scripts="",
                   msg="", mt="ok", error=err, svcs=[], libre=False, hora=""), 429

    if request.method == "POST":
        user   = request.form.get("user","").strip().lower()
        passwd = request.form.get("pass","")

        # Delay fixo para dificultar timing attack
        time.sleep(0.4)

        if pam_auth(user, passwd):
            record_ok(ip)
            session.clear()
            session["auth"]          = True
            session["user"]          = user
            session["last_activity"] = time.time()
            session.permanent        = True
            run(f"logger -t gateway-panel 'LOGIN OK: usuario={user} ip={ip}'")
            return redirect("/")
        else:
            blocked = record_fail(ip)
            run(f"logger -t gateway-panel 'LOGIN FALHOU: usuario={user} ip={ip}'")
            if blocked:
                err = f"Muitas tentativas. IP bloqueado por 15 minutos."
            else:
                remaining_tries = MAX_TRIES - len(_fail_log.get(ip, []))
                err = f"Usuário ou senha inválidos. ({remaining_tries} tentativa(s) restante(s))"

    return rts(BASE, css=CSS, logged=False, p="", content="", scripts="",
               msg="", mt="ok", error=err, svcs=[], libre=False, hora="")

@app.route("/logout")
def logout():
    session.clear(); return redirect("/login")

@app.route("/")
@auth_required
def index():
    p = request.args.get("p","dash")
    msg = request.args.get("msg","")
    mt  = request.args.get("mt","ok")

    if p == "dash":
        ifaces, _, _ = run("ip -4 addr show | grep -E 'inet |^[0-9]' | grep -v 127")
        routes,  _, _ = run("ip route | head -6")
        content = f"""
<div class="pt"><i class="ti ti-dashboard"></i>Dashboard</div>
<div class="g3">
  <div class="stat"><div class="sl">Squid</div><span class="badge {'bon' if svc_ok('squid') else 'boff'}"><span class="dot {'don' if svc_ok('squid') else 'doff'}"></span>{'Ativo' if svc_ok('squid') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">DNS</div><span class="badge {'bon' if svc_ok('named') else 'boff'}"><span class="dot {'don' if svc_ok('named') else 'doff'}"></span>{'Ativo' if svc_ok('named') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">nftables</div><span class="badge {'bon' if svc_ok('nftables') else 'boff'}"><span class="dot {'don' if svc_ok('nftables') else 'doff'}"></span>{'Ativo' if svc_ok('nftables') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Nginx</div><span class="badge {'bon' if svc_ok('nginx') else 'boff'}"><span class="dot {'don' if svc_ok('nginx') else 'doff'}"></span>{'Ativo' if svc_ok('nginx') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Chrony</div><span class="badge {'bon' if svc_ok('chrony') else 'boff'}"><span class="dot {'don' if svc_ok('chrony') else 'doff'}"></span>{'Ativo' if svc_ok('chrony') else 'Inativo'}</span></div>
  <div class="stat"><div class="sl">Fail2ban</div><span class="badge {'bon' if svc_ok('fail2ban') else 'boff'}"><span class="dot {'don' if svc_ok('fail2ban') else 'doff'}"></span>{'Ativo' if svc_ok('fail2ban') else 'Inativo'}</span></div>
</div>
<div class="g2">
  <div class="card"><div class="ct"><span><i class="ti ti-network"></i>Interfaces</span></div><pre>{ifaces}</pre></div>
  <div class="card"><div class="ct"><span><i class="ti ti-route"></i>Rotas</span></div><pre>{routes}</pre></div>
</div>
<div class="card"><div class="ct"><span><i class="ti ti-clock"></i>Acesso agora</span></div>
  <span id="hst">Verificando...</span></div>"""
        scripts = """<script>fetch('/api/h_status').then(r=>r.json()).then(d=>{
  document.getElementById('hst').innerHTML=`<span class="badge ${d.ok?'bon':'bwarn'}">${d.ok?'Horário Livre':'Horário Restrito'}</span> <span style="color:#5a6a7a;font-size:11px">${d.hora} — ${d.msg}</span>`;});</script>"""

    elif p == "svc":
        svcs = [("squid","Proxy + SSL Bump"),("named","DNS (BIND9) — named.service"),
                ("nftables","Firewall/NAT"),("nginx","Web"),("chrony","NTP"),("fail2ban","Brute-force")]
        rows = "".join(f"""<tr><td><strong>{n}</strong></td>
          <td><span class="badge {'bon' if svc_ok(n) else 'boff'}">{'Ativo' if svc_ok(n) else 'Inativo'}</span></td>
          <td class="mono">{d}</td>
          <td style="text-align:right">
            <button class="btn bg bs" onclick="svcAct('restart','{n}')">↺ Reiniciar</button>
            <button class="btn bs" onclick="svcLog('{n}')">📋 Log</button>
          </td></tr>""" for n,d in svcs)
        content = f"""<div class="pt"><i class="ti ti-settings-2"></i>Serviços</div>
<div class="card"><table><thead><tr><th>Serviço</th><th>Status</th><th>Descrição</th><th></th></tr></thead>
<tbody>{rows}</tbody></table></div>
<div class="card" id="log-card" style="display:none"><div class="ct"><span id="log-title">Log</span>
<button class="btn bs" onclick="document.getElementById('log-card').style.display='none'">✕</button></div>
<pre id="log-pre"></pre></div>"""
        scripts = """<script>
async function svcAct(a,n){const r=await api('/api/svc',{action:a,name:n});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
async function svcLog(n){const r=await api('/api/svc_log',{name:n});document.getElementById('log-title').textContent='Log — '+n;document.getElementById('log-pre').textContent=r.log||'(vazio)';document.getElementById('log-card').style.display='block';}
</script>"""

    elif p == "hor":
        horarios = []
        if SQUID_CONF.exists():
            for line in SQUID_CONF.read_text().splitlines():
                m = re.search(r'acl h_livre time MTWHF (\d+:\d+-\d+:\d+)', line)
                if m: horarios.append(m.group(1))
        htxt = "\n".join(horarios) or "07:00-08:00\n11:00-13:00\n17:00-18:00\n19:00-23:00"
        content = f"""<div class="pt"><i class="ti ti-clock"></i>Horários de Acesso</div>
<div class="card"><div class="ct"><span>Horários livres (seg-sex)</span>
<button class="btn bp" onclick="saveHor()">💾 Salvar e Aplicar</button></div>
<p style="font-size:11px;color:#9aaab8;margin-bottom:10px">Fora desses horários, IPs restritos são bloqueados. Formato: HH:MM-HH:MM</p>
<textarea id="hor-txt" rows="8" style="font-family:monospace">{htxt}</textarea>
<div style="margin-top:8px;font-size:11px;color:#9aaab8">
  Sábado/domingo: sempre livre &nbsp;|&nbsp; Atual: <strong id="hstatus">—</strong>
</div></div>"""
        scripts = """<script>
fetch('/api/h_status').then(r=>r.json()).then(d=>{document.getElementById('hstatus').textContent=d.hora+' — '+(d.ok?'Livre':'Restrito');});
async function saveHor(){const r=await api('/api/horarios',{horarios:document.getElementById('hor-txt').value});toast(r.msg,r.ok?'ok':'err');}
</script>"""

    elif p == "ips":
        grupos = [
            ("ips_livres","IPs Livres","Acesso total à internet sem restrição de horário"),
            ("ips_parciais","IPs Parciais","Internet sempre; streaming/social bloqueado fora do horário"),
            ("ips_restritos","IPs Restritos","Só gov+bancos fora do horário; internet total no horário livre"),
        ]
        gdata = {n: read_list(n) for n,_,__ in grupos}
        cards = ""
        for name, label, desc in grupos:
            tags = "".join(f'<span class="tag">{ip}<button onclick="rmIp(\'{name}\',\'{ip}\')">×</button></span>' for ip in gdata[name])
            cards += f"""<div class="card"><div class="ct"><span>{label}</span>
<button class="btn bp" onclick="saveGrp('{name}')">💾 Salvar</button></div>
<p style="font-size:11px;color:#9aaab8;margin-bottom:8px">{desc}</p>
<div class="ip-wrap" id="wrap-{name}" onclick="document.getElementById('inp-{name}').focus()">
{tags}<input id="inp-{name}" placeholder="Ex: 192.168.0.50 (Enter para adicionar)"
onkeydown="if(event.key==='Enter'){{addIp('{name}');event.preventDefault()}}">
</div></div>"""
        content = f'<div class="pt"><i class="ti ti-network"></i>Grupos de IPs</div>{cards}'
        scripts = f"""<script>
const D={json.dumps(gdata)};
function renderTags(n){{const w=document.getElementById('wrap-'+n);const inp=w.querySelector('input');w.innerHTML='';D[n].forEach(ip=>{{const s=document.createElement('span');s.className='tag';s.innerHTML=ip+'<button onclick="rmIp(\\\''+n+'\\\',\\\''+ip+'\\\')">×</button>';w.appendChild(s);}});w.appendChild(inp);}}
function addIp(n){{const inp=document.getElementById('inp-'+n);const v=inp.value.trim().replace(/,$/,'');if(!v)return;if(!D[n].includes(v)){{D[n].push(v);renderTags(n);}}inp.value='';}}
function rmIp(n,ip){{D[n]=D[n].filter(x=>x!==ip);renderTags(n);}}
async function saveGrp(n){{addIp(n);const r=await api('/api/ips',{{name:n,ips:D[n]}});toast(r.msg,r.ok?'ok':'err');}}
</script>"""

    elif p == "sites":
        tabs = [
            ("sites_governo","Governo","Sites gov sempre liberados"),
            ("sites_liberados","Liberados","Sempre acessíveis para todos"),
            ("sites_bloqueados","Bloqueados","Bloqueados para todos, sempre"),
            ("ssl_nobump","SSL NoBump","Sem interceptação SSL"),
        ]
        tab_btns_parts = []
        for i,(n,l,_) in enumerate(tabs):
            active = "on" if i==0 else ""
            tab_btns_parts.append(f'<button class="tab {active}" data-t="{n}" onclick="swTab(\'{n}\')">{l}</button>')
        tab_btns = "".join(tab_btns_parts)
        panels_parts = []
        for pi,(n,l,d) in enumerate(tabs):
            disp = "block" if pi==0 else "none"
            cnt = chr(10).join(read_list(n))
            p1 = '<div id="tp-' + n + '" style="display:' + disp + '">' 
            p2 = '<div class="card"><div class="ct"><span>' + l + " - " + d + '</span>'
            p3 = '<button class="btn bp" onclick="saveTab(\'\'\'\'\\\'\'\'\'\')">' + chr(128190) + ' Salvar</button></div>'
            p4 = '<textarea id="txt-' + n + '" rows="10" style="font-family:monospace;font-size:11px">' + cnt + '</textarea></div></div>'
            panels_parts.append((p1+p2+p3+p4).replace("\'\'\'\'\\\'\'\'\'\'", n))
        panels = "".join(panels_parts)
        content = f'<div class="pt"><i class="ti ti-world"></i>Listas de Sites</div><div class="tabs">{tab_btns}</div>{panels}'
        scripts = """<script>
function swTab(n){document.querySelectorAll('[id^="tp-"]').forEach(el=>el.style.display='none');document.getElementById('tp-'+n).style.display='block';document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('on',t.dataset.t===n));}
async function saveTab(n){const r=await api('/api/sites',{name:n,content:document.getElementById('txt-'+n).value});toast(r.msg,r.ok?'ok':'err');}
</script>"""

    elif p == "nat":
        out, _, _ = run("cat /etc/gateway/nat_entries.conf 2>/dev/null")
        entries = []
        for line in out.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    entries.append({"int":parts[0],"ext":parts[1],"desc":parts[2] if len(parts)>2 else ""})
        rows = "".join(f'<tr><td class="mono">{e["int"]}</td><td class="mono">{e["ext"]}</td><td style="color:#5a6a7a">{e["desc"]}</td><td style="text-align:right"><button class="btn br bs" onclick="delNat(\'{e["int"]}\')">Remover</button></td></tr>' for e in entries)
        content = f"""<div class="pt"><i class="ti ti-arrows-exchange"></i>NAT 1:1</div>
<div class="card"><div class="ct"><span>Entradas ativas</span><button class="btn bp" onclick="document.getElementById('natm').style.display='flex'">+ Adicionar</button></div>
<table><thead><tr><th>IP Interno</th><th>IP Externo</th><th>Descrição</th><th></th></tr></thead>
<tbody>{rows or '<tr><td colspan="4" style="text-align:center;color:#9aaab8;padding:16px">Nenhuma entrada</td></tr>'}</tbody></table></div>
<div id="natm" class="modal-bg" style="display:none"><div class="modal"><h3>Adicionar NAT 1:1</h3>
<label>IP Interno</label><input id="ni" placeholder="192.168.0.50">
<label>IP Externo (vazio = automático)</label><input id="ne" placeholder="10.14.29.50">
<label>Descrição</label><input id="nd" placeholder="Ex: Servidor Web">
<div class="mf"><button class="mc" onclick="document.getElementById('natm').style.display='none'">Cancelar</button>
<button class="mo" onclick="addNat()">Adicionar</button></div></div></div>"""
        scripts = """<script>
async function addNat(){const r=await api('/api/nat',{action:'add',int:document.getElementById('ni').value,ext:document.getElementById('ne').value,desc:document.getElementById('nd').value});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
async function delNat(ip){if(!confirm('Remover NAT para '+ip+'?'))return;const r=await api('/api/nat',{action:'del',int:ip});toast(r.msg,r.ok?'ok':'err');if(r.ok)setTimeout(()=>location.reload(),1200);}
</script>"""

    elif p == "dns":
        zones = []
        lconf = Path("/etc/bind/named.conf.local")
        if lconf.exists():
            import re as _re
            for m in _re.finditer(r'zone "([^"]+)"[^{]*\{[^}]*file "([^"]+)"', lconf.read_text()):
                zn, zf = m.group(1), m.group(2)
                _, _, rc = run(f"named-checkzone {zn} {zf} 2>/dev/null")
                zones.append((zn, zf, rc==0))
        rows = "".join(f'<tr><td class="mono">{z}</td><td class="mono" style="color:#9aaab8">{f}</td><td><span class="badge {"bon" if ok else "boff"}">{("OK" if ok else "Erro")}</span></td></tr>' for z,f,ok in zones)
        content = f"""<div class="pt"><i class="ti ti-dns"></i>DNS</div>
<div class="card"><div class="ct"><span>Testar resolução</span></div>
<div class="hbar"><input id="dns-h" placeholder="Ex: new.cartoriosap.sp.gov.br"><button class="btn bp" onclick="testDns()">Testar</button></div>
<pre id="dns-out" style="min-height:50px">—</pre></div>
<div class="card"><div class="ct"><span>Zonas configuradas</span></div>
<table><thead><tr><th>Zona</th><th>Arquivo</th><th>Status</th></tr></thead><tbody>{rows}</tbody></table></div>"""
        scripts = """<script>
async function testDns(){const h=document.getElementById('dns-h').value.trim();if(!h)return;document.getElementById('dns-out').textContent='Resolvendo...';const r=await api('/api/dns',{host:h});document.getElementById('dns-out').textContent=r.out||r.err||'Sem resposta';}
</script>"""

    elif p == "logs":
        content = """<div class="pt"><i class="ti ti-file-text"></i>Logs</div>
<div class="tabs">
  <button class="tab on" data-l="squid" onclick="loadLog('squid')">Squid</button>
  <button class="tab" data-l="squid_cache" onclick="loadLog('squid_cache')">Squid Cache</button>
  <button class="tab" data-l="named" onclick="loadLog('named')">DNS</button>
  <button class="tab" data-l="nft" onclick="loadLog('nft')">Firewall</button>
</div>
<div class="card"><div class="ct"><span id="log-t">Squid — últimas 100 linhas</span>
<button class="btn bs" onclick="loadLog(curLog)">↺ Atualizar</button></div>
<pre id="log-out" style="max-height:350px">Carregando...</pre></div>"""
        scripts = """<script>
let curLog='squid';
async function loadLog(n){curLog=n;document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('on',t.dataset.l===n));document.getElementById('log-t').textContent=n+' — últimas 100 linhas';document.getElementById('log-out').textContent='Carregando...';const r=await api('/api/log',{name:n});const el=document.getElementById('log-out');el.textContent=r.log||'(vazio)';el.scrollTop=el.scrollHeight;}
loadLog('squid');
</script>"""

    elif p == "tools":
        tools = [("squid_reconfigure","↺ Recarregar Squid","bg"),("reload_dns","↺ Recarregar DNS","bg"),
                 ("reload_nginx","↺ Recarregar Nginx","bg"),("squid_fix","🔧 squid-fix",""),
                 ("gateway_status","📊 gateway-status",""),("restart_squid","⚠ Reiniciar Squid","br")]
        btns = "".join(f'<button class="btn {c}" style="justify-content:flex-start;margin-bottom:6px" onclick="runTool(\'{n}\')">{l}</button>' for n,l,c in tools)
        content = f"""<div class="pt"><i class="ti ti-tool"></i>Ferramentas</div>
<div class="g2">
  <div class="card"><div class="ct"><span>Ações</span></div>
  <div style="display:flex;flex-direction:column">{btns}</div></div>
  <div class="card"><div class="ct"><span>Resultado</span></div>
  <pre id="tool-out" style="min-height:200px;max-height:400px">—</pre></div>
</div>"""
        scripts = """<script>
async function runTool(n){document.getElementById('tool-out').textContent='Executando...';const r=await api('/api/tool',{name:n});document.getElementById('tool-out').textContent=r.out||r.err||'Concluído';}
</script>"""

    elif p == "passwd":
        content = """<div class="pt"><i class="ti ti-key"></i>Senha do Painel</div>
<div class="card" style="max-width:380px">
<label>Senha atual</label><input type="password" id="co">
<label>Nova senha</label><input type="password" id="cn">
<label>Confirmar</label><input type="password" id="cn2">
<button class="btn bp" style="margin-top:14px;width:100%;justify-content:center" onclick="chgPass()">Salvar senha</button></div>"""
        scripts = """<script>
async function chgPass(){const o=document.getElementById('co').value,n=document.getElementById('cn').value,n2=document.getElementById('cn2').value;if(n!==n2){toast('Senhas não coincidem','err');return;}if(n.length<4){toast('Senha muito curta','err');return;}const r=await api('/api/passwd',{old:o,new:n});toast(r.msg,r.ok?'ok':'err');}
</script>"""
    else:
        content = '<div class="pt">Página não encontrada</div>'
        scripts = ""

    return render(p, content, scripts, msg, mt)

# ── API ────────────────────────────────────────────────────────────────────
@app.route("/api/h_status", methods=["POST"])
@auth_required
def api_h():
    import datetime
    now = datetime.datetime.now()
    livre = now.weekday() >= 5
    msg = "Final de semana — livre" if livre else ""
    if not livre and SQUID_CONF.exists():
        for line in SQUID_CONF.read_text().splitlines():
            m = re.search(r'acl h_livre time MTWHF (\d+):(\d+)-(\d+):(\d+)', line)
            if m:
                h1,m1,h2,m2 = int(m.group(1)),int(m.group(2)),int(m.group(3)),int(m.group(4))
                if h1*60+m1 <= now.hour*60+now.minute <= h2*60+m2:
                    livre = True; msg = f"Livre até {h2:02d}:{m2:02d}"; break
    if not livre: msg = "Acesso restrito"
    return jsonify(ok=livre, hora=now.strftime("%H:%M"), msg=msg)

@app.route("/api/svc", methods=["POST"])
@auth_required
def api_svc():
    d = request.json; n = d.get("name"); a = d.get("action")
    allowed = ["squid","named","nftables","nginx","chrony","fail2ban","gateway-panel"]
    if n not in allowed: return jsonify(ok=False, msg="Não permitido")
    out, err, rc = run(f"systemctl {'restart' if a=='restart' else 'reload'} {n} 2>/dev/null || systemctl restart {n}")
    return jsonify(ok=rc==0, msg=f"{n} {'reiniciado' if a=='restart' else 'recarregado'}" if rc==0 else f"Erro: {err[:80]}")

@app.route("/api/svc_log", methods=["POST"])
@auth_required
def api_svc_log():
    n = request.json.get("name","")
    out, _, _ = run(f"journalctl -u {n} --no-pager -n 60 --output=short 2>/dev/null")
    return jsonify(log=out)

@app.route("/api/horarios", methods=["POST"])
@auth_required
def api_horarios():
    if not SQUID_CONF.exists(): return jsonify(ok=False, msg="squid.conf não encontrado")
    lines = request.json.get("horarios","").strip().splitlines()
    content = SQUID_CONF.read_text()
    new_lines = [l for l in content.splitlines() if not re.match(r'acl h_livre time MTWHF', l)]
    idx = next((i for i,l in enumerate(new_lines) if "time SA" in l), len(new_lines))
    new_acls = [f"acl h_livre time MTWHF {h.strip()}" for h in lines if h.strip()]
    new_lines[idx:idx] = new_acls
    SQUID_CONF.write_text("\n".join(new_lines))
    return jsonify(ok=squid_reload(), msg="Horários salvos e Squid recarregado" if squid_reload() else "Salvo — Squid recarregue manualmente")

@app.route("/api/ips", methods=["POST"])
@auth_required
def api_ips():
    d = request.json; n = d.get("name"); ips = d.get("ips",[])
    if n not in ["ips_livres","ips_parciais","ips_restritos"]: return jsonify(ok=False, msg="Inválido")
    write_list(n, ips); squid_reload()
    return jsonify(ok=True, msg=f"{n} salvo")

@app.route("/api/sites", methods=["POST"])
@auth_required
def api_sites():
    d = request.json; n = d.get("name"); content = d.get("content","")
    if n not in ["sites_governo","sites_liberados","sites_bloqueados","ssl_nobump"]: return jsonify(ok=False, msg="Inválido")
    p = LIST_DIR / f"{n}.acl"
    if not p.exists(): p = LIST_DIR / f"{n}.conf"
    p.write_text(content); squid_reload()
    return jsonify(ok=True, msg=f"{n} salvo e Squid recarregado")

@app.route("/api/nat", methods=["POST"])
@auth_required
def api_nat():
    d = request.json; action = d.get("action")
    if action == "add":
        ip_i = d.get("int","").strip(); ip_e = d.get("ext","").strip() or None; desc = d.get("desc","")
        if not ip_i: return jsonify(ok=False, msg="IP interno obrigatório")
        out, err, rc = run(f"nat-manager add {ip_i}{' '+ip_e if ip_e else ''} '{desc}'")
        return jsonify(ok=rc==0, msg=out or err or f"NAT {ip_i} adicionado")
    elif action == "del":
        out, err, rc = run(f"nat-manager del {d.get('int','')}")
        return jsonify(ok=rc==0, msg=out or err)
    return jsonify(ok=False, msg="Ação inválida")

@app.route("/api/dns", methods=["POST"])
@auth_required
def api_dns():
    h = request.json.get("host","").strip()
    if not h: return jsonify(err="Host inválido")
    out, err, _ = run(f"host {h} 127.0.0.1 2>&1 | head -6")
    return jsonify(out=out or err)

@app.route("/api/log", methods=["POST"])
@auth_required
def api_log():
    n = request.json.get("name","squid")
    cmds = {"squid":"tail -100 /var/log/squid/access.log 2>/dev/null",
            "squid_cache":"tail -100 /var/log/squid/cache.log 2>/dev/null",
            "named":"journalctl -u named --no-pager -n 80 2>/dev/null || journalctl -u bind9 --no-pager -n 80 2>/dev/null",
            "nft":"journalctl -k --no-pager -n 80 2>/dev/null | tail -80"}
    if n not in cmds: return jsonify(log="Log inválido")
    out, _, _ = run(cmds[n])
    return jsonify(log=out or "(sem dados)")

@app.route("/api/tool", methods=["POST"])
@auth_required
def api_tool():
    n = request.json.get("name","")
    tools = {"squid_reconfigure":"squid -k reconfigure 2>&1 && echo OK",
             "reload_dns":"systemctl reload named 2>/dev/null && echo OK",
             "reload_nginx":"nginx -t && systemctl reload nginx && echo OK",
             "restart_squid":"systemctl restart squid && echo OK",
             "squid_fix":"squid-fix 2>&1 | tail -40",
             "gateway_status":"gateway-status 2>&1"}
    if n not in tools: return jsonify(err="Inválido")
    out, err, rc = run(tools[n], t=30)
    return jsonify(ok=rc==0, out=out or err)

@app.route("/api/passwd", methods=["POST"])
@auth_required
def api_passwd():
    d = request.json
    if d.get("old") != get_pass(): return jsonify(ok=False, msg="Senha atual incorreta")
    if len(d.get("new","")) < 4: return jsonify(ok=False, msg="Senha muito curta")
    p = GW_CONF / "panel_pass"; p.write_text(d["new"]); p.chmod(0o600)
    return jsonify(ok=True, msg="Senha alterada")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
PYEOF

    chmod 750 "${PANEL_DIR}/app.py"
    ok "app.py criado"

    # Serviço systemd
    cat > /etc/systemd/system/gateway-panel.service << SVCEOF
[Unit]
Description=Gateway CDPNI — Painel Web v1.0
After=network.target

[Service]
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${VENV}/bin/python ${PANEL_DIR}/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable gateway-panel 2>/dev/null || true

    # Porta 5000 já está liberada no nftables pelo passo 7
    # Garantir caso nftables ainda não tenha a regra
    nft add rule inet filter input ip saddr "${NET_INT}" tcp dport 5000 ct state new accept 2>/dev/null || true
    iptables -I INPUT -s "${NET_INT}" -p tcp --dport 5000 -j ACCEPT 2>/dev/null || true

    systemctl restart gateway-panel 2>/dev/null || true
    sleep 3

    if systemctl is-active gateway-panel &>/dev/null; then
        ok "Painel ativo: http://${LAN_IP}:5000"
        ok "Login: usuário root + senha do sistema (PAM)"
    else
        soft_err "Painel não iniciou — verificar:"
        journalctl -u gateway-panel --no-pager -n 10 2>/dev/null \
            | grep -v "AF_VSOCK" | tail -8 || true
    fi
}

configure_panel

# =============================================================================
# ADICIONAR REGRA NFTABLES PARA PORTA 5000 (se ainda não existir)
# =============================================================================
hdr "Liberando porta 5000 no firewall"

if nft list ruleset 2>/dev/null | grep -q "tcp dport 5000"; then
    ok "Regra nftables para porta 5000 já existe"
else
    nft add rule inet filter input ip saddr "${NET_INT}" tcp dport 5000 ct state new accept 2>/dev/null \
        && ok "Regra nftables adicionada: ${NET_INT} → porta 5000" \
        || warn "Falha ao adicionar regra nftables — verifique manualmente"
    # Persistir no arquivo nftables para sobreviver ao reboot
    if [[ -f /etc/nftables.conf ]]; then
        # Inserir antes da linha de drop final do chain input
        sed -i '/limit rate.*NFT-IN-DROP/i\        ip saddr '"${NET_INT}"' tcp dport 5000 ct state new accept' \
            /etc/nftables.conf 2>/dev/null || warn "Não foi possível persistir regra em /etc/nftables.conf"
    fi
fi