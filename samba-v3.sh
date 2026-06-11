#!/bin/bash
# =============================================================================
# SERVIDOR SAMBA — DEBIAN 13 (CDPNI)
# Script único de instalação completa
# Versão: 8.0 — Portal Flask integrado + DNS cdpni.local
#
# Inclui:
#   - RAID 5 (5 discos, ~8TB úteis)
#   - Samba 4 com 33 pastas compartilhadas
#   - Permissões 777 recursivas em todas as pastas
#   - Controle de acesso exclusivamente via Samba (valid users)
#   - Usuários e grupos iniciais
#   - Painel web (Nginx + PHP + HTTPS)
#   - Firewall, Fail2ban, S.M.A.R.T, monitoramento RAID
# =============================================================================

# set -euo pipefail removido — smbpasswd e useradd retornam != 0 em casos normais
# Cada bloco faz sua própria verificação de erro
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# CORES E LOG
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

LOG_FILE="/var/log/samba_setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✔ $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*${NC}"; }
error()  { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ✘ ERRO: $*${NC}"; exit 1; }
info()   { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] ℹ $*${NC}"; }
header() { echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════${NC}";
           echo -e "${BOLD}${BLUE}  $*${NC}";
           echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}\n"; }

[[ $EUID -ne 0 ]] && error "Execute este script como root!"

# ---------------------------------------------------------------------------
# CONFIGURAÇÕES GLOBAIS
# ---------------------------------------------------------------------------
SAMBA_IP="192.168.0.11"
SAMBA_MASK="24"
GATEWAY="192.168.0.1"
DNS_SERVER="192.168.0.1"
SAMBA_WORKGROUP="WORKGROUP"
SAMBA_SERVERNAME="CDPNI"
SAMBA_REALM="cdpni.local"
RAID_MOUNT="/mnt/raid"
RAID_DEVICE="/dev/md0"
SAMBA_ROOT="${RAID_MOUNT}/shares"
RECYCLE_DIR="${RAID_MOUNT}/recycle"
LOG_SAMBA="/var/log/samba"
DEFAULT_PASS="1234"

# ---------------------------------------------------------------------------
# LISTA COMPLETA DE COMPARTILHAMENTOS
# Formato: "NomePasta:grp_grupo:visivel(yes|no)"
# Permissões: 777 em todas — controle de acesso via valid users no smb.conf
# ---------------------------------------------------------------------------
declare -a ALL_SHARES=(
    "Administrativo:grp_administrativo:yes"
    "Aevp:grp_aevp:yes"
    "Almoxarifado:grp_almoxarifado:yes"
    "Cadastro:grp_cadastro:yes"
    "Canil:grp_canil:yes"
    "Chefia_Turno_I:grp_chefia_1:yes"
    "Chefia_Turno_II:grp_chefia_2:yes"
    "Chefia_Turno_III:grp_chefia_3:yes"
    "Chefia_Turno_IV:grp_chefia_4:yes"
    "Cipa:grp_cipa:yes"
    "Conexao_Familiar:grp_conexao_familiar:yes"
    "CPD:grp_cpd:no"
    "csd:grp_csd:yes"
    "Diretoria_Geral:grp_diretoria:yes"
    "Educacao:grp_educacao:yes"
    "Financas:grp_financas:yes"
    "Inclusao:grp_inclusao:yes"
    "Infraestrutura:grp_infraestrutura:yes"
    "Nucleo_de_Pessoal:grp_nucleo_pessoal:yes"
    "Papel_de_Parede:grp_papel_parede:yes"
    "Planilhas:grp_planilhas:yes"
    "Portaria_Turno_I:grp_portaria:yes"
    "Portaria_Turno_II:grp_portaria:yes"
    "Portaria_Turno_III:grp_portaria:yes"
    "Portaria_Turno_IV:grp_portaria:yes"
    "Publico:grp_publico:yes"
    "Rol_de_Visitas:grp_rol_visitas:yes"
    "Saude:grp_saude:yes"
    "Scanner:grp_scanner:yes"
    "Simic:grp_simic:yes"
    "Sindicancia:grp_sindicancia:yes"
    "Supervisao:grp_supervisao:yes"
)

# Usuários iniciais: "login:nome_completo:grupo_primario:grupos_extras"
# Formato: PRIMARY é o 1º grupo (pasta principal do usuário)
# Grupos extras = demais grupos de acesso
declare -a INITIAL_USERS=(
    # ── Administradores — acesso total incluindo Diretoria ─────────────────
    "sambadmin:Administrador Samba:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_chefia_1,grp_chefia_2,grp_chefia_3,grp_chefia_4,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_publico,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "jpfagiani:JP Fagiani - Acesso Root:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_chefia_1,grp_chefia_2,grp_chefia_3,grp_chefia_4,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_publico,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "rcborges:RC Borges - Acesso Total:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_chefia_1,grp_chefia_2,grp_chefia_3,grp_chefia_4,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_publico,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    # ── Acesso total SEM Diretoria ─────────────────────────────────────────
    "cpd:CPD - Acesso Total:grp_cpd:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_chefia_1,grp_chefia_2,grp_chefia_3,grp_chefia_4,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_publico,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "supervisao:Supervisao:grp_supervisao:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_chefia_1,grp_chefia_2,grp_chefia_3,grp_chefia_4,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_publico,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    # ── Chefias — grupo individual por turno ───────────────────────────────
    "chefia1:Chefia Turno I:grp_chefia_1:grp_chefia_1"
    "chefia2:Chefia Turno II:grp_chefia_2:grp_chefia_2"
    "chefia3:Chefia Turno III:grp_chefia_3:grp_chefia_3"
    "chefia4:Chefia Turno IV:grp_chefia_4:grp_chefia_4"
    # ── Acesso cruzado ─────────────────────────────────────────────────────
    "simic:Simic:grp_simic:grp_simic,grp_cadastro"
    "cadastro:Cadastro:grp_cadastro:grp_cadastro,grp_simic"
    "csd:CSD:grp_csd:grp_csd"
    # ── Usuários por setor ─────────────────────────────────────────────────
    "adm:Administrativo:grp_administrativo:grp_administrativo"
    "aevp:AEVP:grp_aevp:grp_aevp"
    "almoxarifado:Almoxarifado:grp_almoxarifado:grp_almoxarifado"
    "canil:Canil:grp_canil:grp_canil"
    "cipa:CIPA:grp_cipa:grp_cipa"
    "conexao:Conexao Familiar:grp_conexao_familiar:grp_conexao_familiar"
    "dg:Diretoria Geral:grp_diretoria:grp_diretoria"
    "educacao:Educacao:grp_educacao:grp_educacao"
    "financas:Financas:grp_financas:grp_financas"
    "inclusao:Inclusao:grp_inclusao:grp_inclusao"
    "infra:Infraestrutura:grp_infraestrutura:grp_infraestrutura"
    "npessoal:Nucleo de Pessoal:grp_nucleo_pessoal:grp_nucleo_pessoal"
    "papel_parede:Papel de Parede:grp_papel_parede:grp_papel_parede"
    "planilhas:Planilhas:grp_planilhas:grp_planilhas"
    "portaria:Portaria (todos os turnos):grp_portaria:grp_portaria"
    "publico:Publico:grp_publico:grp_publico"
    "rol:Rol de Visitas:grp_rol_visitas:grp_rol_visitas"
    "saude:Saude:grp_saude:grp_saude"
    "scanner:Scanner:grp_scanner:grp_scanner"
    "sindicancia:Sindicancia:grp_sindicancia:grp_sindicancia"
)

# ===========================================================================
# 1. DETECÇÃO DOS HDs
# ===========================================================================
header "1. DETECÇÃO AUTOMÁTICA DOS HDs"

info "Detectando discos no sistema..."
mapfile -t ALL_DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | sort)
[[ ${#ALL_DISKS[@]} -eq 0 ]] && error "Nenhum disco detectado"

printf "%-15s %-10s %-22s %s\n" "DISPOSITIVO" "TAMANHO" "MODELO" "STATUS"
echo "─────────────────────────────────────────────────────────────────"
for disk in "${ALL_DISKS[@]}"; do
    SIZE=$(lsblk -dno SIZE "$disk" 2>/dev/null || echo "?")
    MODEL=$(cat /sys/block/"$(basename "$disk")"/device/model 2>/dev/null | xargs || echo "N/D")
    MPTS=$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | head -1 || true)
    ST="Disponível"; [[ -n "$MPTS" ]] && ST="Em uso (${MPTS})"
    printf "%-15s %-10s %-22s %s\n" "$disk" "$SIZE" "${MODEL:0:20}" "$ST"
done
echo ""

_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
if [[ -n "$_SRC" ]]; then
    _PKNAME=$(lsblk -no PKNAME "$_SRC" 2>/dev/null | head -1 || true)
    SYS_DISK="/dev/${_PKNAME:-$(basename "$_SRC" | sed 's/[0-9]*$//')}"
else
    SYS_DISK="/dev/sda"
    warn "Disco do sistema não detectado — assumindo ${SYS_DISK}"
fi
info "Disco do sistema: ${SYS_DISK}"

RAID_DISKS=()
for disk in "${ALL_DISKS[@]}"; do
    [[ "$disk" != "$SYS_DISK" ]] && RAID_DISKS+=("$disk")
done

echo ""
echo -e "${GREEN}Discos disponíveis para RAID 5:${NC}"
for i in "${!RAID_DISKS[@]}"; do
    SZ=$(lsblk -dno SIZE "${RAID_DISKS[$i]}" 2>/dev/null || echo "?")
    echo -e "  ${CYAN}[$i]${NC} ${RAID_DISKS[$i]} ($SZ)"
done
echo ""

RAID_MIN=${RAID_MIN_DISKS:-5}
if [[ ${#RAID_DISKS[@]} -lt $RAID_MIN ]]; then
    error "Necessários ${RAID_MIN} discos para RAID 5. Encontrados: ${#RAID_DISKS[@]}. Use RAID_MIN_DISKS=N para alterar."
fi
[[ ${#RAID_DISKS[@]} -gt 5 ]] && {
    warn "Mais de 5 discos livres. Usando os 5 primeiros."
    RAID_DISKS=("${RAID_DISKS[@]:0:5}")
}

echo -e "${CYAN}RAID 5: 5 × 2TB = ~8TB úteis | Tolerância: 1 disco${NC}"
echo ""
echo -e "${RED}${BOLD}⚠  TODOS OS DADOS NOS DISCOS SERÃO APAGADOS!${NC}"
echo -n "Confirma? [s/N]: "
read -r CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && error "Cancelado."

# ===========================================================================
# 2. PACOTES
# ===========================================================================
header "2. ATUALIZAÇÃO E PACOTES"

export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string cdpni"              | debconf-set-selections

# Configurar proxy para apt (necessário se o servidor usa o gateway como proxy)
if [[ -n "${HTTP_PROXY:-}" ]]; then
    cat > /etc/apt/apt.conf.d/99proxy << APTPROXY
Acquire::http::Proxy "${HTTP_PROXY}";
Acquire::https::Proxy "${HTTP_PROXY}";
APTPROXY
    log "Proxy apt configurado: ${HTTP_PROXY}"
fi

apt-get update -y
apt-get upgrade -y

# ---------------------------------------------------------------------------
# PHP não está nos repositórios padrão do Debian 13 Trixie (em desenvolvimento)
# Repositório oficial Sury (packages.sury.org) é necessário para qualquer versão
# ---------------------------------------------------------------------------
info "Verificando disponibilidade do PHP..."
if ! apt-cache show php8.3-fpm &>/dev/null 2>&1; then
    info "Adicionando repositório PHP (packages.sury.org)..."
    apt-get install -y curl gnupg2 ca-certificates lsb-release apt-transport-https
    # Sury não suporta trixie ainda — usar bookworm como base compatível
    _SURY_CODENAME=$(lsb_release -sc 2>/dev/null || echo "bookworm")
    [[ "$_SURY_CODENAME" == "trixie" || "$_SURY_CODENAME" == "sid" ]] && _SURY_CODENAME="bookworm"
    curl -sSLo /tmp/sury.gpg https://packages.sury.org/php/apt.gpg
    gpg --dearmor < /tmp/sury.gpg > /usr/share/keyrings/sury-php.gpg
    rm -f /tmp/sury.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${_SURY_CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    log "Repositório PHP (Sury/${_SURY_CODENAME}) adicionado"
else
    log "PHP 8.3 já disponível"
fi

apt-get install -y \
    sudo \
    mdadm smartmontools hdparm \
    samba samba-common-bin smbclient \
    nginx php8.3-fpm php8.3-cli php8.3-common \
    acl attr xfsprogs e2fsprogs \
    net-tools iproute2 htop iotop rsync \
    curl wget vim tmux \
    mailutils postfix \
    fail2ban ufw cron lsof \
    bash-completion bc jq findutils openssl \
    python3 python3-pip python3-venv python3-pam acl

unset DEBIAN_FRONTEND

command -v smbd &>/dev/null || error "smbd não instalado. Verifique repositórios."
command -v php  &>/dev/null || error "PHP não instalado. Verifique conexão com packages.sury.org"
log "Pacotes instalados | Samba: $(smbd --version) | PHP: $(php -r 'echo PHP_VERSION;')"

# ===========================================================================
# 3. REDE
# ===========================================================================
header "3. CONFIGURAÇÃO DE REDE"

# Detectar interface que tem o IP do Samba (192.168.0.X)
# NÃO usar 'ip route default' — pode retornar a interface WAN
IFACE=$(ip -4 addr show | awk '/inet 192\.168\./{print $NF}' | head -1)
[[ -z "$IFACE" ]] && IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
[[ -z "$IFACE" ]] && IFACE="eth0"
info "Interface LAN detectada: ${IFACE}"

cat > /etc/network/interfaces << EOF
# Gerado por 01_setup_raid_samba.sh — $(date '+%Y-%m-%d %H:%M:%S')
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
    address ${SAMBA_IP}/${SAMBA_MASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVER}
    dns-search cdpni.local
EOF

hostnamectl set-hostname "cdpni"
{
    echo "127.0.0.1   localhost"
    echo "127.0.1.1   cdpni.cdpni.local cdpni"
    echo "${SAMBA_IP}   cdpni.cdpni.local cdpni"
} > /etc/hosts

log "Rede: ${SAMBA_IP}/${SAMBA_MASK} | GW: ${GATEWAY} | IF: ${IFACE}"

# ---------------------------------------------------------------------------
# 3b. NTP — sincronizar com o gateway (que serve NTP para a LAN)
# ---------------------------------------------------------------------------
timedatectl set-ntp false 2>/dev/null || true
command -v chronyc &>/dev/null || apt-get install -y -q chrony 2>/dev/null || true
if command -v chronyc &>/dev/null; then
    cat > /etc/chrony/chrony.conf << NTPEOF
server ${GATEWAY} iburst prefer minpoll 4 maxpoll 6
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
NTPEOF
    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true
    log "NTP configurado → ${GATEWAY}"
else
    warn "chrony não disponível — configure NTP manualmente apontando para ${GATEWAY}"
fi

# ===========================================================================
# 4. RAID 5
# ===========================================================================
header "4. RAID 5 — 5 discos | ~8TB úteis"

for disk in "${RAID_DISKS[@]}"; do
    info "Zerando: ${disk}"
    mdadm --zero-superblock --force "$disk" 2>/dev/null || true
    wipefs -af "$disk" 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M count=10 oflag=direct 2>/dev/null || true
done

mdadm --create "${RAID_DEVICE}" \
    --level=5 \
    --raid-devices=5 \
    --chunk=512K \
    --layout=left-symmetric \
    --metadata=1.2 \
    --name=data \
    --force \
    --run \
    "${RAID_DISKS[@]}"

sleep 5
cat /proc/mdstat

echo 200000 > /proc/sys/dev/raid/speed_limit_min 2>/dev/null || true
echo 400000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null || true
{
    echo "# RAID 5"
    echo "dev.raid.speed_limit_min = 50000"
    echo "dev.raid.speed_limit_max = 200000"
} >> /etc/sysctl.conf
# Remover duplicatas de execuções anteriores
awk '!seen[$0]++' /etc/sysctl.conf > /tmp/sysctl.tmp && mv /tmp/sysctl.tmp /etc/sysctl.conf

mkdir -p /etc/mdadm
: > /etc/mdadm/mdadm.conf
mdadm --detail --scan > /etc/mdadm/mdadm.conf
echo "MAILADDR root" >> /etc/mdadm/mdadm.conf
update-initramfs -u -k all 2>/dev/null || update-initramfs -u

log "RAID 5 criado: ${RAID_DEVICE}"

# ===========================================================================
# 5. FORMATAÇÃO XFS E MONTAGEM
# ===========================================================================
header "5. FORMATAÇÃO XFS E MONTAGEM"

info "Aguardando array..."
for i in {1..30}; do [[ -b "${RAID_DEVICE}" ]] && break; sleep 2; done
[[ -b "${RAID_DEVICE}" ]] || error "${RAID_DEVICE} não disponível"

mkfs.xfs -f -L "SAMBA_DATA" -d su=512k,sw=4 "${RAID_DEVICE}"

mkdir -p "${RAID_MOUNT}"
RAID_UUID=$(blkid -s UUID -o value "${RAID_DEVICE}")
[[ -z "$RAID_UUID" ]] && error "UUID não encontrado após mkfs"

touch /etc/fstab
grep -v "${RAID_DEVICE}\|SAMBA_DATA" /etc/fstab > /tmp/fstab.tmp && mv /tmp/fstab.tmp /etc/fstab
echo "# RAID 5 Samba" >> /etc/fstab
echo "UUID=${RAID_UUID}  ${RAID_MOUNT}  xfs  defaults,noatime,nodiratime,allocsize=64m,largeio  0  2" >> /etc/fstab

mount "${RAID_MOUNT}"
log "Montado: ${RAID_MOUNT} | UUID: ${RAID_UUID}"

# ===========================================================================
# 6. GRUPOS
# ===========================================================================
header "6. CRIAÇÃO DE GRUPOS"

# Coletar todos os grupos únicos da lista de shares
declare -A _GRUPOS_VISTOS
for entry in "${ALL_SHARES[@]}"; do
    grp=$(echo "$entry" | cut -d: -f2)
    _GRUPOS_VISTOS[$grp]=1
done
# Grupos base adicionais
for grp in grp_diretoria grp_administrativo grp_cpd grp_sindicancia grp_chefia_turno grp_chefia_1 grp_chefia_2 grp_chefia_3 grp_chefia_4; do
    _GRUPOS_VISTOS[$grp]=1
done

for grp in "${!_GRUPOS_VISTOS[@]}"; do
    if getent group "$grp" &>/dev/null; then
        warn "Grupo já existe: ${grp}"
    else
        groupadd --system "$grp"
        log "Grupo criado: ${grp}"
    fi
done

# ===========================================================================
# 7. ESTRUTURA DE DIRETÓRIOS — 777 RECURSIVO
# ===========================================================================
header "7. ESTRUTURA DE DIRETÓRIOS (chmod 777)"

mkdir -p "${SAMBA_ROOT}"
mkdir -p "${RECYCLE_DIR}"
mkdir -p "${LOG_SAMBA}"

for entry in "${ALL_SHARES[@]}"; do
    NAME=$(echo "$entry" | cut -d: -f1)
    DIR="${SAMBA_ROOT}/${NAME}"
    mkdir -p "${DIR}"
    # 777 recursivo — controle de acesso feito exclusivamente pelo Samba
    chmod -R 777 "${DIR}"
    chown -R root:root "${DIR}"
    log "Pasta: ${DIR} (777)"
done

# Lixeira
chmod 1777 "${RECYCLE_DIR}"
chown root:root "${RECYCLE_DIR}"

log "Todas as pastas criadas com permissão 777"

# ===========================================================================
# 8. USUÁRIOS
# ===========================================================================
header "8. CRIAÇÃO DOS USUÁRIOS"

create_samba_user() {
    local LOGIN="$1"
    local FULLNAME="$2"
    local PRIMARY="$3"
    local EXTRAS="$4"

    if ! id "$LOGIN" &>/dev/null; then
        if [[ -n "$EXTRAS" ]]; then
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin \
                    -g "$PRIMARY" -G "$EXTRAS" "$LOGIN"
        else
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin \
                    -g "$PRIMARY" "$LOGIN"
        fi
        echo "${LOGIN}:${DEFAULT_PASS}" | chpasswd
        log "Usuário criado: ${LOGIN}"
    else
        usermod -g "$PRIMARY" ${EXTRAS:+-aG "$EXTRAS"} "$LOGIN" 2>/dev/null || true
        warn "Usuário já existe; grupos atualizados: ${LOGIN}"
    fi

    printf '%s\n%s\n' "${DEFAULT_PASS}" "${DEFAULT_PASS}" | smbpasswd -s -a "$LOGIN"
    smbpasswd -e "$LOGIN"

    # Lixeira pessoal
    mkdir -p "${RECYCLE_DIR}/${LOGIN}"
    chmod 700 "${RECYCLE_DIR}/${LOGIN}"
    chown "${LOGIN}:${PRIMARY}" "${RECYCLE_DIR}/${LOGIN}"

    log "Samba: ${LOGIN} | ${FULLNAME}"
}

for entry in "${INITIAL_USERS[@]}"; do
    IFS=':' read -r LOGIN FULLNAME PRIMARY EXTRAS <<< "$entry"
    EXTRAS="${EXTRAS:-}"
    create_samba_user "$LOGIN" "$FULLNAME" "$PRIMARY" "$EXTRAS"
done

log "Todos os usuários criados"

# ===========================================================================
# 9. SMB.CONF
# ===========================================================================
header "9. CONFIGURAÇÃO DO SAMBA (smb.conf)"

[[ -f /etc/samba/smb.conf ]] && \
    cp /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)"

# Gerar smb.conf — seção global
cat > /etc/samba/smb.conf << SMBEOF
# ============================================================
# smb.conf — CDPNI File Server — gerado $(date)
# Controle de acesso: via valid users por share
# Permissões de disco: 777 (sem restrição no filesystem)
# ============================================================

[global]
    workgroup            = ${SAMBA_WORKGROUP}
    server string        = CDPNI File Server
    netbios name         = CDPNI
    server role          = standalone server

    security             = user
    passdb backend       = tdbsam
    map to guest         = never

    interfaces           = lo ${IFACE}
    bind interfaces only = yes
    # hosts allow cobre a LAN inteira — garante acesso de qualquer IP 192.168.0.x
    hosts allow          = 127.0.0.1 192.168.0.
    hosts deny           = ALL

    min protocol         = SMB2
    max protocol         = SMB3

    use sendfile         = yes
    aio read size        = 16384
    aio write size       = 16384
    read raw             = yes
    write raw            = yes
    max xmit             = 65535
    dead time            = 15
    getwd cache          = yes

    log file             = ${LOG_SAMBA}/log.%m
    max log size         = 51200
    log level            = 1 auth:2

    # Permissões — 777 no filesystem, controle via valid users
    create mask          = 0664
    directory mask       = 0777
    force create mode    = 0664
    force directory mode = 0777

    # Impressoras desabilitadas
    load printers        = no
    printing             = bsd
    printcap name        = /dev/null
    disable spoolss      = yes

    # Charset
    unix charset         = UTF-8
    dos charset          = CP850

    # Lixeira + auditoria
    vfs objects                  = recycle full_audit
    recycle:repository           = ${RECYCLE_DIR}/%U
    recycle:keeptree             = yes
    recycle:versions             = yes
    recycle:touch                = yes
    recycle:touch_mtime          = yes
    recycle:exclude              = *.tmp *.temp ~\$* .DS_Store Thumbs.db desktop.ini
    recycle:exclude_dir          = .recycle tmp temp
    recycle:maxsize              = 1073741824
    full_audit:prefix            = %u|%I|%S
    full_audit:success           = open read write
    full_audit:failure           = connect
    full_audit:facility          = local5
    full_audit:priority          = notice

# ============================================================
# LIXEIRA (somente sambadmin)
# ============================================================

[Recycle]
    comment      = Lixeira
    path         = ${RECYCLE_DIR}
    valid users  = sambadmin
    writable     = no
    browseable   = no

SMBEOF

# Gerar uma entrada por share
# Shares especiais com valid users extras:
#   Chefia_Turno_*: csd e sindicancia também têm acesso
#   CPD: oculto mas acessível por usuários do grp_cpd
for entry in "${ALL_SHARES[@]}"; do
    NAME=$(echo "$entry" | cut -d: -f1)
    GRP=$(echo "$entry"  | cut -d: -f2)
    VIS=$(echo "$entry"  | cut -d: -f3)
    DIR="${SAMBA_ROOT}/${NAME}"

    # ── Regras especiais por share ──────────────────────────────────────────
    # Pastas livres: todos os grupos têm acesso
    FREE_VALID="@grp_administrativo @grp_aevp @grp_almoxarifado @grp_cadastro @grp_canil @grp_chefia_1 @grp_chefia_2 @grp_chefia_3 @grp_chefia_4 @grp_cipa @grp_conexao_familiar @grp_cpd @grp_csd @grp_diretoria @grp_educacao @grp_financas @grp_inclusao @grp_infraestrutura @grp_nucleo_pessoal @grp_papel_parede @grp_planilhas @grp_portaria @grp_publico @grp_rol_visitas @grp_saude @grp_scanner @grp_simic @grp_sindicancia @grp_supervisao"

    case "$NAME" in

        # Pastas livres — qualquer usuário acessa
        Publico|Scanner|Papel_de_Parede)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = ${FREE_VALID}
    writable     = yes
    browseable   = yes
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        # CPD — acesso livre mas OCULTO na rede
        CPD)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = ${FREE_VALID}
    writable     = yes
    browseable   = no
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        # Diretoria — restrito: apenas grp_diretoria + rcborges + jpfagiani
        Diretoria_Geral)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @grp_diretoria rcborges jpfagiani
    writable     = yes
    browseable   = yes
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        # Chefias — grupo próprio + usuários extras autorizados
        Chefia_Turno_I|Chefia_Turno_II|Chefia_Turno_III|Chefia_Turno_IV)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @${GRP} cpd jpfagiani dg rcborges supervisao sindicancia
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        # CSD — restrito: csd + supervisao + rcborges + dg + cpd + jpfagiani
        csd)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @grp_csd supervisao rcborges dg cpd jpfagiani
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        # Simic e Cadastro — acesso cruzado entre si
        Simic)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @grp_simic @grp_cadastro sambadmin jpfagiani rcborges
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

        Cadastro)
            cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @grp_cadastro @grp_simic sambadmin jpfagiani rcborges
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
            continue ;;

    esac

    # Demais shares — grupo próprio + admins
    cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @${GRP} sambadmin jpfagiani rcborges
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
done

testparm -s /etc/samba/smb.conf || error "smb.conf inválido!"

# Garantir que smbd só sobe depois do RAID montado
mkdir -p /etc/systemd/system/smbd.service.d
cat > /etc/systemd/system/smbd.service.d/raid-dependency.conf << 'EOF'
[Unit]
# smbd depende do RAID /mnt/raid estar montado
RequiresMountsFor=/mnt/raid
After=local-fs.target
EOF
systemctl daemon-reload
log "smbd configurado para aguardar montagem do RAID"

systemctl enable smbd nmbd 2>/dev/null || true
systemctl stop smbd nmbd 2>/dev/null || true
sleep 1
systemctl start nmbd 2>/dev/null || true
sleep 1
systemctl start smbd 2>/dev/null || true
sleep 2

if systemctl is-active smbd &>/dev/null; then
    log "smbd ativo"
else
    warn "smbd não iniciou — tentando novamente..."
    journalctl -u smbd --no-pager -n 5 2>/dev/null | tail -5 || true
    systemctl restart smbd 2>/dev/null || true
    sleep 2
    systemctl is-active smbd &>/dev/null && log "smbd ativo (2a tentativa)"         || error "smbd nao iniciou — verifique: systemctl status smbd"
fi
systemctl is-active nmbd &>/dev/null && log "nmbd ativo" || warn "nmbd inativo"
log "Samba iniciado: $(smbd --version)"

# ===========================================================================
# 10. FIREWALL
# ===========================================================================
header "10. FIREWALL (UFW)"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 137/udp   comment "Samba NetBIOS Name"
ufw allow 138/udp   comment "Samba NetBIOS Datagram"
ufw allow 139/tcp   comment "Samba NetBIOS Session"
ufw allow 445/tcp   comment "Samba SMB"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS"
ufw allow 8443/tcp  comment "Painel Admin Samba"
ufw allow 5000/tcp  comment "Flask Portal"
# Regras explícitas LAN — garante acesso mesmo com 'deny incoming'
ufw allow from 192.168.0.0/24 to any port 445 proto tcp
ufw allow from 192.168.0.0/24 to any port 139 proto tcp
ufw allow from 192.168.0.0/24 to any port 137 proto udp
ufw allow from 192.168.0.0/24 to any port 138 proto udp
ufw allow from 192.168.0.0/24 to any port 80 proto tcp
ufw allow from 192.168.0.0/24 to any port 443 proto tcp
ufw allow from 192.168.0.0/24 to any port 8443 proto tcp
ufw allow from 192.168.0.0/24 to any port 5000 proto tcp
ufw allow from 192.168.0.0/24 to any
ufw --force enable
log "Firewall ativo"

# ===========================================================================
# 11. FAIL2BAN
# ===========================================================================
header "11. FAIL2BAN"

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/samba.conf << 'EOF'
[samba]
enabled  = true
port     = 445,139
protocol = tcp
filter   = samba
logpath  = /var/log/samba/log.%(__name__)s
maxretry = 5
bantime  = 3600
findtime = 600
ignoreip = 127.0.0.1/8 192.168.0.0/24
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configurado"

# ===========================================================================
# 12. S.M.A.R.T.
# ===========================================================================
header "12. MONITORAMENTO S.M.A.R.T"

cat > /etc/smartd.conf << 'EOF'
DEVICESCAN -a -o on -S on -n standby,q \
  -s (S/../.././02|L/../../6/03) \
  -m root \
  -M exec /usr/share/smartmontools/smartd-runner
EOF
# Debian 13: smartd.service pode ser symlink — tratar sem abortar o script
systemctl enable smartd 2>/dev/null ||     systemctl enable --force smartd 2>/dev/null ||     warn "smartd enable falhou — monitoramento S.M.A.R.T. manual necessário"
systemctl restart smartd 2>/dev/null ||     systemctl start smartd 2>/dev/null ||     warn "smartd não iniciou — verifique: systemctl status smartd"
systemctl is-active smartd &>/dev/null && log "smartd ativo" || warn "smartd inativo — não crítico"

# ===========================================================================
# 13. MONITORAMENTO RAID
# ===========================================================================
header "13. MONITORAMENTO RAID 5"

cat > /usr/local/bin/raid_check.sh << 'RAIDEOF'
#!/bin/bash
RAID_DEV="/dev/md0"
STATE=$(mdadm --detail "$RAID_DEV" 2>/dev/null | awk '/State :/{print $3}')
FAILED=$(mdadm --detail "$RAID_DEV" 2>/dev/null | awk '/Failed Devices/{print $4}')
DEGRADED=$(mdadm --detail "$RAID_DEV" 2>/dev/null | grep -c "degraded" 2>/dev/null || echo 0)
FAILED=${FAILED:-0}
DEGRADED=${DEGRADED:-0}
ALERT=0; MSG=""
[[ "$FAILED" -gt 0 ]]   && { MSG+="DISCO FALHO ($FAILED)! "; ALERT=1; }
[[ "$DEGRADED" -gt 0 ]] && { MSG+="ARRAY DEGRADADO! "; ALERT=1; }
[[ "$STATE" != "clean" && "$STATE" != "active" ]] && { MSG+="Estado: ${STATE}. "; ALERT=1; }
if [[ $ALERT -eq 1 ]]; then
    echo "RAID ALERTA em $(hostname) $(date): ${MSG}" | mail -s "RAID ALERT" root 2>/dev/null || true
    echo "$(date): ${MSG}" >> /var/log/raid_alert.log
fi
echo "=== $(date) ===" >> /var/log/raid_check.log
mdadm --detail "$RAID_DEV" >> /var/log/raid_check.log 2>&1
RAIDEOF
chmod +x /usr/local/bin/raid_check.sh

cat > /etc/cron.d/raid_monitor << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 * * * * root /usr/local/bin/raid_check.sh
EOF
log "Monitoramento RAID configurado (1×/hora)"

# ---------------------------------------------------------------------------
# 13b. LOGROTATE — Samba e painel web
# ---------------------------------------------------------------------------
cat > /etc/logrotate.d/samba-cdpni << 'LREOF'
/var/log/samba/log.* {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -x /usr/bin/smbcontrol ] && /usr/bin/smbcontrol smbd rotate 2>/dev/null || true
    endscript
}
/var/log/raid_check.log /var/log/raid_alert.log /var/log/samba_setup.log /var/log/samba_panel.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
}
LREOF
log "Logrotate configurado"

# ===========================================================================
# 14. PAINEL WEB (Nginx + PHP + HTTPS)
# ===========================================================================
header "14. PAINEL WEB"

PANEL_DIR="/var/www/samba-panel"
PANEL_SSL_DIR="/etc/nginx/ssl"
PANEL_DOMAIN="cdpni.local"
mkdir -p "${PANEL_DIR}/public/api" "${PANEL_SSL_DIR}"

# Certificado SSL
if [[ ! -f "${PANEL_SSL_DIR}/cdpni.crt" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${PANEL_SSL_DIR}/cdpni.key" \
        -out    "${PANEL_SSL_DIR}/cdpni.crt" \
        -subj   "/C=BR/ST=SP/O=CDPNI/CN=${PANEL_DOMAIN}" \
        -addext "subjectAltName=DNS:${PANEL_DOMAIN},DNS:cdpni,DNS:cdpni.local,IP:${SAMBA_IP}" \
        2>/dev/null
    chmod 600 "${PANEL_SSL_DIR}/cdpni.key"
    log "Certificado SSL gerado"
fi

# Nginx
# Painel admin Samba — porta 8443 (acesso restrito ao admin)
# Portal Flask de arquivos — portas 80/443 (todos os usuários)
cat > /etc/nginx/sites-available/samba-panel << NGINXEOF
server {
    listen 8443 ssl;
    server_name ${PANEL_DOMAIN} ${SAMBA_IP} cdpni cdpni.local;
    ssl_certificate     ${PANEL_SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${PANEL_SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    root  ${PANEL_DIR}/public;
    index index.php;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
    location ~ /\.                    { deny all; }
    location ~* \.(sh|conf|log|key)$  { deny all; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/samba-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# ===========================================================================
# 14b. PORTAL DE ARQUIVOS — Flask
# ===========================================================================
header "14b. PORTAL DE ARQUIVOS (Flask)"

PORTAL_APP="/opt/cdpni-portal"
PORTAL_VENV="${PORTAL_APP}/venv"
PORTAL_DATA="${PORTAL_APP}/data"
PORTAL_UPLOADS="${PORTAL_DATA}/uploads"

mkdir -p "${PORTAL_APP}" "${PORTAL_DATA}" "${PORTAL_UPLOADS}"

# Usuário do serviço
if ! id cdpni &>/dev/null; then
    useradd -r -s /bin/false -d "${PORTAL_APP}" cdpni
    log "Usuário cdpni criado"
fi

# Grupo shadow para PAM
SHADOW_GRP=""
for g in shadow _shadow; do getent group "$g" &>/dev/null && { SHADOW_GRP="$g"; break; }; done
[[ -z "$SHADOW_GRP" ]] && { groupadd shadow 2>/dev/null||true; SHADOW_GRP="shadow"; }
chmod g+r /etc/shadow 2>/dev/null || true
chown root:${SHADOW_GRP} /etc/shadow 2>/dev/null || true
usermod -aG "${SHADOW_GRP}" cdpni && log "cdpni → grupo ${SHADOW_GRP}"

# PAM
cat > /etc/pam.d/cdpni-portal << 'PAMEOF'
auth    required   pam_unix.so
account required   pam_unix.so
PAMEOF

# Sudoers para cdpni
cat >> /etc/sudoers.d/samba-panel << 'SUDOEOF2'
cdpni ALL=(ALL) NOPASSWD: /usr/bin/pdbedit
cdpni ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/useradd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/usermod
cdpni ALL=(ALL) NOPASSWD: /usr/bin/gpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/bin/chpasswd
cdpni ALL=(ALL) NOPASSWD: /usr/sbin/chpasswd
SUDOEOF2

# Virtualenv com system-site-packages (para usar python3-pam do sistema)
python3 -m venv --system-site-packages "${PORTAL_VENV}"
"${PORTAL_VENV}/bin/pip" install --quiet flask
log "Flask instalado no venv"

# Permissões nas pastas Samba
command -v setfacl &>/dev/null && \
    setfacl -R -m u:cdpni:rwx "${SAMBA_ROOT}" 2>/dev/null && \
    log "ACL aplicado em ${SAMBA_ROOT}" || \
    chmod -R o+rwx "${SAMBA_ROOT}" 2>/dev/null || true

# Dados iniciais
cat > "${PORTAL_DATA}/portal_data.json" << 'JSONEOF'
{
  "banners": [
    {
      "title": "Bem-vindo ao Portal CDPNI",
      "body": "Acesse seus compartilhamentos de rede diretamente pelo navegador. Clique em uma pasta na lista à esquerda para abrir no Windows Explorer.",
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

chown -R cdpni:cdpni "${PORTAL_APP}"
chmod -R 750 "${PORTAL_APP}"
chmod 770 "${PORTAL_DATA}" "${PORTAL_UPLOADS}"
chmod 660 "${PORTAL_DATA}/portal_data.json"

log "Estrutura do portal criada em ${PORTAL_APP}"
# O app.py será criado pelo cdpni-flask-install-v3.sh
# Este script instala as dependências e prepara o ambiente
warn "Execute cdpni-flask-install-v3.sh para instalar o app Flask completo"
# Portal Flask — 80/443 (proxy reverso)
cat > /etc/nginx/sites-available/cdpni-portal << PORTALEOF
server {
    listen 80;
    server_name ${SAMBA_IP} cdpni cdpni.local;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${SAMBA_IP} cdpni cdpni.local;
    ssl_certificate     ${PANEL_SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${PANEL_SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    client_max_body_size 512M;
    client_body_timeout  300s;
    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
PORTALEOF
ln -sf /etc/nginx/sites-available/cdpni-portal /etc/nginx/sites-enabled/
log "Nginx: portal Flask configurado em 80/443"

# Serviço systemd para o portal Flask
cat > /etc/systemd/system/cdpni-portal.service << 'SVCEOF'
[Unit]
Description=CDPNI Portal de Arquivos — Flask
After=network.target

[Service]
User=cdpni
Group=cdpni
WorkingDirectory=/opt/cdpni-portal
ExecStart=/opt/cdpni-portal/venv/bin/python /opt/cdpni-portal/app.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable cdpni-portal
log "Serviço cdpni-portal registrado (iniciará após app.py ser instalado)"


# sudoers — criar diretório se não existir (Debian 13 pode não ter)
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/samba-panel << 'SUDOEOF'
www-data ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd, /usr/sbin/useradd, /usr/sbin/usermod, /usr/sbin/userdel, /usr/bin/gpasswd, /usr/sbin/groupadd, /usr/sbin/groupdel, /bin/mkdir, /usr/bin/mkdir, /bin/chown, /usr/bin/chown, /bin/chmod, /usr/bin/chmod, /usr/bin/pdbedit, /usr/sbin/testparm, /bin/systemctl restart smbd, /bin/systemctl reload smbd, /bin/systemctl status smbd, /usr/bin/systemctl restart smbd, /usr/bin/systemctl reload smbd, /usr/bin/systemctl status smbd, /usr/bin/passwd, /sbin/smbstatus, /usr/bin/smbstatus
SUDOEOF
chmod 440 /etc/sudoers.d/samba-panel
# Validar sudoers
visudo -c -f /etc/sudoers.d/samba-panel && log "sudoers OK" || warn "sudoers com erro — verificar manualmente"
# Garantir includedir ativo no sudoers
# Debian 13: usa "@includedir" (sem #). Garantir que está ativo.
if ! grep -qE "^@includedir /etc/sudoers.d|^#includedir /etc/sudoers.d" /etc/sudoers 2>/dev/null; then
    echo "@includedir /etc/sudoers.d" >> /etc/sudoers
    log "includedir adicionado ao sudoers"
else
    log "includedir já presente no sudoers"
fi

# config.php
PANEL_PASS_HASH=$(php -r "echo password_hash('admin', PASSWORD_BCRYPT);")
cat > "${PANEL_DIR}/config.php" << PHPEOF
<?php
define('PANEL_TITLE',  'CDPNI — Painel de Arquivos');
define('SAMBA_ROOT',   '${SAMBA_ROOT}');
define('RECYCLE_DIR',  '${RECYCLE_DIR}');
define('SMB_CONF',     '/etc/samba/smb.conf');
define('LOG_FILE',     '/var/log/samba_panel.log');
define('PANEL_USER',   'admin');
define('PANEL_PASS',   '${PANEL_PASS_HASH}');
define('PASS_FILE',    dirname(__FILE__).'/panel_pass.php'); // senha alterável pelo painel
ini_set('session.cookie_httponly', 1);
ini_set('session.cookie_secure', isset(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] === 'on' ? 1 : 0);
ini_set('session.gc_maxlifetime',  3600);
session_name('SAMBA_PANEL');

// Carregar senha customizada se já foi trocada
if (file_exists(PASS_FILE)) { include PASS_FILE; }
PHPEOF

# API
cat > "${PANEL_DIR}/public/api/index.php" << 'PHPEOF'
<?php
require_once dirname(__DIR__, 2) . '/config.php';
session_start();
header('Content-Type: application/json; charset=utf-8');

function json_out($d,$c=200){http_response_code($c);echo json_encode($d,JSON_UNESCAPED_UNICODE);exit;}
function run($cmd){$o=[];$r=0;exec($cmd.' 2>&1',$o,$r);return['output'=>implode("\n",$o),'code'=>$r];}
function log_action($m){file_put_contents(LOG_FILE,date('[Y-m-d H:i:s]').' ['.($_SESSION['user']??'?').'] '.$m."\n",FILE_APPEND);}
function require_auth(){if(empty($_SESSION['auth']))json_out(['error'=>'Não autenticado'],401);}

$action=$_GET['action']??$_POST['action']??'';

if($action==='login'){
    $current_hash=defined('PANEL_PASS_CURRENT')?PANEL_PASS_CURRENT:PANEL_PASS;
    if(($_POST['user']??'')===PANEL_USER&&password_verify($_POST['pass']??'',$current_hash)){
        $_SESSION['user']=$_POST['user'];
        // Senha padrão nunca foi trocada = forçar troca
        $is_default=!file_exists(PASS_FILE)&&password_verify($_POST['pass']??'',PANEL_PASS);
        if($is_default){
            $_SESSION['must_change']=true;$_SESSION['auth']=false;
            log_action('Login senha padrão — troca obrigatória');
            json_out(['ok'=>true,'must_change'=>true,'message'=>'Senha padrão detectada. Troque agora para continuar.']);
        }
        $_SESSION['auth']=true;$_SESSION['must_change']=false;
        log_action('Login');json_out(['ok'=>true,'must_change'=>false]);
    }
    json_out(['error'=>'Usuário ou senha inválidos'],401);
}
if($action==='logout'){session_destroy();json_out(['ok'=>true]);}

if($action==='change_panel_pass'){
    if(empty($_SESSION['auth'])&&empty($_SESSION['must_change']))json_out(['error'=>'Não autenticado'],401);
    $old=$_POST['old']??'';$new=$_POST['new']??'';$confirm=$_POST['confirm']??'';
    $current_hash=defined('PANEL_PASS_CURRENT')?PANEL_PASS_CURRENT:PANEL_PASS;
    if(!password_verify($old,$current_hash))json_out(['error'=>'Senha atual incorreta'],400);
    if(strlen($new)<6)json_out(['error'=>'Mínimo 6 caracteres'],400);
    if($new!==$confirm)json_out(['error'=>'Senhas não coincidem'],400);
    $hash=password_hash($new,PASSWORD_BCRYPT);
    $php="<?php define('PANEL_PASS_CURRENT','".addslashes($hash)."'); ?>";
    if(!file_put_contents(PASS_FILE,$php))json_out(['error'=>'Erro ao salvar senha'],500);
    $_SESSION['must_change']=false;$_SESSION['auth']=true;
    log_action('Senha do painel alterada');
    json_out(['ok'=>true,'message'=>'Senha alterada com sucesso!']);
}

require_auth();

if($action==='list_users'){
    $out=run('sudo pdbedit -L -v 2>/dev/null');$users=[];$cur=[];
    foreach(explode("\n",$out['output'])as$line){
        if(preg_match('/^Unix username:\s+(.+)/',$line,$m)){if($cur)$users[]=$cur;$cur=['user'=>trim($m[1]),'fullname'=>'','status'=>'Ativo','groups'=>[]];}
        elseif(preg_match('/^Full Name:\s+(.*)/',$line,$m)&&$cur)$cur['fullname']=trim($m[1]);
        elseif(preg_match('/^Account Flags:\s+\[(.+)\]/',$line,$m)&&$cur)$cur['status']=str_contains($m[1],'D')?'Desabilitado':'Ativo';
    }
    if($cur)$users[]=$cur;
    foreach($users as&$u){$g=run('id -nG '.escapeshellarg($u['user']).' 2>/dev/null');$u['groups']=array_values(array_filter(explode(' ',trim($g['output']))));}
    json_out($users);
}
if($action==='create_user'){
    $user=preg_replace('/[^a-z0-9_]/','',strtolower(trim($_POST['user']??'')));
    $full=trim($_POST['fullname']??$user);$pass=$_POST['pass']??'1234';$groups=trim($_POST['groups']??'');
    if(!$user)json_out(['error'=>'Nome inválido'],400);
    $primary=explode(',',$groups)[0]??'grp_administrativo';
    $extra=implode(',',array_slice(explode(',',$groups),1));
    $cmd="sudo useradd -m -c ".escapeshellarg($full)." -s /usr/sbin/nologin -g ".escapeshellarg($primary);
    if($extra)$cmd.=" -G ".escapeshellarg($extra);
    run($cmd." ".escapeshellarg($user));
    run("echo ".escapeshellarg("{$user}:{$pass}")." | sudo chpasswd");
    run("printf '%s\n%s\n' ".escapeshellarg($pass)." ".escapeshellarg($pass)." | sudo smbpasswd -s -a ".escapeshellarg($user));
    run("sudo smbpasswd -e ".escapeshellarg($user));
    $rec=RECYCLE_DIR."/{$user}";
    run("sudo mkdir -p ".escapeshellarg($rec));
    run("sudo chmod 700 ".escapeshellarg($rec));
    run("sudo chown {$user}:{$primary} ".escapeshellarg($rec));
    log_action("Usuário criado: {$user}");
    json_out(['ok'=>true,'message'=>"Usuário {$user} criado"]);
}
if($action==='delete_user'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    if(!$user)json_out(['error'=>'Inválido'],400);
    run("sudo smbpasswd -x ".escapeshellarg($user)." 2>/dev/null");
    run("sudo usermod -s /usr/sbin/nologin ".escapeshellarg($user));
    run("sudo passwd -l ".escapeshellarg($user));
    log_action("Desativado: {$user}");json_out(['ok'=>true]);
}
if($action==='reset_pass'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));$pass=$_POST['pass']??'1234';
    if(!$user)json_out(['error'=>'Inválido'],400);
    run("echo ".escapeshellarg("{$user}:{$pass}")." | sudo chpasswd");
    run("printf '%s\n%s\n' ".escapeshellarg($pass)." ".escapeshellarg($pass)." | sudo smbpasswd -s ".escapeshellarg($user));
    log_action("Senha: {$user}");json_out(['ok'=>true]);
}
if($action==='toggle_user'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));$enable=($_POST['enable']??'0')==='1';
    if(!$user)json_out(['error'=>'Inválido'],400);
    if($enable){run("sudo smbpasswd -e ".escapeshellarg($user));}else{run("sudo smbpasswd -d ".escapeshellarg($user));}
    log_action(($enable?'Habilitado':'Desabilitado').": {$user}");json_out(['ok'=>true]);
}
if($action==='list_groups'){
    $out=run("getent group | grep '^grp_'");$groups=[];
    foreach(explode("\n",$out['output'])as$line){
        if(!$line)continue;$p=explode(':',$line);
        $groups[]=['name'=>$p[0],'gid'=>$p[2],'members'=>$p[3]?array_values(array_filter(explode(',',$p[3]))):[]];
    }
    json_out($groups);
}
if($action==='create_group'){
    $name='grp_'.preg_replace('/[^a-z0-9_]/','',strtolower(trim($_POST['name']??'')));
    if($name==='grp_')json_out(['error'=>'Nome inválido'],400);
    $r=run("sudo groupadd ".escapeshellarg($name)." 2>&1");
    if($r['code']!==0&&str_contains($r['output'],'already exists'))json_out(['error'=>'Já existe'],409);
    log_action("Grupo: {$name}");json_out(['ok'=>true,'message'=>"Grupo {$name} criado"]);
}
if($action==='add_to_group'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    if(!$user||!$group)json_out(['error'=>'Dados inválidos'],400);
    run("sudo usermod -aG ".escapeshellarg($group)." ".escapeshellarg($user));
    log_action("{$user} → {$group}");json_out(['ok'=>true]);
}
if($action==='remove_from_group'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    run("sudo gpasswd -d ".escapeshellarg($user)." ".escapeshellarg($group)." 2>&1");
    log_action("{$user} ← {$group}");json_out(['ok'=>true]);
}
if($action==='list_shares'){
    $shares=[];$conf=file_get_contents(SMB_CONF);
    preg_match_all('/^\[([^\]]+)\]/m',$conf,$names);
    foreach($names[1]as$name){
        if(in_array(strtolower($name),['global','printers','print$','recycle']))continue;
        preg_match('/\['.preg_quote($name,'/').'\].*?(?=\n\[|\z)/s',$conf,$block);
        $b=$block[0]??'';
        $path=preg_match('/path\s*=\s*(.+)/i',$b,$m)?trim($m[1]):'';
        $comment=preg_match('/comment\s*=\s*(.+)/i',$b,$m)?trim($m[1]):'';
        $writable=preg_match('/writable\s*=\s*yes/i',$b);
        $browse=!preg_match('/browseable\s*=\s*no/i',$b);
        $size='';
        if($path&&is_dir($path)){$df=shell_exec("df -h ".escapeshellarg($path)." 2>/dev/null | tail -1");$p=preg_split('/\s+/',trim($df??''));$size=($p[2]??'').'/'.($p[1]??'');}
        $shares[]=compact('name','path','comment','writable','browse','size');
    }
    json_out($shares);
}
if($action==='create_share'){
    $name=preg_replace('/[^a-zA-Z0-9_\-]/','',trim($_POST['name']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    $comment=trim($_POST['comment']??$name);
    $writable=($_POST['writable']??'1')==='1'?'yes':'no';
    $browse=($_POST['browse']??'1')==='1'?'yes':'no';
    if(!$name||!$group)json_out(['error'=>'Nome e grupo obrigatórios'],400);
    $path=SAMBA_ROOT."/{$name}";
    run("sudo mkdir -p ".escapeshellarg($path));
    run("sudo chmod -R 777 ".escapeshellarg($path));
    run("sudo chown -R root:root ".escapeshellarg($path));
    $entry="\n[{$name}]\n    comment      = {$comment}\n    path         = {$path}\n    valid users  = @{$group} sambadmin\n    writable     = {$writable}\n    browseable   = {$browse}\n    create mask  = 0664\n    directory mask = 0777\n    force create mode = 0664\n    force directory mode = 0777\n";
    file_put_contents(SMB_CONF,$entry,FILE_APPEND);
    $t=run("sudo testparm -s ".escapeshellarg(SMB_CONF)." 2>&1");
    if(str_contains($t['output'],'FATAL'))json_out(['error'=>'Erro smb.conf: '.$t['output']],500);
    run("sudo systemctl reload smbd 2>/dev/null || sudo systemctl restart smbd");
    log_action("Share: {$name}");json_out(['ok'=>true,'message'=>"Share {$name} criado"]);
}
if($action==='status'){
    $smbd=run("systemctl is-active smbd 2>/dev/null");
    $nmbd=run("systemctl is-active nmbd 2>/dev/null");
    $raid=run("cat /proc/mdstat 2>/dev/null | head -5");
    $disk=run("df -h ".escapeshellarg(SAMBA_ROOT)." 2>/dev/null | tail -1");
    $conns=run("sudo smbstatus -S 2>/dev/null | grep -v '^\$\|^-\|^Share' | wc -l");
    $uptime=run("uptime -p 2>/dev/null");
    $p=preg_split('/\s+/',trim($disk['output']??''));
    json_out(['smbd'=>trim($smbd['output']),'nmbd'=>trim($nmbd['output']),'disk_used'=>$p[2]??'-','disk_total'=>$p[1]??'-','disk_pct'=>$p[4]??'-','connections'=>max(0,(int)trim($conns['output'])-1),'uptime'=>trim($uptime['output']),'raid'=>trim($raid['output'])]);
}
json_out(['error'=>'Ação desconhecida'],404);
PHPEOF

# Front-end
cat > "${PANEL_DIR}/public/index.php" << 'HTMLEOF'
<?php
require_once dirname(__DIR__) . '/config.php';
session_start();
$logged = !empty($_SESSION['auth']);
?>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>CDPNI — Painel de Arquivos</title>
<!-- Google Fonts removido: ambiente sem internet. Fallback para fontes do sistema -->
<style>
:root{
  --bg:#0d1b2e;--bg2:#112240;--bg3:#163052;
  --border:#1e4070;--text:#d4e8f8;--muted:#5a8ab4;
  --accent:#3a8fff;--accent2:#1a6fdf;
  --danger:#ff5a5a;--success:#3fd87a;--warning:#ffb830;
  --font:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;
  --mono:'Consolas','Courier New',monospace
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh}
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh;background:var(--bg)}
.login-box{background:var(--bg2);border:1px solid var(--border);border-radius:12px;overflow:hidden;width:340px}
.login-header{background:var(--bg3);border-bottom:1px solid var(--border);padding:20px;text-align:center}
.login-icon{width:48px;height:48px;background:linear-gradient(135deg,#1a6fdf,#3a8fff);border-radius:12px;display:inline-flex;align-items:center;justify-content:center;font-size:22px;margin-bottom:8px}
.login-header h1{font-size:16px;font-weight:600;color:var(--text)}
.login-header p{font-size:12px;color:var(--muted);margin-top:2px}
.login-body{padding:20px;display:flex;flex-direction:column;gap:12px}
.login-wrap .form-group label{font-size:11px;color:var(--muted);display:block;margin-bottom:4px}
.login-wrap input{background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:8px 12px;font-size:13px;color:var(--text);width:100%;outline:none}
.login-wrap input:focus{border-color:var(--accent)}
.login-error{font-size:12px;color:var(--danger);padding:8px 12px;background:#2a0f0f;border:1px solid #4a1f1f;border-radius:6px;display:none}
.login-submit{background:linear-gradient(90deg,#1a6fdf,#3a8fff);border:none;border-radius:6px;padding:10px;font-size:13px;font-weight:600;color:#fff;width:100%;cursor:pointer}
.layout{display:flex;height:100vh;overflow:hidden}
.sidebar{width:210px;min-width:210px;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:8px 6px;overflow-y:auto}
.sidebar-logo{padding:10px 10px 14px;border-bottom:1px solid var(--border);margin-bottom:6px;display:flex;align-items:center;gap:8px}
.sidebar-logo-icon{width:30px;height:30px;background:linear-gradient(135deg,#1a6fdf,#3a8fff);border-radius:8px;display:grid;place-items:center;font-size:14px;font-weight:700;color:#fff;flex-shrink:0}
.sidebar-logo h2{font-size:13px;font-weight:600;color:var(--text)}
.sidebar-logo small{color:var(--muted);font-size:11px;display:block}
.nav-section{padding:8px 8px 3px}
.nav-section span{font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.nav-item{display:flex;align-items:center;gap:.5rem;padding:6px 10px;color:var(--muted);cursor:pointer;font-size:12px;font-weight:500;border-radius:6px;border:1px solid transparent;margin-bottom:1px;transition:all .12s}
.nav-item:hover{background:var(--bg3);color:var(--text)}
.nav-item.active{background:#081828;color:var(--accent);border-color:#102840;font-weight:600}
.sidebar-footer{margin-top:auto;padding:10px 8px;border-top:1px solid var(--border)}
.logout-btn{width:100%;padding:.5rem;background:transparent;border:1px solid var(--border);border-radius:8px;color:var(--muted);cursor:pointer;font-size:.8rem;font-family:var(--font);transition:all .15s}
.logout-btn:hover{border-color:var(--danger);color:var(--danger)}
.main{flex:1;display:flex;flex-direction:column;overflow:hidden}
.topbar{height:52px;border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 1.5rem;background:var(--bg2);gap:1rem}
.topbar h3{font-size:.95rem;font-weight:600;flex:1}
.content{flex:1;overflow-y:auto;padding:1.5rem}
.status-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:.75rem;margin-bottom:1.5rem}
.stat-card{background:var(--bg2);border:1px solid var(--border);border-top:3px solid var(--accent);border-radius:8px;padding:10px 12px}
.stat-card .label{font-size:.7rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.stat-card .value{font-size:1.4rem;font-weight:600;margin-top:.25rem;font-family:var(--mono)}
.stat-card .sub{font-size:.75rem;color:var(--muted)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px}
.dot-green{background:var(--accent);box-shadow:0 0 6px var(--accent)}.dot-red{background:var(--danger)}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;overflow:hidden;margin-bottom:1rem}
.card-header{padding:10px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.6rem;background:var(--bg3)}
.card-header h4{font-size:.9rem;font-weight:600;flex:1}
table{width:100%;border-collapse:collapse;font-size:.85rem}
th{padding:.625rem 1.25rem;text-align:left;font-size:.72rem;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);background:var(--bg3);border-bottom:1px solid var(--border)}
td{padding:.75rem 1.25rem;border-bottom:1px solid var(--border);vertical-align:middle}
tr:last-child td{border-bottom:none}tr:hover td{background:rgba(255,255,255,.02)}
.tag{display:inline-block;padding:.15rem .55rem;border-radius:4px;font-size:.72rem;font-family:var(--mono);background:var(--bg3);border:1px solid var(--border);color:var(--muted);margin:.1rem}
.tag-blue{background:rgba(31,111,235,.15);border-color:rgba(31,111,235,.3);color:#79b8ff}
.tag-green{background:#0a2518;border-color:#1a4a30;color:#3fd87a}
.tag-red{background:#2a0f0f;border-color:#4a1f1f;color:#ff5a5a}
.btn{padding:.45rem .9rem;border-radius:6px;border:1px solid var(--border);background:var(--bg3);color:var(--text);cursor:pointer;font-size:.8rem;font-family:var(--font);font-weight:500;transition:all .15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:hover{border-color:var(--accent2);color:var(--accent2)}.btn-primary{background:var(--accent2);border-color:var(--accent2);color:#fff}
.btn-primary:hover{background:#388bfd;color:#fff}.btn-danger{border-color:var(--danger);color:var(--danger)}
.btn-danger:hover{background:rgba(218,54,51,.15)}.btn-sm{padding:.3rem .65rem;font-size:.75rem}
.form-group{margin-bottom:1rem}.form-group label{display:block;font-size:.8rem;color:var(--muted);margin-bottom:.35rem;font-weight:500}
input[type=text],input[type=password],select{width:100%;padding:.55rem .75rem;background:var(--bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:.875rem;font-family:var(--font);outline:none;transition:border-color .15s}
input:focus,select:focus{border-color:var(--accent2)}select option{background:var(--bg2)}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);backdrop-filter:blur(4px);z-index:100;align-items:center;justify-content:center}
.modal-overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:12px;width:480px;max-width:95vw;padding:1.5rem;box-shadow:0 24px 64px rgba(0,0,0,.5);animation:mIn .2s ease}
@keyframes mIn{from{opacity:0;transform:translateY(-12px) scale(.97)}to{opacity:1;transform:none}}
.modal h3{font-size:1rem;font-weight:600;margin-bottom:1.25rem;padding-bottom:.75rem;border-bottom:1px solid var(--border)}
.modal-footer{display:flex;gap:.625rem;justify-content:flex-end;margin-top:1.25rem;padding-top:.75rem;border-top:1px solid var(--border)}
.toast-wrap{position:fixed;bottom:1.5rem;right:1.5rem;z-index:999;display:flex;flex-direction:column;gap:.5rem}
.toast{padding:.75rem 1.25rem;border-radius:8px;border:1px solid;font-size:.85rem;font-weight:500;max-width:320px;animation:tIn .25s ease}
@keyframes tIn{from{opacity:0;transform:translateX(20px)}to{opacity:1;transform:none}}
.toast.success{background:var(--green-bg,#0a2518);border-color:var(--green-bd,#1a4a30);color:#3fd87a}
.toast.error{background:#2a0f0f;border-color:#4a1f1f;color:#ff5a5a}
.empty{text-align:center;padding:3rem 1rem;color:var(--muted)}.empty .icon{font-size:2.5rem;display:block;margin-bottom:.75rem;opacity:.4}
.spin{display:inline-block;width:14px;height:14px;border:2px solid var(--border);border-top-color:var(--accent2);border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
</style>
</head>
<body>
<?php if(!$logged): ?>
<div class="login-wrap"><div class="login-box">
  <div class="login-header"><div class="login-icon">📁</div><h1>CDPNI</h1><p>Painel de Gerenciamento de Arquivos</p></div>
  <div class="login-body">
  <form id="lF">
    <div id="lE" class="login-error"></div>
    <div class="form-group"><label>Usuário</label><input type="text" id="lU" value="admin" required></div>
    <div class="form-group"><label>Senha</label><input type="password" id="lP" placeholder="••••••••" required></div>
    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;padding:.6rem">Entrar</button>
    <div id="lE" style="color:var(--danger);font-size:.8rem;margin-top:.5rem;text-align:center;display:none"></div>
  </form>
</div></div>
<?php else: ?>
<div class="layout">
  <aside class="sidebar">
    <div class="sidebar-logo"><div class="sidebar-logo-icon">SB</div><div><h2>Samba CDPNI</h2><small>v7.4 — Arquivos</small></div></div>
    <div class="nav-section"><span>Principal</span></div>
    <div class="nav-item active" onclick="goto('dashboard')"><span>🏠</span> Dashboard</div>
    <div class="nav-section"><span>Usuários</span></div>
    <div class="nav-item" onclick="goto('users')"><span>👤</span> Usuários</div>
    <div class="nav-item" onclick="goto('groups')"><span>👥</span> Grupos</div>
    <div class="nav-section"><span>Arquivos</span></div>
    <div class="nav-item" onclick="goto('shares')"><span>🗂️</span> Compartilhamentos</div>
    <div class="sidebar-footer"><button class="logout-btn" onclick="logout()">⏻ Sair</button></div>
  </aside>
  <div class="main">
    <div class="topbar"><h3 id="pT">Dashboard</h3><button id="tA" class="btn btn-primary btn-sm" style="display:none"></button></div>
    <div class="content" id="ct"><div style="display:flex;align-items:center;gap:.5rem;color:var(--muted)"><span class="spin"></span> Carregando...</div></div>
  </div>
</div>
<div class="modal-overlay" id="modal"><div class="modal"><h3 id="mT"></h3><div id="mB"></div><div class="modal-footer" id="mF"></div></div></div>
<div class="toast-wrap" id="toasts"></div>
<?php endif; ?>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
function toast(msg,type='success'){const t=document.createElement('div');t.className='toast '+type;t.textContent=msg;$('toasts').appendChild(t);setTimeout(()=>t.remove(),3500);}
async function api(action,data={},method='GET'){const isGet=method==='GET';const opts={method,credentials:'same-origin'};if(!isGet){const fd=new FormData();fd.append('action',action);Object.entries(data).forEach(([k,v])=>fd.append(k,v));opts.body=fd;}const res=await fetch(isGet?`api/?action=${action}`:'api/',opts);const json=await res.json();if(json.error)throw new Error(json.error);return json;}
function modal(title,body,btns=[]){$('mT').textContent=title;$('mB').innerHTML=body;$('mF').innerHTML='';btns.forEach(b=>{const el=document.createElement('button');el.className='btn '+(b.cls||'');el.textContent=b.label;el.onclick=b.fn;$('mF').appendChild(el);});$('modal').classList.add('open');}
function closeModal(){$('modal').classList.remove('open');}
$('modal')?.addEventListener('click',e=>{if(e.target===$('modal'))closeModal();});
document.getElementById('lF')?.addEventListener('submit',async e=>{
  e.preventDefault();
  const btn=e.target.querySelector('button');
  btn.disabled=true;btn.textContent='Entrando...';
  try{
    const res=await api('login',{user:$('lU').value,pass:$('lP').value},'POST');
    if(res.must_change){
      // Mostrar tela de troca de senha obrigatória
      document.querySelector('.login-box').innerHTML=`
        <div class="login-header">
          <div class="login-icon">🔑</div>
          <h1>Troca de Senha Obrigatória</h1>
          <p style="color:var(--warning)">${res.message}</p>
        </div>
        <div class="login-body">
          <form id="cpF">
            <div id="cpE" class="login-error"></div>
            <div class="form-group"><label>Senha Atual</label><input type="password" id="cpO" placeholder="senha atual" required></div>
            <div class="form-group"><label>Nova Senha</label><input type="password" id="cpN" placeholder="mínimo 6 caracteres" required></div>
            <div class="form-group"><label>Confirmar Nova Senha</label><input type="password" id="cpC" placeholder="repita a nova senha" required></div>
            <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;padding:.6rem">Salvar Nova Senha</button>
          </form>
        </div>`;
      document.getElementById('cpF').addEventListener('submit',async ev=>{
        ev.preventDefault();
        const b=ev.target.querySelector('button');b.disabled=true;b.textContent='Salvando...';
        try{
          await api('change_panel_pass',{old:$('cpO').value,new:$('cpN').value,confirm:$('cpC').value},'POST');
          location.reload();
        }catch(err){
          $('cpE').textContent=err.message;$('cpE').style.display='block';
          b.disabled=false;b.textContent='Salvar Nova Senha';
        }
      });
    } else {
      location.reload();
    }
  }catch(err){$('lE').textContent=err.message;$('lE').style.display='block';btn.disabled=false;btn.textContent='Entrar';}
});
async function logout(){await api('logout',{},'POST');location.reload();}
const pages={dashboard:{title:'Dashboard',action:null},users:{title:'Usuários',action:{label:'+ Novo Usuário',fn:'openCreateUser'}},groups:{title:'Grupos',action:{label:'+ Novo Grupo',fn:'openCreateGroup'}},shares:{title:'Compartilhamentos',action:{label:'+ Novo Share',fn:'openCreateShare'}}};
function goto(page){document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));document.querySelectorAll('.nav-item').forEach(n=>{if(n.getAttribute('onclick')?.includes(`'${page}'`))n.classList.add('active');});const p=pages[page];$('pT').textContent=p.title;const btn=$('tA');if(p.action){btn.style.display='';btn.textContent=p.action.label;btn.onclick=()=>window[p.action.fn]();}else btn.style.display='none';$('ct').innerHTML='<div style="display:flex;align-items:center;gap:.5rem;color:var(--muted)"><span class="spin"></span> Carregando...</div>';renders[page]?.();}
const renders={
async dashboard(){try{const s=await api('status');const ok=v=>v==='active';$('ct').innerHTML=`<div class="status-grid"><div class="stat-card"><div class="label">Samba</div><div class="value" style="font-size:1rem;margin-top:.4rem"><span class="dot ${ok(s.smbd)?'dot-green':'dot-red'}"></span>${ok(s.smbd)?'Ativo':'Inativo'}</div></div><div class="stat-card"><div class="label">NetBIOS</div><div class="value" style="font-size:1rem;margin-top:.4rem"><span class="dot ${ok(s.nmbd)?'dot-green':'dot-red'}"></span>${ok(s.nmbd)?'Ativo':'Inativo'}</div></div><div class="stat-card"><div class="label">Disco</div><div class="value">${esc(s.disk_used||'-')}</div><div class="sub">de ${esc(s.disk_total||'-')} (${esc(s.disk_pct||'-')})</div></div><div class="stat-card"><div class="label">Conexões</div><div class="value">${esc(s.connections)}</div></div><div class="stat-card" style="grid-column:span 2"><div class="label">Uptime</div><div class="value" style="font-size:.95rem;margin-top:.35rem">${esc(s.uptime||'-')}</div></div></div><div class="card"><div class="card-header"><h4>Status RAID 5</h4></div><pre style="padding:1rem 1.25rem;font-family:var(--mono);font-size:.78rem;color:var(--muted);white-space:pre-wrap">${esc(s.raid||'N/D')}</pre></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async users(){try{const u=await api('list_users');if(!u.length){$('ct').innerHTML='<div class="empty"><span class="icon">👤</span>Nenhum usuário</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Usuários Samba (${u.length})</h4></div><table><thead><tr><th>Usuário</th><th>Nome</th><th>Status</th><th>Grupos</th><th></th></tr></thead><tbody>${u.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.user)}</span></td><td style="color:var(--muted)">${esc(x.fullname||'-')}</td><td>${x.status==='Ativo'?'<span class="tag tag-green">Ativo</span>':'<span class="tag tag-red">Desabilitado</span>'}</td><td>${x.groups.map(g=>`<span class="tag tag-blue">${esc(g)}</span>`).join('')||'-'}</td><td style="text-align:right;white-space:nowrap"><button class="btn btn-sm" onclick="openResetPass('${esc(x.user)}')">🔑</button> <button class="btn btn-sm" onclick="toggleUser('${esc(x.user)}','${x.status}')">${x.status==='Ativo'?'⏸':'▶'}</button> <button class="btn btn-sm btn-danger" onclick="deleteUser('${esc(x.user)}')">🗑</button></td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async groups(){try{const g=await api('list_groups');if(!g.length){$('ct').innerHTML='<div class="empty"><span class="icon">👥</span>Nenhum grupo</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Grupos (${g.length})</h4></div><table><thead><tr><th>Grupo</th><th>GID</th><th>Membros</th><th></th></tr></thead><tbody>${g.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.name)}</span></td><td style="color:var(--muted);font-family:var(--mono)">${esc(x.gid)}</td><td>${x.members.map(m=>`<span class="tag">${esc(m)}</span>`).join('')||'<span style="color:var(--muted);font-size:.8rem">sem membros</span>'}</td><td style="text-align:right"><button class="btn btn-sm" onclick="openAddMember('${esc(x.name)}')">+ Membro</button></td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async shares(){try{const s=await api('list_shares');if(!s.length){$('ct').innerHTML='<div class="empty"><span class="icon">🗂️</span>Nenhum share</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Compartilhamentos (${s.length})</h4></div><table><thead><tr><th>Nome</th><th>Caminho</th><th>Disco</th><th>Flags</th></tr></thead><tbody>${s.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.name)}</span></td><td style="color:var(--muted);font-size:.8rem;font-family:var(--mono)">${esc(x.path)}</td><td style="font-family:var(--mono);font-size:.8rem">${esc(x.size||'-')}</td><td>${x.writable?'<span class="tag tag-green">gravável</span>':'<span class="tag">leitura</span>'} ${x.browse?'<span class="tag">visível</span>':'<span class="tag tag-red">oculto</span>'}</td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}}};
async function loadGrps(){try{const g=await api('list_groups');return g.map(x=>`<option value="${esc(x.name)}">${esc(x.name)}</option>`).join('');}catch{return '';}}
async function openCreateUser(){const opts=await loadGrps();modal('Novo Usuário',`<div class="form-row"><div class="form-group"><label>Login *</label><input type="text" id="nU" placeholder="ex: joao"></div><div class="form-group"><label>Nome Completo</label><input type="text" id="nF"></div></div><div class="form-row"><div class="form-group"><label>Senha</label><input type="password" id="nP" placeholder="1234"></div><div class="form-group"><label>Grupo Principal *</label><select id="nG">${opts}</select></div></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const user=$('nU').value.trim();if(!user)return toast('Informe o login','error');try{await api('create_user',{user,fullname:$('nF').value,pass:$('nP').value||'C1234!',groups:$('nG').value},'POST');toast(`Usuário ${user} criado`);closeModal();renders.users();}catch(e){toast(e.message,'error');}}}]);}
function openResetPass(user){modal(`Resetar Senha — ${user}`,`<div class="form-group"><label>Nova Senha</label><input type="password" id="rP" placeholder="1234"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Salvar',cls:'btn-primary',fn:async()=>{try{await api('reset_pass',{user,pass:$('rP').value||'C1234!'},'POST');toast('Senha atualizada');closeModal();}catch(e){toast(e.message,'error');}}}]);}
async function toggleUser(user,status){try{await api('toggle_user',{user,enable:status!=='Ativo'?'1':'0'},'POST');toast(`${user} ${status!=='Ativo'?'habilitado':'desabilitado'}`);renders.users();}catch(e){toast(e.message,'error');}}
function deleteUser(user){modal(`Revogar Acesso — ${user}`,`<p style="color:var(--muted)">Acesso de <strong style="color:var(--text)">${esc(user)}</strong> será revogado.</p>`,[{label:'Cancelar',fn:closeModal},{label:'Revogar',cls:'btn-danger',fn:async()=>{try{await api('delete_user',{user},'POST');toast('Acesso revogado');closeModal();renders.users();}catch(e){toast(e.message,'error');}}}]);}
function openCreateGroup(){modal('Novo Grupo',`<div class="form-group"><label>Nome (prefixado com grp_) *</label><input type="text" id="gN" placeholder="ex: financeiro"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const name=$('gN').value.trim();if(!name)return toast('Informe o nome','error');try{await api('create_group',{name},'POST');toast(`Grupo grp_${name} criado`);closeModal();renders.groups();}catch(e){toast(e.message,'error');}}}]);}
async function openAddMember(group){modal(`Adicionar Membro — ${group}`,`<div class="form-group"><label>Usuário *</label><input type="text" id="mU" placeholder="ex: joao"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Adicionar',cls:'btn-primary',fn:async()=>{const user=$('mU').value.trim();if(!user)return toast('Informe o usuário','error');try{await api('add_to_group',{user,group},'POST');toast(`${user} adicionado`);closeModal();renders.groups();}catch(e){toast(e.message,'error');}}}]);}
async function openCreateShare(){const opts=await loadGrps();modal('Novo Compartilhamento',`<div class="form-row"><div class="form-group"><label>Nome *</label><input type="text" id="sN"></div><div class="form-group"><label>Grupo *</label><select id="sG">${opts}</select></div></div><div class="form-group"><label>Descrição</label><input type="text" id="sC"></div><div class="form-row"><div class="form-group"><label>Gravável</label><select id="sW"><option value="1">Sim</option><option value="0">Não</option></select></div><div class="form-group"><label>Visível</label><select id="sB"><option value="1">Sim</option><option value="0">Não</option></select></div></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const name=$('sN').value.trim(),group=$('sG').value;if(!name||!group)return toast('Nome e grupo obrigatórios','error');try{await api('create_share',{name,group,comment:$('sC').value,writable:$('sW').value,browse:$('sB').value},'POST');toast(`Share ${name} criado`);closeModal();renders.shares();}catch(e){toast(e.message,'error');}}}]);}
<?php if($logged): ?>goto('dashboard');<?php endif; ?>
</script></body></html>
HTMLEOF

chown -R www-data:www-data "${PANEL_DIR}"
chmod -R 750 "${PANEL_DIR}"
chmod 640 "${PANEL_DIR}/config.php"

# Criar arquivo de log do painel com permissão correta
touch /var/log/samba_panel.log
chown www-data:www-data /var/log/samba_panel.log
chmod 664 /var/log/samba_panel.log
log "Log do painel criado: /var/log/samba_panel.log"

systemctl enable php8.3-fpm
systemctl restart php8.3-fpm
nginx -t || error "Nginx config inválida"
systemctl enable nginx
systemctl restart nginx

# Testar que www-data pode executar pdbedit via sudo
if sudo -u www-data sudo /usr/bin/pdbedit -L &>/dev/null; then
    log "sudo OK: www-data pode executar pdbedit"
else
    warn "sudo pode não estar funcionando para www-data — verifique /etc/sudoers.d/samba-panel"
fi

log "Painel web: https://${SAMBA_IP} | admin / admin"

# ===========================================================================
# 15. RESUMO FINAL
# ===========================================================================
header "INSTALAÇÃO CONCLUÍDA"

echo -e "${GREEN}${BOLD}"
cat << 'BANNER'
  ██████╗██████╗ ██████╗ ███╗   ██╗██╗
 ██╔════╝██╔══██╗██╔══██╗████╗  ██║██║
 ██║     ██║  ██║██████╔╝██╔██╗ ██║██║
 ██║     ██║  ██║██╔═══╝ ██║╚██╗██║██║
 ╚██████╗██████╔╝██║     ██║ ╚████║██║
  ╚═════╝╚═════╝ ╚═╝     ╚═╝  ╚═══╝╚═╝
BANNER
echo -e "${NC}"

TOTAL_SHARES=${#ALL_SHARES[@]}
OCULTAS=$(printf '%s\n' "${ALL_SHARES[@]}" | grep -c ':no$' || true)

echo -e "${CYAN}┌──────────────────────────────────────────────────────────┐"
echo -e "│                  RESUMO DA INSTALAÇÃO                   │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  Servidor     : cdpni  (192.168.0.11/24)                 │"
echo -e "│  Gateway/DNS  : 192.168.0.1                              │"
echo -e "│  RAID 5       : /dev/md0 — 5 × 2TB — ~8TB úteis         │"
echo -e "│  Permissões   : 777 recursivo (controle via Samba)       │"
echo -e "│  Pastas       : ${TOTAL_SHARES} compartilhamentos (${OCULTAS} oculta: CPD)       │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  USUÁRIO      SENHA  ACESSO                              │"
echo -e "│  sambadmin    1234   todos os compartilhamentos ⚠TROCAR  │"
echo -e "│  cpd          1234   todos os compartilhamentos          │"
echo -e "│  jpfagiani    1234   todos (acesso root)                 │"
echo -e "│  rcborges     1234   todos os compartilhamentos          │"
echo -e "│  supervisao   1234   todos os compartilhamentos          │"
echo -e "│  adm/aevp/... 1234   pasta do respectivo setor           │"
echo -e "│  sindicancia  1234   Sindicancia + Chefias               │"
echo -e "│  csd          1234   CSD + Chefias + Rol + Sindicancia   │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  Portal arquivos  : https://cdpni  ou https://192.168.0.11  │"
echo -e "│  Painel admin     : https://cdpni:8443  (admin / admin)  │"
echo -e "│  Samba            : \\\\cdpni  ou  \\\\192.168.0.11             │"
echo -e "│  CPD oculto       : acesse direto \\\\192.168.0.11\\CPD       │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  ⚠  RAID 5 sincronizando em background                  │"
echo -e "│     watch cat /proc/mdstat                               │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  ⚠  Para ativar o portal Flask:                         │"
echo -e "│     bash cdpni-flask-install-v3.sh                      │"
echo -e "└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}Próximos passos:"
echo -e "  1. Instalar portal  : sudo bash cdpni-flask-install-v3.sh"
echo -e "  2. Acessar portal   : https://cdpni  (ou https://192.168.0.11)"
echo -e "  3. Painel admin     : https://cdpni:8443"
echo -e "  4. Trocar senha     : via portal → Minha Senha"
echo -e "  5. Reiniciar        : sudo reboot${NC}"
echo ""