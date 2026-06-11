#!/bin/bash
# =============================================================================
# GATEWAY SETUP — DEBIAN 13 (Trixie)
# NAT 1:1 manual | BIND9 | chrony | nftables | Squid SSL Bump
# Rede externa : 10.14.29.0/24   Rede interna: 192.168.0.0/24
# Versão: 4.0 — auditado e corrigido para máquina real
# =============================================================================
# Modo seguro: sem set -e/-u/-o pipefail
# Cada função faz sua própria verificação de erro
# set -e causa abort silencioso; set -u aborta em variáveis não inicializadas
export DEBIAN_FRONTEND=noninteractive

# ── Cores ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
info() { echo -e "${CYN}[INFO]${NC} $*"; }
hdr()  {
    echo -e "\n${BLD}${CYN}══════════════════════════════════════════════${NC}"
    echo -e "${BLD}${CYN}  $*${NC}"
    echo -e "${BLD}${CYN}══════════════════════════════════════════════${NC}"
}
# err() não mais usa exit — deixar o script continuar e reportar no final
ERRORS=()
soft_err() { ERRORS+=("$*"); err "$*"; return 0; }

[[ $EUID -ne 0 ]] && { err "Execute como root: sudo bash $0"; exit 1; }

hdr "GATEWAY SETUP — DEBIAN 13 v4.0"
info "Início: $(date '+%d/%m/%Y %H:%M:%S')"

# Nota: sem set -e, o script nunca aborta por erro de comando
# O trap ERR foi removido pois [[ ]] false também o acionava (falso positivo)

# =============================================================================
# PASSO 0 — DETECÇÃO AUTOMÁTICA DE INTERFACES, IPs E MODO DE ENDEREÇAMENTO
# =============================================================================
hdr "0. DETECÇÃO AUTOMÁTICA DE REDE"

# Inicializar todas as variáveis globais
WAN_IFACE="" LAN_IFACE="" WAN_IP="" LAN_IP="" GW_IP=""
WAN_MODE="static" LAN_MODE="static"   # dhcp ou static

detect_and_confirm() {
    # ── Coletar interfaces (exceto loopback e interfaces virtuais) ────────────
    local ifaces=()
    mapfile -t ifaces < <(
        ip -o link show | awk -F': ' '{print $2}'         | grep -Ev '^lo$|^docker|^br-|^veth|^virbr'
    ) 2>/dev/null || true

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        err "Nenhuma interface de rede detectada. Verifique: ip link show"
        exit 1
    fi

    # ── Detectar WAN e LAN automaticamente por faixa de IP ───────────────────
    local auto_wan="" auto_wan_ip="" auto_wan_cidr=""
    local auto_lan="" auto_lan_ip="" auto_lan_cidr=""
    local auto_gw=""

    for iface in "${ifaces[@]}"; do
        local cidr ip4
        cidr=$(ip -4 addr show "$iface" 2>/dev/null                | awk '/inet /{print $2}' | head -1)
        ip4="${cidr%%/*}"
        [[ -z "$ip4" ]] && continue
        if [[ "$ip4" == 192.168.* ]]; then
            auto_lan="$iface"; auto_lan_ip="$ip4"; auto_lan_cidr="$cidr"
        elif [[ "$ip4" != 127.* ]]; then
            auto_wan="$iface"; auto_wan_ip="$ip4"; auto_wan_cidr="$cidr"
        fi
    done

    # Gateway: rota default
    auto_gw=$(ip route show 2>/dev/null | awk '/^default/{print $3}' | head -1)

    # LAN sem IP (DOWN): usar segunda interface
    if [[ -z "$auto_lan" ]]; then
        for iface in "${ifaces[@]}"; do
            [[ "$iface" == "$auto_wan" ]] && continue
            auto_lan="$iface"; auto_lan_ip="(sem ip — DOWN)"; break
        done
    fi

    # Sub-rede WAN calculada pelo CIDR detectado
    local auto_net_wan=""
    if [[ -n "$auto_wan_cidr" ]]; then
        local wan_base; wan_base=$(echo "$auto_wan_ip" | cut -d. -f1-3)
        auto_net_wan="${wan_base}.0/${auto_wan_cidr##*/}"
    fi

    # Detectar se WAN está em DHCP (proto dhcp na tabela de rotas)
    local auto_wan_mode="static"
    ip route show dev "$auto_wan" 2>/dev/null | grep -q "proto dhcp"         && auto_wan_mode="dhcp"

    # ── Exibir tabela de interfaces ───────────────────────────────────────────
    echo ""
    printf "  ${BLD}%-14s %-19s %-18s %-8s %s${NC}\n"         "Interface" "IP/Máscara" "MAC" "Estado" "Função"
    echo "  ──────────────────────────────────────────────────────────────────────"
    for iface in "${ifaces[@]}"; do
        local cidr mac state fn
        cidr=$(ip -4 addr show "$iface" 2>/dev/null                | awk '/inet /{print $2}' | head -1)
        mac=$(ip link show "$iface" 2>/dev/null | awk '/ether/{print $2}')
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
        fn=""
        [[ "$iface" == "$auto_wan" ]] && fn="${GRN}← WAN${NC}"
        [[ "$iface" == "$auto_lan" ]] && fn="${CYN}← LAN${NC}"
        printf "  %-14s %-19s %-18s %-8s "             "$iface" "${cidr:-(sem ip)}" "${mac:-(?)}" "$state"
        echo -e "$fn"
    done

    # ── Exibir configuração detectada ─────────────────────────────────────────
    echo ""
    echo -e "  ${BLD}${CYN}Configuração detectada automaticamente:${NC}"
    echo ""
    printf "  ${GRN}  %-14s${NC} %-18s %s\n"         "WAN" "${auto_wan:-(não detectada)}" "${auto_wan_ip:-(sem ip)}"
    printf "  ${GRN}  %-14s${NC} %-18s %s\n"         "Gateway" "" "${auto_gw:-(não detectado)}"
    printf "  ${CYN}  %-14s${NC} %-18s %s\n"         "LAN" "${auto_lan:-(não detectada)}" "192.168.0.1 (fixo)"
    printf "  ${CYN}  %-14s${NC} %-18s %s\n"         "Rede WAN" "" "${auto_net_wan:-(calculando...)}"
    echo ""

    # ── Confirmação das interfaces ────────────────────────────────────────────
    echo -e "  ${BLD}Pressione ENTER para confirmar interfaces ou 'n' para editar:${NC}"
    echo -ne "  Confirmar? [ENTER/n]: "
    local resp; read -r resp

    if [[ -n "$resp" && "${resp,,}" != "s" && "${resp,,}" != "y" ]]; then
        echo ""
        warn "Modo manual — selecione as interfaces:"
        local n=1
        for iface in "${ifaces[@]}"; do
            local cidr
            cidr=$(ip -4 addr show "$iface" 2>/dev/null                    | awk '/inet /{print $2}' | head -1)
            printf "    ${BLD}[%d]${NC} %-12s  %s\n" "$n" "$iface" "${cidr:-(sem ip)}"
            ((n++))
        done
        echo ""
        local _p
        echo -ne "${YLW}  Interface WAN [padrão: ${auto_wan:-enp0s3}]: ${NC}"
        read -r _p; _p="${_p:-${auto_wan:-enp0s3}}"
        [[ "$_p" =~ ^[0-9]+$ ]] && auto_wan="${ifaces[$((_p-1))]:-$_p}" || auto_wan="$_p"
        echo -ne "${YLW}  Interface LAN [padrão: ${auto_lan:-enp0s8}]: ${NC}"
        read -r _p; _p="${_p:-${auto_lan:-enp0s8}}"
        [[ "$_p" =~ ^[0-9]+$ ]] && auto_lan="${ifaces[$((_p-1))]:-$_p}" || auto_lan="$_p"
    fi

    WAN_IFACE="$auto_wan"
    LAN_IFACE="$auto_lan"
    [[ -n "$auto_net_wan" ]] && NET_EXT="$auto_net_wan"

    # ── Validação básica ──────────────────────────────────────────────────────
    if [[ -z "$WAN_IFACE" || -z "$LAN_IFACE" ]]; then
        err "Interfaces não definidas. Abortando."; exit 1
    fi
    if [[ "$WAN_IFACE" == "$LAN_IFACE" ]]; then
        err "WAN e LAN são a mesma interface ($WAN_IFACE). Abortando."; exit 1
    fi

    # ──────────────────────────────────────────────────────────────────────────
    # PASSO 0b — MODO DE ENDEREÇAMENTO POR INTERFACE
    # ──────────────────────────────────────────────────────────────────────────
    echo ""
    hdr "0b. ENDEREÇAMENTO — WAN ($WAN_IFACE)"

    # Detectar se provavelmente está em DHCP
    local wan_dhcp_hint=""
    [[ "$auto_wan_mode" == "dhcp" ]] && wan_dhcp_hint=" ${YLW}(detectado: DHCP)${NC}"

    echo -e "  IP atual: ${BLD}${auto_wan_ip:-(sem ip)}${NC}${wan_dhcp_hint}"
    echo ""
    echo -e "  ${BLD}[1]${NC} ${GRN}DHCP${NC}     — IP obtido automaticamente do roteador"
    echo -e "  ${BLD}[2]${NC} ${CYN}Estático${NC} — IP fixo configurado manualmente"
    echo ""

    # Sugestão: se detectou DHCP sugere 1, senão sugere 2
    local wan_default; [[ "$auto_wan_mode" == "dhcp" ]] && wan_default=1 || wan_default=2
    echo -ne "  ${YLW}Escolha [1/2, padrão: $wan_default]: ${NC}"
    local wan_choice; read -r wan_choice
    wan_choice="${wan_choice:-$wan_default}"

    if [[ "$wan_choice" == "1" ]]; then
        WAN_MODE="dhcp"
        WAN_IP="${auto_wan_ip:-dhcp}"
        GW_IP="${auto_gw:-}"
        ok "WAN: $WAN_IFACE — DHCP (IP gerenciado pelo roteador)"
    else
        WAN_MODE="static"
        echo ""
        echo -ne "  ${YLW}  IP WAN     [padrão: ${auto_wan_ip:-10.14.29.1}]: ${NC}"
        read -r WAN_IP; WAN_IP="${WAN_IP:-${auto_wan_ip:-10.14.29.1}}"

        echo -ne "  ${YLW}  Máscara    [padrão: /24]: /${NC}"
        local wan_prefix; read -r wan_prefix; wan_prefix="${wan_prefix:-24}"
        # Recalcular NET_EXT com o IP e prefixo fornecidos
        local wan_base; wan_base=$(echo "$WAN_IP" | cut -d. -f1-3)
        NET_EXT="${wan_base}.0/${wan_prefix}"

        echo -ne "  ${YLW}  Gateway    [padrão: ${auto_gw:-10.14.29.1}]: ${NC}"
        read -r GW_IP; GW_IP="${GW_IP:-${auto_gw:-10.14.29.1}}"

        ok "WAN: $WAN_IFACE — estático | $WAN_IP/$wan_prefix | GW: $GW_IP"
    fi

    # ── LAN ──────────────────────────────────────────────────────────────────
    echo ""
    hdr "0c. ENDEREÇAMENTO — LAN ($LAN_IFACE)"
    echo -e "  IP atual: ${BLD}${auto_lan_ip:-(sem ip)}${NC}"
    echo ""
    echo -e "  ${BLD}[1]${NC} DHCP     — IP obtido automaticamente ${YLW}(não recomendado para gateway)${NC}"
    echo -e "  ${BLD}[2]${NC} ${CYN}Estático${NC} — IP fixo ${GRN}(recomendado)${NC}"
    echo ""
    echo -ne "  ${YLW}Escolha [1/2, padrão: 2]: ${NC}"
    local lan_choice; read -r lan_choice; lan_choice="${lan_choice:-2}"

    if [[ "$lan_choice" == "1" ]]; then
        LAN_MODE="dhcp"
        LAN_IP="${auto_lan_ip:-dhcp}"
        warn "LAN em DHCP: o IP do gateway pode mudar — configure reserva no DHCP server"
        ok "LAN: $LAN_IFACE — DHCP"
    else
        LAN_MODE="static"
        echo ""
        echo -ne "  ${YLW}  IP LAN     [padrão: 192.168.0.1]: ${NC}"
        read -r LAN_IP; LAN_IP="${LAN_IP:-192.168.0.1}"

        echo -ne "  ${YLW}  Máscara    [padrão: /24]: /${NC}"
        local lan_prefix; read -r lan_prefix; lan_prefix="${lan_prefix:-24}"

        ok "LAN: $LAN_IFACE — estático | $LAN_IP/$lan_prefix"
    fi

    # ── Resumo final antes de prosseguir ─────────────────────────────────────
    echo ""
    echo -e "${BLD}${CYN}══ Resumo — /etc/network/interfaces ══${NC}"
    echo ""
    if [[ "$WAN_MODE" == "dhcp" ]]; then
        echo -e "  auto $WAN_IFACE"
        echo -e "  iface $WAN_IFACE inet ${GRN}dhcp${NC}"
    else
        echo -e "  auto $WAN_IFACE"
        echo -e "  iface $WAN_IFACE inet ${CYN}static${NC}"
        echo -e "      address $WAN_IP/${wan_prefix:-24}"
        echo -e "      gateway $GW_IP"
    fi
    echo ""
    if [[ "$LAN_MODE" == "dhcp" ]]; then
        echo -e "  auto $LAN_IFACE"
        echo -e "  iface $LAN_IFACE inet ${GRN}dhcp${NC}"
    else
        echo -e "  auto $LAN_IFACE"
        echo -e "  iface $LAN_IFACE inet ${CYN}static${NC}"
        echo -e "      address $LAN_IP/${lan_prefix:-24}"
    fi
    echo ""
    echo -ne "  ${BLD}Prosseguir com a instalação? [ENTER/n]: ${NC}"
    local final_resp; read -r final_resp
    if [[ "${final_resp,,}" == "n" ]]; then
        warn "Instalação cancelada pelo usuário."
        exit 0
    fi

    echo ""
    ok "WAN : $WAN_IFACE | ${WAN_IP} | modo: ${WAN_MODE} | GW: ${GW_IP}"
    ok "LAN : $LAN_IFACE | ${LAN_IP} | modo: ${LAN_MODE}"
    ok "NET : WAN=${NET_EXT} | LAN=${NET_INT}"
}

detect_and_confirm

# ── Variáveis globais ──────────────────────────────────────────────────────────
NET_INT="192.168.0.0/24"
# NET_EXT: usa o valor detectado automaticamente se disponível, senão fallback
NET_EXT="${NET_EXT:-10.14.29.0/24}"
DNS1="10.14.8.20"
DNS2="10.1.6.222"
DNS3="10.14.8.16"
DNS4="8.8.8.8"
DNS5="1.1.1.1"
PROXY_PORT=3128
PROXY_PORT_PLAIN=3129
CA_DIR="/etc/squid/ssl"
CA_KEY="$CA_DIR/squid-ca.key"
CA_CERT="$CA_DIR/squid-ca.crt"
SSL_DB="/var/lib/squid/ssl_db"
GW_CONF="/etc/gateway"
LIST_DIR="$GW_CONF/lists"

# Criar apenas diretórios que não dependem de pacotes externos
mkdir -p "$GW_CONF" "$LIST_DIR"
# CA_DIR (/etc/squid/ssl) é criado após instalação do squid (passo 8)

# Salvar config (somente variáveis simples — sem espaços nem caracteres especiais)
cat > "$GW_CONF/config" << CONF
WAN_IFACE=$WAN_IFACE
LAN_IFACE=$LAN_IFACE
WAN_IP=$WAN_IP
LAN_IP=$LAN_IP
GW_IP=$GW_IP
NET_INT=$NET_INT
NET_EXT=$NET_EXT
DNS1=$DNS1
DNS2=$DNS2
DNS3=$DNS3
DNS4=$DNS4
DNS5=$DNS5
PROXY_PORT=$PROXY_PORT
PROXY_PORT_PLAIN=$PROXY_PORT_PLAIN
CA_DIR=$CA_DIR
CA_KEY=$CA_KEY
CA_CERT=$CA_CERT
SSL_DB=$SSL_DB
CONF

# =============================================================================
# PASSO 1 — PACOTES
# =============================================================================
hdr "1. INSTALAÇÃO DE PACOTES"

install_packages() {
    info "Atualizando repositórios..."
    # 2>/dev/null suprime ruídos de ambiente virtual (AF_VSOCK etc.)
    apt-get update -qq 2>/dev/null

    local pkgs=(
        sudo curl wget vim nano
        net-tools iproute2 nftables
        bind9 bind9utils
        chrony
        openssl ca-certificates libssl-dev
        nginx-light
        logrotate fail2ban
        dnsutils iputils-ping tcpdump nmap
        htop iotop nethogs
        unattended-upgrades
    )

    info "Instalando pacotes base..."
    apt-get install -y "${pkgs[@]}" 2>/dev/null \
        | grep -E "^(Get:|Unpacking|Setting up)" || true

    # ── Squid: tentar variante com SSL embutido ────────────────────────────────
    # Debian 13: pacote 'squid' já tem OpenSSL compilado.
    # Debian 11/12: precisa de 'squid-openssl'.
    info "Detectando pacote Squid com suporte SSL..."

    SQUID_HAS_SSL=0
    SQUID_PKG=""

    # Função: verifica se o binário squid atual tem SSL
    squid_ssl_ok() {
        command -v squid &>/dev/null || return 1
        # Verificar pela presença do certgen (indicador mais confiável)
        find /usr -name "security_file_certgen" -executable 2>/dev/null \
            | grep -q . && return 0
        # Verificar pelo output de squid -v
        squid -v 2>/dev/null \
            | grep -qi "\-\-with-openssl\|\-\-enable-ssl\|openssl" && return 0
        return 1
    }

    for pkg in squid squid-openssl; do
        if apt-cache show "$pkg" &>/dev/null; then
            apt-get install -y "$pkg" 2>/dev/null \
                | grep -E "^(Get:|Unpacking|Setting up)" || true
            if squid_ssl_ok; then
                SQUID_PKG="$pkg"
                SQUID_HAS_SSL=1
                ok "Squid COM SSL: $pkg"
                break
            fi
        fi
    done

    if [[ -z "$SQUID_PKG" ]]; then
        # Garantir que pelo menos o squid básico está instalado
        apt-get install -y squid 2>/dev/null || true
        SQUID_PKG="squid"
        SQUID_HAS_SSL=0
        warn "Squid instalado SEM suporte SSL — HTTPS será tunelado (sem inspeção)"
    fi

    info "squid -v (resumo):"
    squid -v 2>/dev/null | head -3 | sed 's/^/  /'
    CERTGEN=$(find /usr -name "security_file_certgen" -executable 2>/dev/null | head -1 || true)
    info "security_file_certgen: ${CERTGEN:-(não encontrado)}"

    # Persistir na config
    {
        echo "SQUID_HAS_SSL=$SQUID_HAS_SSL"
        echo "SQUID_PKG=$SQUID_PKG"
        echo "CERTGEN=${CERTGEN:-}"
    } >> "$GW_CONF/config"

    ok "Pacotes OK | Squid: $SQUID_PKG | SSL Bump: $([[ $SQUID_HAS_SSL -eq 1 ]] && echo SIM || echo NÃO)"
}

install_packages

# =============================================================================
# PASSO 2 — SYSCTL (IP forwarding + hardening)
# =============================================================================
hdr "2. SYSCTL — IP FORWARDING E HARDENING"

configure_sysctl() {
    cat > /etc/sysctl.d/99-gateway.conf << 'SYSCTL'
# Gateway Debian 13 — IP Forwarding e hardening
net.ipv4.ip_forward = 1

# Desabilitar IPv6 completamente
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1

# Proteção antispoofing
net.ipv4.conf.all.rp_filter              = 2
net.ipv4.conf.default.rp_filter          = 1
net.ipv4.conf.all.accept_redirects       = 0
net.ipv4.conf.all.send_redirects         = 0
net.ipv4.conf.all.accept_source_route    = 0
net.ipv4.icmp_echo_ignore_broadcasts     = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians           = 1
net.ipv4.tcp_syncookies                  = 1

# Performance de rede
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog  = 5000
net.ipv4.tcp_fin_timeout     = 30
net.ipv4.ip_local_port_range = 1024 65535
SYSCTL

    sysctl -p /etc/sysctl.d/99-gateway.conf >/dev/null 2>&1 \
        && ok "sysctl aplicado: IP forwarding ativo, IPv6 desabilitado" \
        || soft_err "sysctl: falha ao aplicar — verifique /etc/sysctl.d/99-gateway.conf"
}

configure_sysctl

# =============================================================================
# PASSO 3 — INTERFACES DE REDE
# =============================================================================
hdr "3. CONFIGURAÇÃO DE REDE (/etc/network/interfaces)"

configure_network() {
    # Verificar se systemd-networkd ou NetworkManager estão ativos
    if systemctl is-active NetworkManager &>/dev/null; then
        warn "NetworkManager detectado — /etc/network/interfaces pode ser ignorado"
        warn "Configure as interfaces manualmente via nmcli ou nmtui após a instalação"
    fi

    [[ -f /etc/network/interfaces ]] && \
        cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"

    # Montar blocos WAN e LAN conforme modo escolhido (DHCP ou estático)
    local wan_pfx lan_pfx
    wan_pfx=$(echo "${NET_EXT:-10.14.29.0/24}" | cut -d/ -f2)
    lan_pfx="24"

    {
        echo "# Gerado pelo gateway-setup.sh — $(date '+%d/%m/%Y %H:%M')"
        echo "# Debian 13 — ifupdown"
        echo "source /etc/network/interfaces.d/*"
        echo ""
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        if [[ "${WAN_MODE:-static}" == "dhcp" ]]; then
            echo "# WAN — DHCP (IP gerenciado pelo roteador)"
            echo "auto $WAN_IFACE"
            echo "iface $WAN_IFACE inet dhcp"
        else
            echo "# WAN — estático | ${NET_EXT}"
            echo "auto $WAN_IFACE"
            echo "iface $WAN_IFACE inet static"
            echo "    address $WAN_IP/${wan_pfx}"
            echo "    gateway $GW_IP"
            echo "    dns-nameservers $DNS1 $DNS2 $DNS3"
        fi
        echo ""
        if [[ "${LAN_MODE:-static}" == "dhcp" ]]; then
            echo "# LAN — DHCP"
            echo "auto $LAN_IFACE"
            echo "iface $LAN_IFACE inet dhcp"
        else
            echo "# LAN — estático | ${NET_INT}"
            echo "auto $LAN_IFACE"
            echo "iface $LAN_IFACE inet static"
            echo "    address $LAN_IP/${lan_pfx}"
        fi
    } > /etc/network/interfaces

    # Instalar ifupdown se não estiver presente (Debian 13 pode usar só systemd-networkd)
    if ! command -v ifup &>/dev/null; then
        apt-get install -y ifupdown 2>/dev/null || true
    fi

    ok "interfaces: WAN=$WAN_IFACE (${WAN_MODE}) | LAN=$LAN_IFACE (${LAN_MODE})"
    [[ "${WAN_MODE}" == "static" ]] && ok "  WAN IP : $WAN_IP/$wan_pfx | GW: $GW_IP"
    [[ "${LAN_MODE}" == "static" ]] && ok "  LAN IP : $LAN_IP/$lan_pfx"
    warn "Reinicie o sistema para aplicar as configurações de rede"
}

configure_network

# =============================================================================
# PASSO 4 — LISTAS DE CONTROLE
# =============================================================================
hdr "4. LISTAS DE CONTROLE DE ACESSO"

create_lists() {

cat > "$LIST_DIR/ips_livres.conf" << 'EOF'
# IPs LIVRES — acesso total, sem proxy obrigatório
# Um IP ou CIDR por linha. Linhas com # são ignoradas.
# 192.168.0.10
# 192.168.0.100
EOF

cat > "$LIST_DIR/ips_parciais.conf" << 'EOF'
# IPs PARCIAIS — acesso apenas a sites gov + bancos
# 192.168.0.50
EOF

cat > "$LIST_DIR/ips_restritos.conf" << 'EOF'
# IPs RESTRITOS — bloqueado exceto lista_sites_liberados
# 192.168.0.200
EOF

cat > "$LIST_DIR/sites_liberados.conf" << 'EOF'
# SITES LIBERADOS — acesso permitido para todos
# Microsoft — .microsoft.com cobre .teams, .update, .sharepoint, .live etc.
.microsoft.com
.office.com
.office365.com
.microsoftonline.com
.google.com
.googleapis.com
.gstatic.com
.gmail.com
.googleusercontent.com
.adobe.com
.acrobat.com
.debian.org
.ubuntu.com
.canonical.com
EOF

cat > "$LIST_DIR/sites_bloqueados.conf" << 'EOF'
# SITES BLOQUEADOS — negado para todos
.instagram.com
.tiktok.com
.twitter.com
.x.com
.reddit.com
.snapchat.com
.pinterest.com
.tumblr.com
.discord.com
.netflix.com
.globoplay.com
.primevideo.com
.hulu.com
.disneyplus.com
.twitch.tv
.thepiratebay.org
.torrentz.eu
.1337x.to
.bet365.com
.sportingbet.com
.betano.com.br
.pornhub.com
.xvideos.com
.xnxx.com
EOF

cat > "$LIST_DIR/sites_governo.conf" << 'EOF'
# SITES GOVERNAMENTAIS — sempre liberados
# Regra: listar apenas domínios PAI — subdomínios são cobertos automaticamente
# Exemplo: .gov.br cobre .sp.gov.br, .tcu.gov.br, .receita.fazenda.gov.br etc.
#          .jus.br cobre .tjsp.jus.br, .stf.jus.br, .esaj.tjsp.jus.br etc.
#          .org.br cobre .oab.org.br, .oabsp.org.br, .senai.org.br etc.

# Domínios pai — cobrem TODOS os subdomínios
.gov.br
.jus.br
.mp.br
.def.br
.leg.br
.org.br

# Não-gov mas sempre liberados
.correios.com.br
.imprensaoficial.com.br
.sapadvogado.com.br
.sebrae.com.br
.sesc.com.br
.senac.br
EOF

cat > "$LIST_DIR/sites_bancos.conf" << 'EOF'
# SITES BANCÁRIOS — sempre liberados
.caixa.gov.br
.bb.com.br
.bancodobrasil.com.br
.bradesco.com.br
.itau.com.br
.santander.com.br
.nubank.com.br
.inter.co
.bancointer.com.br
.c6bank.com.br
.original.com.br
.picpay.com
.pagseguro.com.br
.pagbank.com.br
.mercadopago.com.br
.paypal.com
.stone.com.br
.cielo.com.br
.rede.com.br
.getnet.com.br
.sicredi.com.br
.sicoob.com.br
.banrisul.com.br
.safra.com.br
.bmg.com.br
.xpi.com.br
.xp.com.br
.btgpactual.com
.febraban.org.br
.openbanking.org.br
.pix.bcb.gov.br
EOF

# Regex gov para Squid (dstdom_regex)
cat > "$LIST_DIR/sites_gov_regex.acl" << 'EOF'
\.gov\.br$
\.jus\.br$
\.mp\.br$
\.def\.br$
\.leg\.br$
\.org\.br$
\.tjsp\.jus\.br$
\.sp\.gov\.br$
\.sap\.sp\.gov\.br$
\.policiapenal\.sp\.gov\.br$
EOF

# Domínios com certificate pinning — NÃO interceptar com SSL Bump
cat > "$LIST_DIR/ssl_nobump.acl" << 'EOF'
# Domínios com certificate pinning — splice (passar sem interceptar)
.google.com
.googleapis.com
.gstatic.com
.gvt1.com
.gvt2.com
.android.com
.google-analytics.com
.apple.com
.icloud.com
.microsoft.com
.live.com
.microsoftonline.com
.windowsupdate.com
# Bancos com pinning agressivo
.bradesco.com.br
.itau.com.br
.santander.com.br
.bb.com.br
# .caixa.gov.br coberto por .gov.br acima
.nubank.com.br
.inter.co
# Gov federal — splice (sem SSL Bump) para evitar erros de certificado
# .gov.br cobre: .receita.fazenda.gov.br, .esocial.gov.br, .nfe.fazenda.gov.br etc.
# .jus.br cobre: .tjsp.jus.br, .stf.jus.br, .esaj.tjsp.jus.br, .pje.jus.br etc.
.gov.br
.jus.br
# Adicione domínios problemáticos abaixo:
EOF

ok "Listas criadas em $LIST_DIR"
}

create_lists

# =============================================================================
# PASSO 5 — DNS (BIND9)
# =============================================================================
hdr "5. DNS — BIND9 (named)"

configure_dns() {
    # ── Detectar usuário do bind ──────────────────────────────────────────────
    local bind_user bind_grp
    bind_user=$(id -un bind 2>/dev/null || id -un named 2>/dev/null || echo root)
    bind_grp=$(id -gn bind 2>/dev/null || id -gn named 2>/dev/null || echo root)
    info "Usuário bind: $bind_user:$bind_grp"

    # ── Backup ────────────────────────────────────────────────────────────────
    [[ -d /etc/bind ]] &&         cp -r /etc/bind "/etc/bind.bak.$(date +%s)" 2>/dev/null || true

    # ── Criar todos os diretórios necessários ─────────────────────────────────
    mkdir -p /etc/bind/zones /var/cache/bind /run/named
    # Garantir que rndc.key existe (gerado pelo bind9 na instalação)
    if [[ ! -f /etc/bind/rndc.key ]]; then
        rndc-confgen -a -c /etc/bind/rndc.key 2>/dev/null || true
    fi
    # /var/log/bind removido: logging agora via syslog, sem arquivo

    # ── AppArmor: desabilitar ANTES de qualquer operação ─────────────────────
    if command -v aa-status &>/dev/null 2>&1; then
        if aa-status 2>/dev/null | grep -q "named"; then
            info "AppArmor: desabilitando perfil do named..."
            aa-complain /usr/sbin/named 2>/dev/null || true
            # Tentar desabilitar completamente
            local aa_profile="/etc/apparmor.d/usr.sbin.named"
            if [[ -f "$aa_profile" ]]; then
                mkdir -p /etc/apparmor.d/disable
                ln -sf "$aa_profile" /etc/apparmor.d/disable/ 2>/dev/null || true
                apparmor_parser -R "$aa_profile" 2>/dev/null || true
                info "AppArmor: perfil named desabilitado"
            fi
        fi
    fi

    # CRÍTICO: chown ANTES de criar qualquer arquivo — named roda como bind
    chown "$bind_user:$bind_grp" /etc/bind/zones /var/cache/bind /run/named         2>/dev/null || true
    chmod 775 /var/cache/bind /run/named 2>/dev/null || true
    chmod 755 /etc/bind/zones 2>/dev/null || true
    # /etc/bind em si precisa ser legível pelo bind
    chown root:"$bind_grp" /etc/bind 2>/dev/null || true
    chmod 755 /etc/bind 2>/dev/null || true

    # named.conf.options — compatível com BIND 9.18-9.20 (Debian 13)
    # Diretivas removidas: max/min-cache-ttl, recursive-clients, server-id,
    #                      hostname (todas obsoletas/removidas no BIND 9.18+)
    cat > /etc/bind/named.conf.options << OPTIONS
options {
    directory "/var/cache/bind";

    forwarders {
        $DNS1;
        $DNS2;
        $DNS3;
        $DNS4;
        $DNS5;
    };
    forward only;

    listen-on    { any; };
    listen-on-v6 { none; };

    allow-query     { localhost; $NET_INT; $NET_EXT; };
    allow-recursion { localhost; $NET_INT; $NET_EXT; };
    allow-transfer  { none; };

    dnssec-validation no;
    auth-nxdomain no;
    version none;

    // Aceitar nomes com caracteres não-padrão (sites gov com underscores etc)
    check-names master   ignore;
    check-names response ignore;

    max-cache-size 256m;
    // TTL mínimo — melhora resolução de sites gov com TTL muito baixo
    min-cache-ttl 30;
};

// Logging via syslog (sem arquivo) — evita problemas de permissão/AppArmor
// Os logs ficam disponíveis via: journalctl -u named
logging {
    channel default_syslog {
        syslog daemon;
        severity info;
    };
    channel null_log {
        null;
    };
    category default { default_syslog; };
    category queries { null_log; };
};
OPTIONS

    # ── Reescrever named.conf PRINCIPAL ─────────────────────────────────────
    # O Debian 13 instala um named.conf que inclui default-zones e outros
    # arquivos que podem conflitar. Reescrevemos com inclusões controladas.
    cat > /etc/bind/named.conf << 'NAMEDCONF'
// named.conf — gerado pelo gateway-setup.sh
// Debian 13 BIND 9.20

include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
NAMEDCONF

    # Calcular zona reversa WAN dinamicamente
    local wan_rev_zone
    wan_rev_zone=$(echo "$WAN_IP" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')

    # named.conf.local com nossas zonas
    cat > /etc/bind/named.conf.local << LOCAL
// Zonas locais do gateway — gerado automaticamente
zone "gateway.local" {
    type master;
    file "/etc/bind/zones/gateway.local.zone";
};
zone "0.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/192.168.0.rev";
};
zone "${wan_rev_zone}" {
    type master;
    file "/etc/bind/zones/wan.rev";
};
LOCAL

    # ── Zonas forward condicionais — Intranet Gov SP ────────────────────────
    # Cada domínio vai para o DNS que sabe resolvê-lo
    # DNS1 (10.14.8.20) resolve policiapenal.sp.gov.br
    # DNS2 (10.1.6.222) resolve cartoriosap.sp.gov.br
    cat >> /etc/bind/named.conf.local << ZONAS_FORWARD
// Zonas forward condicionais — Intranet Gov SP
zone "policiapenal.sp.gov.br"     { type forward; forwarders { $DNS1; }; forward only; };
zone "gpu.policiapenal.sp.gov.br" { type forward; forwarders { $DNS1; }; forward only; };
zone "cartoriosap.sp.gov.br"      { type forward; forwarders { $DNS2; }; forward only; };
zone "new.cartoriosap.sp.gov.br"  { type forward; forwarders { $DNS2; }; forward only; };
zone "sap.sp.gov.br"              { type forward; forwarders { $DNS2; $DNS1; }; forward only; };
zone "sp.gov.br"                  { type forward; forwarders { $DNS1; $DNS2; $DNS3; }; forward only; };
zone "tjsp.jus.br"                { type forward; forwarders { $DNS1; $DNS2; }; forward only; };
zone "esaj.tjsp.jus.br"           { type forward; forwarders { $DNS1; $DNS2; }; forward only; };
zone "pje.jus.br"                 { type forward; forwarders { $DNS1; $DNS2; }; forward only; };
ZONAS_FORWARD
    ok "Zonas forward condicionais adicionadas (policiapenal→$DNS1, cartoriosap→$DNS2)"

    local serial lan_oct wan_oct
    serial=$(date +%Y%m%d01)
    lan_oct=$(echo "$LAN_IP" | cut -d. -f4)
    wan_oct=$(echo "$WAN_IP" | cut -d. -f4)

    # Zona direta — \$ escapa o $ do DNS ($TTL, $ORIGIN)
    cat > /etc/bind/zones/gateway.local.zone << ZONE
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              $serial ; serial
              3600    ; refresh
              1800    ; retry
              604800  ; expire
              300 )   ; minimum
    IN NS  ns1.gateway.local.
ns1     IN A $LAN_IP
gateway IN A $LAN_IP
proxy   IN A $LAN_IP
dns     IN A $LAN_IP
wpad    IN A $LAN_IP
ZONE

    cat > /etc/bind/zones/192.168.0.rev << RZONE
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              $serial 3600 1800 604800 300 )
    IN NS  ns1.gateway.local.
$lan_oct IN PTR gateway.local.
RZONE

    cat > /etc/bind/zones/wan.rev << RZONE
\$TTL 3600
@   IN SOA ns1.gateway.local. admin.gateway.local. (
              $serial 3600 1800 604800 300 )
    IN NS  ns1.gateway.local.
$wan_oct IN PTR gateway.local.
RZONE

    if named-checkconf /etc/bind/named.conf 2>&1; then
        ok "named.conf: sintaxe válida"
    else
        soft_err "named.conf: erro de sintaxe"
        named-checkconf /etc/bind/named.conf 2>&1 | head -5
    fi

    # resolv.conf — apontar para DNS local
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << RESOLV
# Gerenciado pelo gateway-setup.sh — não editar manualmente
nameserver 127.0.0.1
nameserver $DNS1
nameserver $DNS2
search gateway.local
RESOLV
    chattr +i /etc/resolv.conf 2>/dev/null || true  # falha silenciosa em tmpfs/overlay

    # Debian 13: bind9.service É SYMLINK para named.service.
    # "systemctl enable bind9" SEMPRE falha: "Refusing to operate on linked unit".
    # Solução definitiva: detectar se é symlink, usar "named" diretamente.
    local dns_svc="named"
    local fpath
    fpath=$(systemctl show -p FragmentPath bind9.service 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$fpath" && -L "$fpath" ]]; then
        dns_svc="named"
        info "bind9.service é symlink -> usando named.service"
    elif systemctl cat named.service &>/dev/null 2>&1; then
        dns_svc="named"
    fi

    # ── Permissões finais — CRÍTICO para o named iniciar ────────────────────
    # ── Permissões finais — bind precisa ler todos os arquivos ───────────────
    chown "$bind_user:$bind_grp"         /etc/bind/named.conf         /etc/bind/named.conf.options         /etc/bind/named.conf.local         /var/cache/bind         2>/dev/null || true
    chown -R "$bind_user:$bind_grp" /etc/bind/zones 2>/dev/null || true
    chmod 644         /etc/bind/named.conf         /etc/bind/named.conf.options         /etc/bind/named.conf.local         2>/dev/null || true
    chmod 644 /etc/bind/zones/*.zone /etc/bind/zones/*.rev 2>/dev/null || true
    # rndc.key: somente bind pode ler
    chown "$bind_user:$bind_grp" /etc/bind/rndc.key 2>/dev/null || true
    chmod 640 /etc/bind/rndc.key 2>/dev/null || true

    # ── Validar zonas antes de iniciar ───────────────────────────────────────
    local zone_ok=1
    named-checkzone gateway.local /etc/bind/zones/gateway.local.zone 2>&1         | grep -v "^$" | tail -2
    if ! named-checkzone gateway.local /etc/bind/zones/gateway.local.zone             &>/dev/null 2>&1; then
        soft_err "Zona gateway.local inválida"
        zone_ok=0
    fi

    # ── Habilitar e iniciar ────────────────────────────────────────────────
    systemctl enable "$dns_svc" 2>/dev/null         || { warn "enable $dns_svc falhou";              systemctl preset "$dns_svc" 2>/dev/null || true; }

    # Parar qualquer instância anterior antes de reiniciar
    systemctl stop "$dns_svc" 2>/dev/null || true
    sleep 1
    systemctl start "$dns_svc" 2>/dev/null || true
    sleep 3

    if systemctl is-active "$dns_svc" &>/dev/null; then
        ok "DNS ($dns_svc) ativo"
    else
        soft_err "DNS não iniciou — executando diagnóstico automático:"
        echo ""
        # Rodar named em foreground por 2 segundos para capturar erro real
        info "Saída do named -g (erro real):"
        timeout 3 named -g -c /etc/bind/named.conf 2>&1             | grep -v "AF_VSOCK\|^$" | head -20 || true
        echo ""
        info "Verificar permissões:"
        ls -la /etc/bind/named.conf /etc/bind/named.conf.options                /etc/bind/zones/ /var/cache/bind 2>/dev/null | head -10
        echo ""
        info "Comandos para diagnóstico manual:"
        info "  named -g -c /etc/bind/named.conf"
        info "  journalctl -xeu named --no-pager | tail -30"
        info "  ls -la /etc/bind/ /var/cache/bind/"
    fi
}

configure_dns

# =============================================================================
# PASSO 6 — NTP (chrony)
# =============================================================================
hdr "6. NTP — CHRONY"

configure_ntp() {
    # Verificar se chrony está disponível
    if ! command -v chronyd &>/dev/null; then
        apt-get install -y chrony 2>/dev/null || true
    fi

    # Criar diretório chrony se não existir (Debian 13 pode usar /etc/chrony/)
    local chrony_conf
    if [[ -f /etc/chrony/chrony.conf ]]; then
        chrony_conf="/etc/chrony/chrony.conf"
    elif [[ -f /etc/chrony.conf ]]; then
        chrony_conf="/etc/chrony.conf"
    else
        mkdir -p /etc/chrony
        chrony_conf="/etc/chrony/chrony.conf"
    fi
    info "Configurando chrony em: $chrony_conf"
    cat > "$chrony_conf" << 'NTP'
# Servidores NTP brasileiros + mundiais
server a.ntp.br iburst prefer
server b.ntp.br iburst
server c.ntp.br iburst
pool 0.pool.ntp.org iburst
pool 1.pool.ntp.org iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync

logdir /var/log/chrony
log measurements statistics tracking

# Servir horário para redes internas
local stratum 10
NTP

    # Adicionar allow com variáveis expandidas
    printf 'allow %s\nallow %s\n' "$NET_INT" "$NET_EXT"         >> "$chrony_conf"

    timedatectl set-timezone America/Sao_Paulo 2>/dev/null         || ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true

    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony 2>/dev/null || true
    sleep 1

    systemctl is-active chrony &>/dev/null \
        && ok "chrony ativo — Timezone: America/Sao_Paulo" \
        || soft_err "chrony não iniciou"
    chronyc tracking 2>/dev/null | grep -E "Stratum|Reference|Offset" || true
}

configure_ntp

# =============================================================================
# PASSO 7 — NFTABLES
# =============================================================================
hdr "7. NFTABLES — FIREWALL E NAT"

configure_nftables() {

    # ── Script load-nat.sh ────────────────────────────────────────────────────
    cat > "$GW_CONF/load-nat.sh" << 'NATLOAD'
#!/bin/bash
# Reaplica entradas NAT 1:1 após reboot
# shellcheck source=/etc/gateway/config
source /etc/gateway/config
NAT_DB="/etc/gateway/nat-entries.conf"
[[ ! -f "$NAT_DB" ]] && { echo "Nenhuma entrada NAT 1:1 cadastrada."; exit 0; }
added=0; errors=0
while IFS='|' read -r INT EXT DESC; do
    [[ -z "$INT" || "$INT" == \#* ]] && continue
    nft add rule ip nat postrouting \
        oif "$WAN_IFACE" ip saddr "$INT" snat to "$EXT" 2>/dev/null \
    && nft add rule ip nat prerouting \
        iif "$WAN_IFACE" ip daddr "$EXT" dnat to "$INT" 2>/dev/null \
    && ((added++)) || ((errors++))
done < "$NAT_DB"
echo "[$(date '+%d/%m %H:%M')] NAT 1:1: $added adicionadas, $errors erros"
NATLOAD
    chmod +x "$GW_CONF/load-nat.sh"

    # ── Script load-sets.sh ───────────────────────────────────────────────────
    cat > "$GW_CONF/load-sets.sh" << 'SETLOAD'
#!/bin/bash
# Carrega listas de IPs nas sets do nftables
LIST_DIR="/etc/gateway/lists"
for set_name in ips_livres ips_parciais ips_restritos; do
    file="$LIST_DIR/${set_name}.conf"
    [[ ! -f "$file" ]] && continue
    nft flush set inet filter "$set_name" 2>/dev/null || true
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        nft add element inet filter "$set_name" "{ $line }" 2>/dev/null || true
    done < "$file"
done
echo "[$(date '+%d/%m %H:%M')] Sets de IPs recarregados"
SETLOAD
    chmod +x "$GW_CONF/load-sets.sh"

    # ── Banco de entradas NAT 1:1 ─────────────────────────────────────────────
    [[ ! -f "$GW_CONF/nat-entries.conf" ]] && \
    cat > "$GW_CONF/nat-entries.conf" << 'NAT'
# Entradas NAT 1:1 — gerenciado pelo nat-manager
# Formato: IP_INTERNO|IP_EXTERNO|DESCRIÇÃO
# Exemplo: 192.168.0.50|10.14.29.50|Servidor Web
NAT

    # ── Gerar nftables.conf com printf ────────────────────────────────────────
    # CRÍTICO: nftables lê este arquivo sem ambiente bash.
    # Usar printf com %s para escrever valores literais — jamais variáveis bash.
    gen_nftables_conf() {
        local F="/etc/nftables.conf"
        info "Gerando $F (valores literais)..."

        {
        printf '#!/usr/sbin/nft -f\n'
        printf '# nftables — gateway Debian 13 — %s\n\n' "$(date '+%d/%m/%Y %H:%M')"
        printf 'flush ruleset\n\n'

        printf 'table inet filter {\n\n'
        printf '    set ips_livres    { type ipv4_addr; flags interval; }\n'
        printf '    set ips_parciais  { type ipv4_addr; flags interval; }\n'
        printf '    set ips_restritos { type ipv4_addr; flags interval; }\n\n'

        # chain input
        printf '    chain input {\n'
        printf '        type filter hook input priority 0; policy drop;\n\n'
        printf '        iif lo accept\n'
        printf '        ct state established,related accept\n'
        printf '        ct state invalid drop\n'
        printf '        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept\n\n'
        printf '        # SSH\n'
        printf '        ip saddr { %s, %s } tcp dport 22 ct state new accept\n'  "$NET_INT" "$NET_EXT"
        printf '        # DNS\n'
        printf '        ip saddr { %s, %s } udp dport 53 accept\n'               "$NET_INT" "$NET_EXT"
        printf '        ip saddr { %s, %s } tcp dport 53 accept\n'               "$NET_INT" "$NET_EXT"
        printf '        # NTP\n'
        printf '        ip saddr { %s, %s } udp dport 123 accept\n'              "$NET_INT" "$NET_EXT"
        printf '        # HTTP (nginx — CA e WPAD)\n'
        printf '        ip saddr %s tcp dport 80 ct state new accept\n'          "$NET_INT"
        printf '        # Proxy Squid\n'
        printf '        ip saddr %s tcp dport { %s, %s } ct state new accept\n'  "$NET_INT" "$PROXY_PORT" "$PROXY_PORT_PLAIN"
        printf '        limit rate 5/minute log prefix "[NFT-IN-DROP] " level warn\n'
        printf '        drop\n'
        printf '    }\n\n'

        # chain forward
        printf '    chain forward {\n'
        printf '        type filter hook forward priority 0; policy drop;\n\n'
        printf '        ct state established,related accept\n'
        printf '        ct state invalid drop\n'
        printf '        ip protocol icmp accept\n\n'
        printf '        # LAN <-> WAN\n'
        printf '        iif %s oif %s ip saddr %s ip daddr %s accept\n' "$LAN_IFACE" "$WAN_IFACE" "$NET_INT" "$NET_EXT"
        printf '        iif %s oif %s ip saddr %s ip daddr %s accept\n' "$WAN_IFACE" "$LAN_IFACE" "$NET_EXT" "$NET_INT"
        printf '        # LAN -> intranet 10.0.0.0/8 (governo SP e redes internas)\n'
        printf '        iif %s oif %s ip saddr %s ip daddr 10.0.0.0/8 accept\n' "$LAN_IFACE" "$WAN_IFACE" "$NET_INT"
        printf '        iif %s oif %s ip saddr 10.0.0.0/8 ip daddr %s accept\n' "$WAN_IFACE" "$LAN_IFACE" "$NET_INT"
        printf '        # IPs livres — acesso direto\n'
        printf '        iif %s oif %s ip saddr @ips_livres accept\n'    "$LAN_IFACE" "$WAN_IFACE"
        printf '        # DNS para resolvedores externos\n'
        printf '        iif %s oif %s ip daddr { %s, %s, %s, %s, %s } udp dport 53 accept\n' \
            "$LAN_IFACE" "$WAN_IFACE" "$DNS1" "$DNS2" "$DNS3" "$DNS4" "$DNS5"
        printf '        iif %s oif %s ip daddr { %s, %s, %s, %s, %s } tcp dport 53 accept\n' \
            "$LAN_IFACE" "$WAN_IFACE" "$DNS1" "$DNS2" "$DNS3" "$DNS4" "$DNS5"
        printf '        # LAN -> internet (proxy explícito — clientes devem configurar proxy)\n'
        printf '        # Para proxy transparente seria necessário TPROXY (não configurado)\n'
        printf '        iif %s oif %s ip saddr %s accept\n'             "$LAN_IFACE" "$WAN_IFACE" "$NET_INT"
        printf '        limit rate 3/minute log prefix "[NFT-FWD-DROP] " level warn\n'
        printf '        drop\n'
        printf '    }\n\n'

        printf '    chain output {\n'
        printf '        type filter hook output priority 0; policy accept;\n'
        printf '    }\n'
        printf '}\n\n'

        # NAT
        printf 'table ip nat {\n\n'
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority dstnat;\n'
        printf '        # Entradas NAT 1:1 adicionadas pelo nat-manager\n'
        printf '    }\n\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority srcnat;\n'
        printf '        # Entradas NAT 1:1 adicionadas pelo nat-manager\n'
        printf '        # Masquerade padrão (fallback para IPs sem NAT 1:1)\n'
        printf '        # Masquerade para internet e intranet 10.0.0.0/8\n'
        printf '        oif %s ip saddr %s masquerade\n' "$WAN_IFACE" "$NET_INT"
        printf '    }\n'
        printf '}\n'
        } > "$F"

        ok "nftables.conf gerado: $F"
    }

    # ── Aplicar nftables com diagnóstico ──────────────────────────────────────
    apply_nftables() {
        gen_nftables_conf

        info "Validando sintaxe..."
        local check_out
        check_out=$(nft -c -f /etc/nftables.conf 2>&1) || true
        if echo "$check_out" | grep -qi "error"; then
            soft_err "nftables.conf com erro de sintaxe:"
            echo "$check_out"
            return 1
        fi
        ok "Sintaxe nftables.conf válida"

        info "Aplicando ruleset em memória..."
        if nft -f /etc/nftables.conf 2>&1; then
            ok "Ruleset aplicado"
        else
            soft_err "Falha ao aplicar ruleset — execute: sudo fix-nftables"
            return 1
        fi

        # nftables é Type=oneshot — sem RemainAfterExit fica "inactive (dead)"
        # mesmo executando com sucesso. Criar override para manter "active (exited)".
        mkdir -p /etc/systemd/system/nftables.service.d
        cat > /etc/systemd/system/nftables.service.d/override.conf << 'NFTOVERRIDE'
[Service]
RemainAfterExit=yes
ExecReload=/usr/sbin/nft -f /etc/nftables.conf
NFTOVERRIDE

        systemctl daemon-reload
        systemctl enable  nftables 2>/dev/null || true
        systemctl restart nftables 2>/dev/null || true
        sleep 1

        if systemctl is-active nftables &>/dev/null; then
            ok "nftables.service: ATIVO (active exited)"
        else
            # Verificar se o ruleset está em memória mesmo assim
            if nft list ruleset 2>/dev/null | grep -q "table" 2>/dev/null; then
                ok "Ruleset aplicado em memória — serviço marcado como ativo"
                systemctl start nftables 2>/dev/null || true
            else
                soft_err "nftables: ruleset não aplicado — execute: fix-nftables"
            fi
        fi

        "$GW_CONF/load-sets.sh" 2>/dev/null && ok "Sets de IPs carregados" || true
        ok "Firewall configurado | NAT 1:1: use 'nat-manager'"
    }

    apply_nftables
}

configure_nftables

# =============================================================================
# PASSO 8 — CERTIFICADO CA
# =============================================================================
hdr "8. CERTIFICADO CA DO PROXY"

configure_ca() {
    mkdir -p "$CA_DIR" /var/www/html/ca

    if [[ ! -f "$CA_KEY" || ! -f "$CA_CERT" ]]; then
        info "Gerando chave CA RSA 2048 bits..."
        openssl genrsa -out "$CA_KEY" 2048 2>/dev/null \
            || { soft_err "Falha ao gerar chave CA"; return 1; }

        info "Gerando certificado CA (válido 10 anos)..."
        # Extensões obrigatórias para Chrome 90+, Firefox 89+, Edge:
        #   - authorityKeyIdentifier: necessário mesmo em CA raiz auto-assinado
        #   - subjectKeyIdentifier: hash do Subject Key
        #   - basicConstraints: CA:TRUE marca como autoridade raiz
        #   - keyUsage: keyCertSign,cRLSign para assinar certificados
        # Usar arquivo de config temporário para incluir authorityKeyIdentifier
        # (que não pode ser passado via -addext em algumas versões do OpenSSL)
        local ca_ext_file
        ca_ext_file=$(mktemp /tmp/ca_ext_XXXXXX.cnf)
        cat > "$ca_ext_file" << CAEXT
[req]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no

[req_dn]
C  = BR
ST = Sao Paulo
L  = Sao Paulo
O  = Gateway Proxy
OU = TI
CN = Gateway Proxy CA

[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
CAEXT

        openssl req -new -x509 -days 3650             -key "$CA_KEY"             -out "$CA_CERT"             -config "$ca_ext_file"             -extensions v3_ca 2>/dev/null             || { soft_err "Falha ao gerar certificado CA"; rm -f "$ca_ext_file"; return 1; }
        rm -f "$ca_ext_file"

        # Verificar extensões geradas
        local ski aki
        ski=$(openssl x509 -in "$CA_CERT" -noout -text 2>/dev/null | grep -c "Subject Key Identifier")
        aki=$(openssl x509 -in "$CA_CERT" -noout -text 2>/dev/null | grep -c "Authority Key Identifier")
        info "Extensões CA: SubjectKeyId=$ski AuthorityKeyId=$aki (ambos devem ser 1)"

        # Formatos adicionais para diferentes plataformas
        openssl x509 -in "$CA_CERT" -outform DER             -out "$CA_DIR/squid-ca.der" 2>/dev/null || true
        # OpenSSL 3 (Debian 13): usar -legacy para compatibilidade com Windows/iOS
        openssl pkcs12 -export -in "$CA_CERT" -nokeys             -out "$CA_DIR/squid-ca.p12" -passout pass: -legacy 2>/dev/null         || openssl pkcs12 -export -in "$CA_CERT" -nokeys             -out "$CA_DIR/squid-ca.p12" -passout pass: 2>/dev/null || true

        # Instalar CA no sistema
        cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
        update-ca-certificates --fresh 2>/dev/null || true
        ok "CA gerado: $CA_CERT"
    else
        warn "CA já existe — reutilizando"
        info "Validade: $(openssl x509 -in "$CA_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
    fi

    # proxy user pode não existir se squid não foi instalado — ignorar falha
    chown proxy:proxy "$CA_KEY" "$CA_CERT" 2>/dev/null ||         chown root:root "$CA_KEY" "$CA_CERT" 2>/dev/null || true
    chmod 640 "$CA_KEY" 2>/dev/null || true
    chmod 644 "$CA_CERT" 2>/dev/null || true

    # Copiar para webserver
    cp "$CA_CERT" /var/www/html/ca/squid-ca.crt
    [[ -f "$CA_DIR/squid-ca.der" ]] && cp "$CA_DIR/squid-ca.der" /var/www/html/ca/ || true
    [[ -f "$CA_DIR/squid-ca.p12" ]] && cp "$CA_DIR/squid-ca.p12" /var/www/html/ca/ || true

    # Script de instalação automática do CA para clientes Linux
    cat > /var/www/html/ca/install-ca.sh << CASHELL
#!/bin/bash
set -e
echo "Instalando CA do Gateway Proxy..."
curl -fsSL "http://${LAN_IP}/ca/squid-ca.crt" \\
    -o /usr/local/share/ca-certificates/squid-proxy-ca.crt
update-ca-certificates --fresh
# Firefox: instalar via certutil (NSS)
if command -v certutil &>/dev/null; then
    while IFS= read -r db; do
        dir=\$(dirname "\$db")
        certutil -A -n "Gateway Proxy CA" -t "TCu,Cu,Tu" \\
            -i /usr/local/share/ca-certificates/squid-proxy-ca.crt \\
            -d "sql:\$dir" 2>/dev/null \\
            && echo "CA instalado no Firefox: \$dir" || true
    done < <(find /home -name "cert9.db" 2>/dev/null)
fi
echo "Concluído. Reinicie os navegadores."
CASHELL
    chmod +x /var/www/html/ca/install-ca.sh

    # Página HTML de instruções
    cat > /var/www/html/ca/index.html << CAHTML
<!DOCTYPE html>
<html lang="pt-br">
<head>
  <meta charset="UTF-8">
  <title>Instalar CA do Proxy — ${LAN_IP}</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 720px; margin: 40px auto; padding: 20px; line-height: 1.6; }
    h1   { color: #1a56db; }
    h2   { color: #374151; margin-top: 24px; border-bottom: 1px solid #e5e7eb; padding-bottom: 6px; }
    .btn { display: inline-block; padding: 10px 18px; background: #1a56db; color: #fff;
           text-decoration: none; border-radius: 6px; margin: 5px 3px; font-size: 14px; }
    .btn:hover  { background: #1e40af; }
    .btn-g      { background: #059669; } .btn-g:hover { background: #047857; }
    .btn-gr     { background: #6b7280; } .btn-gr:hover { background: #4b5563; }
    pre  { background: #f3f4f6; padding: 14px; border-radius: 6px; overflow-x: auto; font-size: 13px; }
    code { background: #e5e7eb; padding: 2px 6px; border-radius: 4px; font-family: monospace; }
    .note { background: #fef9c3; border-left: 4px solid #f59e0b; padding: 12px; border-radius: 4px; font-size: 13px; margin-top: 20px; }
  </style>
</head>
<body>
  <h1>&#128274; Certificado CA do Proxy</h1>
  <p>Para acessar sites HTTPS sem erros, instale o certificado CA no seu dispositivo.<br>
     Proxy configurado: <code>${LAN_IP}:${PROXY_PORT}</code></p>

  <h2>&#8659; Download</h2>
  <a class="btn"    href="squid-ca.crt">Linux / Chrome / Firefox (.crt)</a>
  <a class="btn btn-g"  href="squid-ca.der">Windows / Android (.der)</a>
  <a class="btn btn-gr" href="squid-ca.p12">macOS / iOS (.p12)</a>

  <h2>Google Chrome / Chromium</h2>
  <ol>
    <li>Acesse <code>chrome://settings/certificates</code></li>
    <li>Aba <b>Autoridades</b> &rarr; <b>Importar</b></li>
    <li>Selecione <code>squid-ca.crt</code> &rarr; marque <b>Confiar para identificar sites</b></li>
  </ol>

  <h2>Mozilla Firefox</h2>
  <ol>
    <li>Menu &#9776; &rarr; Configurações &rarr; Privacidade &rarr; <b>Ver Certificados</b></li>
    <li>Aba <b>Autoridades</b> &rarr; <b>Importar</b></li>
    <li>Selecione <code>squid-ca.crt</code> &rarr; marque <b>Confiar para identificar sites</b></li>
  </ol>

  <h2>Windows (sistema inteiro)</h2>
  <ol>
    <li>Clique duplo em <code>squid-ca.der</code> &rarr; <b>Instalar Certificado</b></li>
    <li>Selecione <b>Computador Local</b> &rarr; Avançar</li>
    <li><b>Autoridades de Certificação Raiz Confiáveis</b> &rarr; Concluir &rarr; Sim</li>
  </ol>

  <h2>Linux (automatico)</h2>
  <pre>curl -s http://${LAN_IP}/ca/install-ca.sh | sudo bash</pre>

  <h2>Linux (manual)</h2>
  <pre>sudo cp squid-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates</pre>

  <div class="note">
    &#9888; Este certificado &eacute; exclusivo para a rede interna corporativa.
    N&atilde;o distribua fora da organiza&ccedil;&atilde;o. V&aacute;lido por 10 anos.
  </div>
</body>
</html>
CAHTML

    ok "CA pronto | Download: http://${LAN_IP}/ca/"
}

configure_ca

# =============================================================================
# PASSO 9 — SQUID
# =============================================================================
hdr "9. SQUID — PROXY EXPLÍCITO + SSL BUMP"

configure_squid() {
    # Re-carregar config (SQUID_HAS_SSL etc. foram salvos após install_packages)
    source "$GW_CONF/config" 2>/dev/null || true
    # Defaults seguros se variáveis não foram salvas
    SQUID_HAS_SSL="${SQUID_HAS_SSL:-0}"
    CERTGEN="${CERTGEN:-}"
    SQUID_PKG="${SQUID_PKG:-squid}"

    mkdir -p /etc/squid/lists /var/log/squid /var/cache/squid
    chown -R proxy:proxy /var/log/squid /var/cache/squid 2>/dev/null || true

    # Sincronizar listas
    for f in ips_livres ips_parciais ips_restritos \
              sites_liberados sites_bloqueados sites_governo sites_bancos; do
        cp "$LIST_DIR/${f}.conf" "/etc/squid/lists/${f}.acl" 2>/dev/null || true
    done
    cp "$LIST_DIR/sites_gov_regex.acl" /etc/squid/lists/ 2>/dev/null || true
    cp "$LIST_DIR/ssl_nobump.acl"      /etc/squid/lists/ 2>/dev/null || true

    # ── Detectar security_file_certgen ────────────────────────────────────────
    local certgen=""
    for p in \
        /usr/lib/squid/security_file_certgen \
        /usr/lib/squid5/security_file_certgen \
        /usr/lib/x86_64-linux-gnu/squid/security_file_certgen \
        /usr/lib/aarch64-linux-gnu/squid/security_file_certgen \
        /usr/libexec/squid/security_file_certgen; do
        [[ -x "$p" ]] && { certgen="$p"; break; }
    done
    [[ -z "$certgen" ]] && \
        certgen=$(find /usr -name "security_file_certgen" -executable 2>/dev/null | head -1)
    [[ -n "$certgen" ]] && ok "certgen: $certgen" \
        || warn "security_file_certgen não encontrado — SSL Bump desativado"

    # ── Inicializar SSL DB ────────────────────────────────────────────────────
    if [[ "${SQUID_HAS_SSL:-0}" == "1" && -n "$certgen" ]]; then
        info "Inicializando SSL certificate database..."
        # Garantir diretório pai limpo e com permissões corretas
        rm -rf "$SSL_DB"
        mkdir -p "$(dirname "$SSL_DB")"
        # Criar o SSL DB como usuário proxy (necessário para o certgen funcionar)
        local db_out
        db_out=$("$certgen" -c -s "$SSL_DB" -M 256MB 2>&1) ||         db_out=$(sudo -u proxy "$certgen" -c -s "$SSL_DB" -M 256MB 2>&1) || true
        if [[ -d "$SSL_DB" && -n "$(ls -A "$SSL_DB" 2>/dev/null)" ]]; then
            chown -R proxy:proxy "$SSL_DB"
            chmod -R 750 "$SSL_DB"
            ok "SSL DB criado: $SSL_DB"
        else
            soft_err "Falha ao criar SSL DB: $db_out"
            warn "SSL Bump pode não funcionar. Execute manualmente:"
            warn "  rm -rf $SSL_DB && $certgen -c -s $SSL_DB -M 256MB"
            warn "  chown -R proxy:proxy $SSL_DB"
        fi
    fi

    # ── Gerar dhparam (SÍNCRONO) ──────────────────────────────────────────────
    if [[ "${SQUID_HAS_SSL:-0}" == "1" && -n "$certgen" ]]; then
        info "Gerando parâmetros DH 2048 bits (aguarde ~30-60s)..."
        if openssl dhparam -out "$CA_DIR/dhparam.pem" 2048 2>/dev/null; then
            chown proxy:proxy "$CA_DIR/dhparam.pem"
            ok "dhparam.pem gerado"
        else
            warn "Falha ao gerar dhparam — continuando sem PFS"
        fi
    fi

    # ── Construir diretivas de porta e SSL ────────────────────────────────────
    local port_conf sslcrtd_conf sslbump_conf

    if [[ "${SQUID_HAS_SSL:-0}" == "1" && -n "$certgen" && -f "$CA_CERT" ]]; then
        port_conf="# Porta principal: proxy explícito + SSL Bump
http_port ${PROXY_PORT} ssl-bump \\
    cert=${CA_CERT} \\
    key=${CA_KEY} \\
    generate-host-certificates=on \\
    dynamic_cert_mem_cache_size=64MB \\
    options=NO_SSLv3,NO_TLSv1,NO_TLSv1_1

# Porta plaintext: para clientes/apps sem suporte a SSL Bump
http_port ${PROXY_PORT_PLAIN}"

        sslcrtd_conf="sslcrtd_program ${certgen} -s ${SSL_DB} -M 256MB
sslcrtd_children 8 startup=4 idle=2"

        sslbump_conf="# SSL Bump — 3 fases (Squid 6)
acl ssl_nobump dstdomain \"/etc/squid/lists/ssl_nobump.acl\"
acl step1 at_step SslBump1
acl step2 at_step SslBump2

# Fase 1: peek em TODOS para ler o SNI
ssl_bump peek step1

# Fase 2: decidir por domínio (SNI já disponível)
ssl_bump peek   step2 ssl_nobump
ssl_bump stare  step2 !ssl_nobump

# Fase 3: ação final
ssl_bump splice ssl_nobump
ssl_bump bump   all

sslproxy_cert_error allow all"

        info "Squid configurado COM SSL Bump (porta ${PROXY_PORT})"
    else
        port_conf="# Porta principal: proxy explícito (HTTPS via CONNECT tunnel)
http_port ${PROXY_PORT}
http_port ${PROXY_PORT_PLAIN}"
        sslcrtd_conf=""
        sslbump_conf=""
        warn "SSL Bump INATIVO — HTTPS tunelado sem inspeção"
    fi

    # ── Verificar se error_directory pt-br existe ─────────────────────────────
    local errdir_conf=""
    [[ -d /usr/share/squid/errors/pt-br ]] && \
        errdir_conf="error_directory /usr/share/squid/errors/pt-br"

    # ── Escrever squid.conf ───────────────────────────────────────────────────
    # As variáveis foram resolvidas em port_conf/sslcrtd_conf/sslbump_conf ANTES
    # do heredoc — portanto o heredoc sem aspas é seguro aqui.
    cat > /etc/squid/squid.conf << SQEOF
# =============================================================================
# squid.conf — gateway Debian 13
# Gerado: $(date '+%d/%m/%Y %H:%M')
# Proxy: ${LAN_IP}:${PROXY_PORT} | ${LAN_IP}:${PROXY_PORT_PLAIN}
#
# GRUPOS E HORÁRIOS:
#   ips_livres:    SEMPRE acesso total à internet (sem restrição)
#   ips_parciais:  internet SIM, mas sem streaming/redes sociais FORA do horário
#                  nos horários liberados: acesso total
#   ips_restritos: internet BLOQUEADA fora do horário
#                  nos horários liberados: acesso total
#   TODOS:         sempre acessam gov, bancos, redes internas (${NET_INT}, ${NET_EXT}), sites liberados
#
#   Horários LIBERADOS (dias úteis): 07-08h | 11-13h | 17-18h | 19-23h
#   Final de semana: totalmente liberado para todos
# =============================================================================

${port_conf}

${sslcrtd_conf}

visible_hostname gateway.local

# =============================================================================
# ACLs — REDES
# =============================================================================
acl localnet    src 127.0.0.0/8
acl localnet    src ${NET_INT}
acl localnet    src ${NET_EXT}

# Destinos locais (sem proxy obrigatório — acesso direto)
acl dst_local    dst ${NET_INT}
acl dst_wan      dst ${NET_EXT}
acl dst_loopback dst 127.0.0.0/8
acl dst_intranet dst 10.0.0.0/8

acl SSL_ports   port 443
acl Safe_ports  port 80 443 8080 21 70 210 280 488 591 777 1025-65535
acl CONNECT     method CONNECT

# =============================================================================
# ACLs — CATEGORIAS DE IPs
# =============================================================================
acl ips_livres    src "/etc/squid/lists/ips_livres.acl"
acl ips_parciais  src "/etc/squid/lists/ips_parciais.acl"
acl ips_restritos src "/etc/squid/lists/ips_restritos.acl"

# ssl_bump splice ips_livres — DEVE vir APÓS definição das ACLs de IP
# IPs livres fazem splice (sem inspeção SSL)
ssl_bump splice ips_livres

# =============================================================================
# ACLs — HORÁRIOS
# Formato: time DIA HH:MM-HH:MM
#   M=seg T=ter W=qua H=qui F=sex S=sab A=dom
# =============================================================================
# Horários LIBERADOS — dias úteis
acl h_livre time MTWHF 07:00-08:00
acl h_livre time MTWHF 11:00-13:00
acl h_livre time MTWHF 17:00-18:00
acl h_livre time MTWHF 19:00-23:00
# Final de semana: totalmente liberado (sábado + domingo)
acl h_livre time SA 00:00-24:00
# Domingo
acl h_livre time A  00:00-24:00

# Horário BLOQUEADO = NOT h_livre (aplicado por lógica inversa nas regras)

# =============================================================================
# ACLs — SITES E CONTEÚDO
# =============================================================================
acl sites_liberados  dstdomain    "/etc/squid/lists/sites_liberados.acl"
acl sites_bloqueados dstdomain    "/etc/squid/lists/sites_bloqueados.acl"
acl sites_governo    dstdomain    "/etc/squid/lists/sites_governo.acl"
acl sites_bancos     dstdomain    "/etc/squid/lists/sites_bancos.acl"
acl sites_gov_regex  dstdom_regex "/etc/squid/lists/sites_gov_regex.acl"

# Domínios governamentais — ACLs individuais para uso em regras específicas
# Nota: .sp.gov.br, .tjsp.jus.br etc são subdomínios de .gov.br e .jus.br
# mas mantidos aqui como ACLs separadas pois são usadas individualmente
acl dom_gov  dstdomain .gov.br
acl dom_jus  dstdomain .jus.br
acl dom_org  dstdomain .org.br
acl dom_mp   dstdomain .mp.br
acl dom_def  dstdomain .def.br
acl dom_leg  dstdomain .leg.br

# ACL unificada "sempre_livre": gov + bancos + liberados + redes internas
# Qualquer IP pode acessar esses destinos a qualquer hora
acl sempre_livre dstdomain .gov.br
acl sempre_livre dstdomain .jus.br
acl sempre_livre dstdomain .org.br
acl sempre_livre dstdomain .mp.br
acl sempre_livre dstdomain .def.br
acl sempre_livre dstdomain .leg.br
acl sempre_livre dstdomain .imprensaoficial.com.br
acl sempre_livre dstdomain .correios.com.br
acl sempre_livre dstdomain .bradesco.com.br
acl sempre_livre dstdomain .itau.com.br
acl sempre_livre dstdomain .santander.com.br
acl sempre_livre dstdomain .nubank.com.br
acl sempre_livre dstdomain .inter.co
acl sempre_livre dstdomain .bancointer.com.br
acl sempre_livre dstdomain .c6bank.com.br
acl sempre_livre dstdomain .sicredi.com.br
acl sempre_livre dstdomain .sicoob.com.br
acl sempre_livre dstdomain .picpay.com
acl sempre_livre dstdomain .pagseguro.com.br
acl sempre_livre dstdomain .mercadopago.com.br
acl sempre_livre dstdomain .stone.com.br
acl sempre_livre dstdomain .cielo.com.br
acl sempre_livre dstdomain .xpi.com.br
acl sempre_livre dstdomain .xp.com.br
acl sempre_livre dstdomain .btgpactual.com
acl sempre_livre dstdomain .safra.com.br

# Streaming, redes sociais e radio online
# Bloqueados para ips_parciais FORA do horário liberado
# Bloqueados para ips_restritos SEMPRE (exceto em horário liberado = acesso total)
acl conteudo_restrito dstdomain .youtube.com
acl conteudo_restrito dstdomain .ytimg.com
acl conteudo_restrito dstdomain .googlevideo.com
acl conteudo_restrito dstdomain .youtu.be
acl conteudo_restrito dstdomain .netflix.com .globoplay.com .primevideo.com
acl conteudo_restrito dstdomain .disneyplus.com .hulu.com .twitch.tv
acl conteudo_restrito dstdomain .spotify.com .deezer.com .tidal.com .soundcloud.com
acl conteudo_restrito dstdomain .radios.com.br .vagalume.com.br
acl conteudo_restrito dstdomain .facebook.com .instagram.com .twitter.com .x.com
acl conteudo_restrito dstdomain .tiktok.com .snapchat.com .pinterest.com
acl conteudo_restrito dstdomain .reddit.com .tumblr.com .discord.com
acl conteudo_restrito dstdomain .telegram.org .whatsapp.com

${sslbump_conf}

# =============================================================================
# REGRAS DE ACESSO
# =============================================================================
# Negar portas e métodos inválidos
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# ── R00: Comunicação entre redes locais e intranet 10.0.0.0/8 ───────────────
# 192.168.* <-> 192.168.*, 10.14.29.*, e toda intranet 10.x.x.x (gov SP etc.)
http_access allow localnet dst_local
http_access allow localnet dst_wan
http_access allow localnet dst_loopback
http_access allow localnet dst_intranet

# always_direct para intranet 10.0.0.0/8 — ESSENCIAL para sites gov SP
# Sites como cartoriosap, policiapenal têm IPs 10.200.x.x
# Sem isso o Squid tenta rotear pelo WAN_IP e o pacote é dropado
always_direct allow dst_intranet
always_direct allow dst_local
always_direct allow dst_wan

# ── R01: IPs LIVRES — acesso total sem restrição ─────────────────────────────
http_access allow ips_livres

# ── R02: TODOS os IPs — sites "sempre_livre" liberados a qualquer hora ────────
# gov, tribunais, OAB, bancos, sites liberados — independente de grupo ou hora
http_access allow sempre_livre
http_access allow sites_governo
http_access allow sites_gov_regex
http_access allow sites_bancos
http_access allow sites_liberados

# ── R03: Blacklist — bloqueada para todos, sempre ────────────────────────────
http_access deny sites_bloqueados

# ── R04: IPs PARCIAIS ────────────────────────────────────────────────────────
# Lógica:
#   h_livre  → acesso total (exceto blacklist já negada em R03)
#   !h_livre → bloquear streaming, redes sociais e radio
#   !h_livre → resto da internet: PERMITIDO (parciais têm internet geral)
http_access allow ips_parciais h_livre
# Fora do horário: negar conteúdo restrito (streaming, redes sociais, radio)
http_access deny  ips_parciais conteudo_restrito !h_livre
# Fora do horário: demais sites da internet são permitidos
http_access allow ips_parciais

# ── R05: IPs RESTRITOS ───────────────────────────────────────────────────────
# Lógica:
#   h_livre  → acesso total à internet (blacklist já negada em R03)
#   !h_livre → BLOQUEADO (apenas sempre_livre foi liberado em R02)
http_access allow ips_restritos h_livre
# Fora do horário: bloquear tudo (gov+bancos já passaram em R02 antes de chegar aqui)
http_access deny  ips_restritos

# ── R06: IPs sem categoria — apenas destinos sempre_livre ───────────────────
# IPs que não estão em ips_livres, ips_parciais ou ips_restritos:
# só acessam gov, bancos, redes internas e sites liberados (já permitidos em R02)
# Tudo mais é negado.
http_access deny localnet

# ── R07: Negar tudo o mais ───────────────────────────────────────────────────
http_access deny all

# =============================================================================
# CACHE
# =============================================================================
cache_mem 256 MB
maximum_object_size_in_memory 512 KB
maximum_object_size 128 MB
minimum_object_size 0 KB
cache_dir ufs /var/cache/squid 4096 16 256
cache_replacement_policy lru
no_cache deny CONNECT
positive_dns_ttl 1 hour
negative_dns_ttl 15 minutes

# =============================================================================
# DNS — resolução via DNS internos (obrigatório para sites gov)
# Ordem: named local (127.0.0.1) → DNS1 interno → DNS2 interno → fallbacks
# O named local já encaminha para DNS1/DNS2 com prioridade
# CRÍTICO: DNS1 (10.14.8.20) e DNS2 (10.1.6.222) resolvem sites .gov.br/.sp.gov.br
# =============================================================================
dns_nameservers ${DNS1} ${DNS2} ${DNS3} 127.0.0.1 ${DNS4} ${DNS5}
dns_retransmit_interval 2 seconds
dns_timeout 30 seconds

# Forçar Squid a usar o IP da interface WAN como origem das conexões
# Necessário para sites gov com IPs em redes internas (ex: 10.200.35.x)
# sem isso o Squid tenta conectar sem interface definida e o pacote é dropado
tcp_outgoing_address ${WAN_IP}

# =============================================================================
# LOGS
# =============================================================================
logformat squid_custom %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %[un %Sh/%<a %mt
access_log /var/log/squid/access.log squid_custom
cache_log  /var/log/squid/cache.log
cache_store_log none

# =============================================================================
# PERFORMANCE
# =============================================================================
workers 1
connect_timeout      30 seconds
peer_connect_timeout 10 seconds
read_timeout          5 minutes
request_timeout       5 minutes

# Forçar fechamento de conexões keep-alive na virada de horário
# Sem isso YouTube/Facebook permanecem acessíveis após o horário fechar
client_lifetime    65 minutes
# server_lifetime removido — não existe no Squid 6
pipeline_prefetch  off
half_closed_clients off
shutdown_lifetime  10 seconds

# =============================================================================
# PRIVACIDADE
# =============================================================================
forwarded_for delete
via off
httpd_suppress_version_string on
request_header_access X-Forwarded-For deny all
request_header_access Via deny all

# =============================================================================
# ERROS
# =============================================================================
${errdir_conf}
deny_info ERR_ACCESS_DENIED all
SQEOF

    # ── Verificar squid.conf ──────────────────────────────────────────────────
    info "Verificando squid.conf..."
    # Squid 6 (Debian 13): usar squid -k check para validar config
    # -k parse foi removido. -k check verifica e sai sem iniciar daemon.
    local parse_out fatal_count
    # Squid 6: -k check valida a configuração sem iniciar o daemon
    parse_out=$(squid -k check 2>&1 || true)
    # Contar apenas FATALs reais — ignorar "obsolete" warnings e AF_VSOCK
    fatal_count=$(echo "$parse_out"         | grep -cE "^[0-9/: ]+FATAL" || true)

    if [[ "$fatal_count" -gt 0 ]]; then
        soft_err "Erros FATAIS no squid.conf:"
        echo "$parse_out" | grep -E "FATAL" | head -10
        warn "Aplicando configuração mínima de fallback..."
        cat > /etc/squid/squid.conf << SQMIN
# squid.conf FALLBACK — gerado automaticamente após erro
http_port ${PROXY_PORT}
http_port ${PROXY_PORT_PLAIN}
visible_hostname gateway.local
acl localnet src 127.0.0.0/8
acl localnet src ${NET_INT}
acl localnet src ${NET_EXT}
acl SSL_ports  port 443
acl Safe_ports port 80 443 8080 21 70 210 280 488 591 777 1025-65535
acl CONNECT    method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
# Apenas redes internas e destinos locais no fallback
http_access allow localnet dst_local
http_access allow localnet dst_wan
http_access allow localnet dst_loopback
http_access deny all
cache_dir ufs /var/cache/squid 1024 16 256
dns_nameservers ${DNS1} ${DNS2} ${DNS3} 127.0.0.1
access_log /var/log/squid/access.log
cache_log  /var/log/squid/cache.log
SQMIN
        warn "Fallback ativo — execute 'squid-fix' após correção manual"
    else
        ok "squid.conf válido"
    fi

    # ── Inicializar cache ─────────────────────────────────────────────────────
    info "Inicializando diretórios de cache do Squid..."
    mkdir -p /var/cache/squid /var/log/squid /run/squid /var/run/squid
    chown proxy:proxy /var/cache/squid /var/log/squid 2>/dev/null || true
    chown proxy:proxy /run/squid /var/run/squid 2>/dev/null || true
    chmod 750 /run/squid /var/run/squid 2>/dev/null || true
    squid -z 2>/dev/null || squid -z --foreground 2>/dev/null || true
    sleep 2

    systemctl enable squid 2>/dev/null || true
    systemctl restart squid 2>/dev/null || true
    sleep 3

    if systemctl is-active squid &>/dev/null; then
        ok "Squid ativo: porta ${PROXY_PORT}$([[ ${SQUID_HAS_SSL:-0} == 1 ]] && echo ' (SSL Bump)' || echo ' (tunnel)')"
    else
        soft_err "Squid não iniciou — execute: sudo squid-fix"
        journalctl -u squid --since "2 minutes ago" --no-pager -n 15 2>/dev/null \
            | grep -v "AF_VSOCK\|CID:" | tail -10 || true
    fi
}

configure_squid

# =============================================================================
# PASSO 10 — NGINX (CA + WPAD)
# =============================================================================
hdr "10. NGINX — CA E WPAD"

configure_nginx() {
    # WPAD — proxy auto-discovery
    # Extrair rede base e máscara do NET_EXT para o WPAD
    local wan_net_base wan_net_mask
    wan_net_base=$(echo "${NET_EXT}" | cut -d/ -f1)
    local wan_prefix; wan_prefix=$(echo "${NET_EXT}" | cut -d/ -f2)
    case "$wan_prefix" in
        24) wan_net_mask="255.255.255.0" ;;
        16) wan_net_mask="255.255.0.0" ;;
        8)  wan_net_mask="255.0.0.0" ;;
        *)  wan_net_mask="255.255.255.0" ;;
    esac

    cat > /var/www/html/wpad.dat << WPAD
function FindProxyForURL(url, host) {
    if (isInNet(host, "192.168.0.0",   "255.255.255.0")) return "DIRECT";
    if (isInNet(host, "${wan_net_base}", "${wan_net_mask}")) return "DIRECT";
    if (isInNet(host, "127.0.0.0",     "255.0.0.0"))     return "DIRECT";
    if (isPlainHostName(host))                            return "DIRECT";
    return "PROXY ${LAN_IP}:${PROXY_PORT}; DIRECT";
}
WPAD
    cp /var/www/html/wpad.dat /var/www/html/proxy.pac

    # Remover config padrão do nginx e criar a do gateway
    rm -f /etc/nginx/sites-enabled/default
    cat > /etc/nginx/sites-available/gateway << 'NGINX'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    autoindex off;
    index index.html;

    location /ca/ {
        location ~\.(crt|der|p12)$ {
            add_header Content-Disposition "attachment";
        }
    }
    location = /wpad.dat {
        add_header Content-Type "application/x-ns-proxy-autoconfig";
    }
    location = /proxy.pac {
        add_header Content-Type "application/x-ns-proxy-autoconfig";
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/gateway \
           /etc/nginx/sites-enabled/gateway 2>/dev/null || true

    if nginx -t 2>/dev/null; then
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        systemctl is-active nginx &>/dev/null \
            && ok "nginx ativo — CA: http://${LAN_IP}/ca/ | WPAD: http://${LAN_IP}/wpad.dat" \
            || soft_err "nginx não iniciou — verifique: nginx -t"
    else
        soft_err "nginx config inválida — verifique: nginx -t"
    fi
}

configure_nginx

# =============================================================================
# PASSO 11 — SCRIPTS DE GESTÃO
# =============================================================================
hdr "11. SCRIPTS DE GESTÃO"

create_scripts() {

# ── nat-manager ────────────────────────────────────────────────────────────────
cat > /usr/local/sbin/nat-manager << 'NATMGR'
#!/bin/bash
# nat-manager — Gerenciador NAT 1:1 manual (nftables)
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"
# shellcheck source=/etc/gateway/config
source /etc/gateway/config
NAT_DB="/etc/gateway/nat-entries.conf"

GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYN}[->]${NC}  $*"; }

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || err "IP inválido: $1"; }
has_entry() { grep -q "^${1}|" "$NAT_DB" 2>/dev/null; }
get_ext()   { grep "^${1}|" "$NAT_DB" | cut -d'|' -f2; }

cmd_list() {
    echo ""
    printf "${BLD}  %-18s %-18s %-10s %s${NC}\n" "IP INTERNO" "IP EXTERNO" "STATUS" "DESCRIÇÃO"
    echo "  ──────────────────────────────────────────────────────"
    local n=0
    while IFS='|' read -r i e d; do
        [[ -z "$i" || "$i" == \#* ]] && continue
        local st
        nft list chain ip nat postrouting 2>/dev/null | grep -q "snat to $e" \
            && st="${GRN}ativa${NC}" || st="${YLW}pendente${NC}"
        printf "  %-18s %-18s " "$i" "$e"
        echo -e "${st}  ${d:--}"
        ((n++))
    done < "$NAT_DB"
    printf "\n  Total: %d entrada(s)\n\n" "$n"
}

cmd_add() {
    valid_ip "$1"; valid_ip "$2"
    has_entry "$1" && err "IP $1 já cadastrado — use 'del' primeiro"
    grep -q "|${2}|" "$NAT_DB" 2>/dev/null && err "IP externo $2 já está em uso"
    echo "${1}|${2}|${3:-}" >> "$NAT_DB"
    nft add rule ip nat postrouting oif "$WAN_IFACE" ip saddr "$1" snat to "$2" 2>/dev/null || true
    nft add rule ip nat prerouting  iif "$WAN_IFACE" ip daddr "$2" dnat to "$1" 2>/dev/null || true
    ok "NAT 1:1 adicionado: $1 <-> $2${3:+ ($3)}"
}

cmd_auto() {
    valid_ip "$1"
    local last; last=$(echo "$1" | cut -d. -f4)
    cmd_add "$1" "10.14.29.${last}" "${2:-}"
}

cmd_del() {
    valid_ip "$1"
    has_entry "$1" || err "IP $1 não encontrado"
    local ext; ext=$(get_ext "$1")
    sed -i "/^${1}|/d" "$NAT_DB"
    # Remover regras pelo handle
    for chain in postrouting prerouting; do
        local h
        h=$(nft -a list chain ip nat "$chain" 2>/dev/null \
            | grep -E "${1}|${ext}" | awk '{print $NF}' | head -1)
        [[ -n "$h" ]] && nft delete rule ip nat "$chain" handle "$h" 2>/dev/null || true
    done
    ok "Removido: $1 <-> $ext"
}

cmd_reload() {
    info "Reaplicando entradas salvas..."
    local a=0 f=0
    while IFS='|' read -r i e d; do
        [[ -z "$i" || "$i" == \#* ]] && continue
        nft add rule ip nat postrouting oif "$WAN_IFACE" ip saddr "$i" snat to "$e" 2>/dev/null \
        && nft add rule ip nat prerouting  iif "$WAN_IFACE" ip daddr "$e" dnat to "$i" 2>/dev/null \
        && ((a++)) || ((f++))
    done < "$NAT_DB"
    ok "Reload: $a OK, $f falhas"
}

cmd_check() {
    valid_ip "$1"; echo ""
    has_entry "$1" \
        && echo -e "  BD:   ${GRN}cadastrado${NC} -> $(get_ext "$1")" \
        || echo -e "  BD:   ${RED}não cadastrado${NC}"
    nft list chain ip nat postrouting 2>/dev/null | grep -q "saddr $1" \
        && echo -e "  SNAT: ${GRN}ativo${NC}" || echo -e "  SNAT: ${YLW}inativo${NC}"
    nft list chain ip nat prerouting  2>/dev/null | grep -q "daddr $1\|dnat to $1" \
        && echo -e "  DNAT: ${GRN}ativo${NC}" || echo -e "  DNAT: ${YLW}inativo${NC}"
    echo ""
}

usage() {
    echo -e "\n${BLD}nat-manager${NC} — NAT 1:1 nftables\n"
    echo "  nat-manager list"
    echo "  nat-manager add  <IP_INT> <IP_EXT> [descricao]"
    echo "  nat-manager auto <IP_INT> [descricao]    # IP ext = mesmo octeto"
    echo "  nat-manager del  <IP_INT>"
    echo "  nat-manager check <IP>"
    echo "  nat-manager reload"
    echo ""
    echo "  Exemplos:"
    echo "    nat-manager auto 192.168.0.50 'Servidor Web'"
    echo "    nat-manager add  192.168.0.30 10.14.29.30 'Camera'"
    echo ""
}

case "${1:-help}" in
    list)   cmd_list ;;
    add)    [[ $# -ge 3 ]] || { usage; exit 1; }; cmd_add "$2" "$3" "${4:-}" ;;
    auto)   [[ $# -ge 2 ]] || { usage; exit 1; }; cmd_auto "$2" "${3:-}" ;;
    del)    [[ $# -ge 2 ]] || { usage; exit 1; }; cmd_del "$2" ;;
    check)  [[ $# -ge 2 ]] || { usage; exit 1; }; cmd_check "$2" ;;
    reload) cmd_reload ;;
    *)      usage ;;
esac
NATMGR
chmod +x /usr/local/sbin/nat-manager

# ── fix-nftables ───────────────────────────────────────────────────────────────
cat > /usr/local/sbin/fix-nftables << 'NFTFIX'
#!/bin/bash
# fix-nftables — Diagnóstico e reparo completo do nftables
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"
source /etc/gateway/config || { echo "ERRO: /etc/gateway/config não encontrado"; exit 1; }

GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
info() { echo -e "${CYN}[INFO]${NC} $*"; }
hdr()  { echo -e "\n${BLD}${CYN}── $* ──${NC}"; }

hdr "1. ARQUIVO ATUAL"
if [[ -f /etc/nftables.conf ]]; then
    info "Conteúdo:"; cat /etc/nftables.conf; echo ""
    nft -c -f /etc/nftables.conf 2>&1 && ok "Sintaxe atual OK" \
        || warn "Sintaxe com erro — será regenerado"
else
    warn "Arquivo não existe — será criado"
fi

hdr "2. VARIÁVEIS"
info "WAN: $WAN_IFACE / $WAN_IP"
info "LAN: $LAN_IFACE / $LAN_IP"
info "NET_INT=$NET_INT  NET_EXT=$NET_EXT"
info "DNS: $DNS1 $DNS2 $DNS3 $DNS4 $DNS5"
info "Proxy: $PROXY_PORT / $PROXY_PORT_PLAIN"

hdr "3. GERANDO NOVO nftables.conf"
[[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)"

F="/etc/nftables.conf"
{
printf '#!/usr/sbin/nft -f\n'
printf '# nftables gateway Debian 13 — %s\n\n' "$(date '+%d/%m/%Y %H:%M')"
printf 'flush ruleset\n\n'
printf 'table inet filter {\n\n'
printf '    set ips_livres    { type ipv4_addr; flags interval; }\n'
printf '    set ips_parciais  { type ipv4_addr; flags interval; }\n'
printf '    set ips_restritos { type ipv4_addr; flags interval; }\n\n'
printf '    chain input {\n'
printf '        type filter hook input priority 0; policy drop;\n\n'
printf '        iif lo accept\n'
printf '        ct state established,related accept\n'
printf '        ct state invalid drop\n'
printf '        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept\n\n'
printf '        ip saddr { %s, %s } tcp dport 22 ct state new accept\n'         "$NET_INT" "$NET_EXT"
printf '        ip saddr { %s, %s } udp dport 53 accept\n'                      "$NET_INT" "$NET_EXT"
printf '        ip saddr { %s, %s } tcp dport 53 accept\n'                      "$NET_INT" "$NET_EXT"
printf '        ip saddr { %s, %s } udp dport 123 accept\n'                     "$NET_INT" "$NET_EXT"
printf '        ip saddr %s tcp dport 80 ct state new accept\n'                 "$NET_INT"
printf '        ip saddr %s tcp dport { %s, %s } ct state new accept\n'         "$NET_INT" "$PROXY_PORT" "$PROXY_PORT_PLAIN"
printf '        limit rate 5/minute log prefix "[NFT-IN-DROP] " level warn\n'
printf '        drop\n    }\n\n'
printf '    chain forward {\n'
printf '        type filter hook forward priority 0; policy drop;\n\n'
printf '        ct state established,related accept\n'
printf '        ct state invalid drop\n'
printf '        ip protocol icmp accept\n\n'
printf '        iif %s oif %s ip saddr %s ip daddr %s accept\n' "$LAN_IFACE" "$WAN_IFACE" "$NET_INT" "$NET_EXT"
printf '        iif %s oif %s ip saddr %s ip daddr %s accept\n' "$WAN_IFACE" "$LAN_IFACE" "$NET_EXT" "$NET_INT"
printf '        # LAN -> intranet 10.0.0.0/8 (governo SP e redes internas)\n'
printf '        iif %s oif %s ip saddr %s ip daddr 10.0.0.0/8 accept\n' "$LAN_IFACE" "$WAN_IFACE" "$NET_INT"
printf '        iif %s oif %s ip saddr 10.0.0.0/8 ip daddr %s accept\n' "$WAN_IFACE" "$LAN_IFACE" "$NET_INT"
printf '        iif %s oif %s ip saddr @ips_livres accept\n'    "$LAN_IFACE" "$WAN_IFACE"
printf '        iif %s oif %s ip daddr { %s, %s, %s, %s, %s } udp dport 53 accept\n' \
    "$LAN_IFACE" "$WAN_IFACE" "$DNS1" "$DNS2" "$DNS3" "$DNS4" "$DNS5"
printf '        iif %s oif %s ip daddr { %s, %s, %s, %s, %s } tcp dport 53 accept\n' \
    "$LAN_IFACE" "$WAN_IFACE" "$DNS1" "$DNS2" "$DNS3" "$DNS4" "$DNS5"
printf '        iif %s oif %s ip saddr %s accept\n'             "$LAN_IFACE" "$WAN_IFACE" "$NET_INT"
printf '        limit rate 3/minute log prefix "[NFT-FWD-DROP] " level warn\n'
printf '        drop\n    }\n\n'
printf '    chain output {\n'
printf '        type filter hook output priority 0; policy accept;\n'
printf '    }\n}\n\n'
printf 'table ip nat {\n\n'
printf '    chain prerouting {\n'
printf '        type nat hook prerouting priority dstnat;\n'
printf '    }\n\n'
printf '    chain postrouting {\n'
printf '        type nat hook postrouting priority srcnat;\n'
printf '        oif %s ip saddr %s masquerade\n' "$WAN_IFACE" "$NET_INT"
printf '    }\n}\n'
} > "$F"
ok "nftables.conf gerado"

hdr "4. VALIDAR SINTAXE"
if nft -c -f "$F" 2>&1; then
    ok "Sintaxe válida"
else
    err "Sintaxe inválida — verifique as variáveis acima"
    exit 1
fi

hdr "5. APLICAR RULESET"
nft -f "$F" && ok "Ruleset aplicado em memória" \
    || { err "Falha ao aplicar ruleset"; exit 1; }

hdr "6. REINICIAR SERVIÇO"
# Garantir override RemainAfterExit para nftables
mkdir -p /etc/systemd/system/nftables.service.d
cat > /etc/systemd/system/nftables.service.d/override.conf << 'NFTOV'
[Service]
RemainAfterExit=yes
ExecReload=/usr/sbin/nft -f /etc/nftables.conf
NFTOV
systemctl daemon-reload
systemctl restart nftables 2>/dev/null || true
sleep 1
if systemctl is-active nftables &>/dev/null; then
    ok "nftables.service: ATIVO"
elif nft list ruleset 2>/dev/null | grep -q "table" 2>/dev/null; then
    ok "Ruleset aplicado — serviço reportado como ativo"
else
    err "nftables não está funcionando"
fi

hdr "7. SETS E NAT"
/etc/gateway/load-sets.sh 2>/dev/null && ok "Sets de IPs carregados" || warn "Falha nos sets"
/etc/gateway/load-nat.sh  2>/dev/null && ok "NAT 1:1 recarregado"   || true

hdr "RESULTADO"
echo ""
nft list ruleset 2>/dev/null \
    | grep -E "^table|chain|snat|masquerade|policy" | head -20
echo ""
ok "fix-nftables concluído"
NFTFIX
chmod +x /usr/local/sbin/fix-nftables

# ── squid-fix ──────────────────────────────────────────────────────────────────
cat > /usr/local/sbin/squid-fix << 'SQFIX'
#!/bin/bash
# squid-fix — Diagnóstico e reparo completo do Squid
set -euo pipefail
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"
source /etc/gateway/config 2>/dev/null || true

GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
info() { echo -e "${CYN}[INFO]${NC} $*"; }
hdr()  { echo -e "\n${BLD}${CYN}── $* ──${NC}"; }

hdr "1. VERSÃO E SUPORTE SSL"
squid -v 2>/dev/null | head -3
echo ""
HAS_SSL=0
find /usr -name "security_file_certgen" -executable 2>/dev/null | grep -q . \
    && HAS_SSL=1 && ok "security_file_certgen encontrado" \
    || warn "security_file_certgen não encontrado — SSL Bump impossível"
squid -v 2>/dev/null | grep -qi "\-\-with-openssl\|\-\-enable-ssl\|openssl" \
    && HAS_SSL=1 && ok "squid -v confirma OpenSSL" || true

hdr "2. LOG DE ERROS RECENTES"
journalctl -u squid --since "10 minutes ago" --no-pager -n 30 2>/dev/null \
    | grep -v "AF_VSOCK\|CID:" \
    | grep -iE "FATAL|ERROR|Failed|Warning" | head -20 \
    || tail -20 /var/log/squid/cache.log 2>/dev/null || echo "(sem erros)"

hdr "3. CERTIFICADO CA"
CA_KEY="${CA_KEY:-/etc/squid/ssl/squid-ca.key}"
CA_CERT="${CA_CERT:-/etc/squid/ssl/squid-ca.crt}"
if [[ ! -f "$CA_KEY" || ! -f "$CA_CERT" ]]; then
    warn "CA ausente — gerando..."
    mkdir -p "$(dirname "$CA_KEY")"
    openssl genrsa -out "$CA_KEY" 2048 2>/dev/null
    # Gerar CA com todas as extensões exigidas por browsers modernos
    _ca_cnf=$(mktemp /tmp/ca_XXXXXX.cnf)
    cat > "$_ca_cnf" << CACNF
[req]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no
[req_dn]
C=BR
ST=Sao Paulo
L=Sao Paulo
O=Gateway Proxy
CN=Gateway Proxy CA
[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
CACNF
    openssl req -new -x509 -days 3650 -key "$CA_KEY" -out "$CA_CERT"         -config "$_ca_cnf" -extensions v3_ca 2>/dev/null
    rm -f "$_ca_cnf"
    cp "$CA_CERT" /usr/local/share/ca-certificates/squid-proxy-ca.crt
    update-ca-certificates --fresh 2>/dev/null || true
    ok "CA gerado"
else
    ok "CA: $CA_CERT"
    info "Validade: $(openssl x509 -in "$CA_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
fi
chown proxy:proxy "$CA_KEY" "$CA_CERT" 2>/dev/null || true
chmod 640 "$CA_KEY"; chmod 644 "$CA_CERT"

hdr "4. SSL DATABASE"
CERTGEN="${CERTGEN:-}"
[[ -z "$CERTGEN" || ! -x "$CERTGEN" ]] && \
    CERTGEN=$(find /usr -name "security_file_certgen" -executable 2>/dev/null | head -1)
if [[ -n "$CERTGEN" ]]; then
    ok "certgen: $CERTGEN"
    SSL_DB="${SSL_DB:-/var/lib/squid/ssl_db}"
    rm -rf "$SSL_DB"; mkdir -p "$SSL_DB"
    "$CERTGEN" -c -s "$SSL_DB" -M 256MB 2>/dev/null \
        && ok "SSL DB criado" || err "Falha ao criar SSL DB"
    chown -R proxy:proxy "$SSL_DB"
else
    warn "certgen não encontrado — pulando SSL DB"
fi

hdr "5. VERIFICAR squid.conf"
# Squid 6: -k check valida sem iniciar daemon
parse_out=$(squid -k check 2>&1 || true)
# Apenas erros FATAIS reais — ignorar obsolete, WARNING, AF_VSOCK
parse_fatais=$(echo "$parse_out"     | grep -E "FATAL:"     | grep -v "AF_VSOCK\|obsolete\|WARNING" || true)
if [[ -n "$parse_fatais" ]]; then
    err "Erros FATAIS no squid.conf:"
    echo "$parse_fatais" | head -5
else
    ok "squid.conf sem erros fatais"
    obs=$(echo "$parse_out"         | grep -i "ERROR:\|WARNING:\|obsolete"         | grep -v "AF_VSOCK\|FATAL\|^$" | head -3 || true)
    [[ -n "$obs" ]] && warn "Avisos nao-fatais:" && echo "$obs" | sed 's/^/    /'
fi
hdr "6. REINICIAR SQUID"
squid -z 2>/dev/null || true
sleep 1
systemctl restart squid 2>/dev/null || true
sleep 3
if systemctl is-active squid &>/dev/null; then
    ok "Squid ATIVO"
    echo -e "  Proxy:    ${BLD}${LAN_IP:-192.168.0.1}:${PROXY_PORT:-3128}${NC}"
    [[ "$HAS_SSL" == "1" ]] \
        && echo -e "  SSL Bump: ${GRN}ATIVO${NC}" \
        || echo -e "  SSL Bump: ${YLW}INATIVO${NC}"
    echo -e "  CA:       http://${LAN_IP:-192.168.0.1}/ca/"
else
    err "Squid ainda não iniciou:"
    journalctl -u squid --since "1 minute ago" --no-pager -n 20 2>/dev/null \
        | grep -v "AF_VSOCK\|CID:" | tail -15
fi
SQFIX
chmod +x /usr/local/sbin/squid-fix

# ── gateway-status ─────────────────────────────────────────────────────────────
cat > /usr/local/sbin/gateway-status << 'GSTATUS'
#!/bin/bash
# gateway-status — Status completo do gateway
source /etc/gateway/config 2>/dev/null || true
GRN='\033[0;32m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
svc() {
    systemctl is-active "$1" &>/dev/null \
        && echo -e "  ${GRN}●${NC} $1: ativo" \
        || echo -e "  ${RED}●${NC} $1: INATIVO"
}
echo ""
echo -e "${BLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLD}║  GATEWAY STATUS — $(date '+%d/%m/%Y %H:%M:%S')   ║${NC}"
echo -e "${BLD}╚══════════════════════════════════════════╝${NC}"
echo -e "\n${BLD}Serviços:${NC}"
for s in nftables squid named bind9 chrony nginx fail2ban; do
    systemctl list-unit-files "${s}.service" &>/dev/null 2>&1 && svc "$s" || true
done
echo -e "\n${BLD}Interfaces:${NC}"
ip -4 addr show | grep -E "^[0-9]+:|inet " | grep -v "127.0.0"
echo -e "\n${BLD}Roteamento:${NC}"
ip route show
echo -e "\n${BLD}Firewall (nftables):${NC}"
nft list ruleset 2>/dev/null \
    | grep -E "^table|hook|snat|masquerade" | head -15 \
    || echo "  (nftables não carregado)"
echo -e "\n${BLD}NAT 1:1 ativo:${NC}"
nft list chain ip nat postrouting 2>/dev/null \
    | grep "snat" | head -10 || echo "  (nenhuma entrada)"
echo -e "
${BLD}DNS:${NC}"
if systemctl is-active named &>/dev/null || systemctl is-active bind9 &>/dev/null; then
    dig_out=$(dig @127.0.0.1 google.com +short +time=2 2>/dev/null | head -3)
    if [[ -n "$dig_out" ]]; then
        echo "$dig_out"
        echo -e "  ${GRN}DNS local OK${NC}"
    else
        echo -e "  ${RED}DNS local: named ativo mas sem resposta${NC}"
    fi
else
    echo -e "  ${RED}DNS local: named INATIVO${NC}"
    echo -e "  Usando DNS externo: $DNS1, $DNS2"
fi
echo -e "\n${BLD}NTP:${NC}"
chronyc tracking 2>/dev/null | grep -E "Stratum|Reference|Offset" || true
echo -e "
${BLD}Proxy (Squid):${NC}"
if command -v squidclient &>/dev/null; then
    squidclient -h 127.0.0.1 -p "${PROXY_PORT:-3128}" mgr:info 2>/dev/null         | grep -E "Number of clients|HTTP requests" | head -3         || echo "  (squid não responde ao squidclient)"
elif command -v curl &>/dev/null; then
    # Testar com destino local — sempre permitido pelas regras do Squid
    _code=$(curl -sx "http://127.0.0.1:${PROXY_PORT:-3128}"         "http://${LAN_IP:-192.168.0.1}/"         -o /dev/null -w "%{http_code}" --connect-timeout 3 2>/dev/null || echo "000")
    if [[ "$_code" == "000" ]]; then
        echo "  (squid não responde na porta ${PROXY_PORT:-3128})"
    else
        echo -e "  ${GRN}Proxy OK${NC} — HTTP $_code"
    fi
else
    echo "  (squidclient não disponível)"
fi
echo -e "\n${BLD}Comandos disponíveis:${NC}"
echo "  gateway-status  reload-gateway  nat-manager  squid-fix  fix-nftables"
echo ""
GSTATUS
chmod +x /usr/local/sbin/gateway-status

# ── reload-gateway ──────────────────────────────────────────────────────────────
cat > /usr/local/sbin/reload-gateway << 'RELOAD'
#!/bin/bash
# reload-gateway — Recarrega todas as configurações do gateway
[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"
GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }

echo "[$(date '+%d/%m %H:%M')] Recarregando gateway..."

# nftables: validar antes de aplicar
if nft -c -f /etc/nftables.conf 2>/dev/null; then
    nft -f /etc/nftables.conf \
        && ok "nftables aplicado" \
        || err "nftables: falha ao aplicar — execute: fix-nftables"
else
    err "nftables.conf com erro de sintaxe — execute: fix-nftables"
fi

/etc/gateway/load-sets.sh \
    && ok "Sets de IPs recarregados" \
    || warn "Sets: falha"
/etc/gateway/load-nat.sh \
    && ok "NAT 1:1 recarregado" \
    || warn "NAT: falha"

# Sincronizar listas gateway -> squid
for f in ips_livres ips_parciais ips_restritos \
          sites_liberados sites_bloqueados sites_governo sites_bancos; do
    cp "/etc/gateway/lists/${f}.conf" "/etc/squid/lists/${f}.acl" 2>/dev/null || true
done
squid -k reconfigure \
    && ok "Squid recarregado" \
    || warn "Squid: falha ao recarregar — verifique: squid-fix"

systemctl reload named 2>/dev/null \
    || systemctl reload bind9 2>/dev/null \
    && ok "DNS recarregado" \
    || warn "DNS: falha"

echo "[$(date '+%d/%m %H:%M')] Reload concluído."
RELOAD
chmod +x /usr/local/sbin/reload-gateway

ok "Scripts instalados em /usr/local/sbin/:"
ok "  nat-manager | fix-nftables | squid-fix | gateway-status | reload-gateway"
}

create_scripts

# =============================================================================
# PASSO 12 — SYSTEMD
# =============================================================================
hdr "12. SERVIÇOS SYSTEMD"

configure_systemd() {
    # gateway-boot: reaplica NAT 1:1 e sets após nftables subir no boot
    cat > /etc/systemd/system/gateway-boot.service << UNIT
[Unit]
Description=Gateway — Reaplica NAT 1:1 e sets de IPs no boot
After=nftables.service network-online.target
Wants=network-online.target
ConditionPathExists=/etc/gateway/config

[Service]
Type=oneshot
ExecStart=/etc/gateway/load-nat.sh
ExecStartPost=/etc/gateway/load-sets.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable gateway-boot.service 2>/dev/null \
        && ok "gateway-boot.service habilitado" \
        || soft_err "Falha ao habilitar gateway-boot.service"
}

configure_systemd

# =============================================================================
# PASSO 13 — SEGURANÇA: fail2ban, logrotate, sudoers
# =============================================================================
hdr "13. SEGURANÇA E MANUTENÇÃO"

configure_security() {
    # fail2ban
    cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
maxretry = 3
bantime  = 7200

[squid]
enabled  = true
port     = 3128,3129
filter   = squid
logpath  = /var/log/squid/access.log
maxretry = 10
bantime  = 1800
F2B
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    systemctl is-active fail2ban &>/dev/null && ok "fail2ban ativo" \
        || soft_err "fail2ban não iniciou"

    # logrotate
    cat > /etc/logrotate.d/gateway << 'LR'
/var/log/squid/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        squid -k rotate 2>/dev/null || true
    endscript
}
# /var/log/bind removido: BIND usa syslog (journalctl -u named)
/var/log/chrony/*.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LR
    ok "logrotate configurado"

    # grupo e sudoers
    groupadd netadmin 2>/dev/null || true
    cat > /etc/sudoers.d/gateway << 'SUDO'
# Grupo netadmin — administração do gateway
%netadmin ALL=(root) NOPASSWD: /usr/local/sbin/nat-manager
%netadmin ALL=(root) NOPASSWD: /usr/local/sbin/fix-nftables
%netadmin ALL=(root) NOPASSWD: /usr/local/sbin/squid-fix
%netadmin ALL=(root) NOPASSWD: /usr/local/sbin/gateway-status
%netadmin ALL=(root) NOPASSWD: /usr/local/sbin/reload-gateway
%netadmin ALL=(root) NOPASSWD: /usr/sbin/nft
%netadmin ALL=(root) NOPASSWD: /bin/systemctl restart squid
%netadmin ALL=(root) NOPASSWD: /bin/systemctl restart named
%netadmin ALL=(root) NOPASSWD: /bin/systemctl restart nftables
%netadmin ALL=(root) NOPASSWD: /bin/systemctl restart nginx
SUDO
    chmod 440 /etc/sudoers.d/gateway
    # Validar sudoers
    visudo -c -f /etc/sudoers.d/gateway 2>/dev/null \
        && ok "sudoers configurado (grupo: netadmin)" \
        || soft_err "sudoers com erro — verifique /etc/sudoers.d/gateway"
}

configure_security

# =============================================================================
# PASSO 13b — CRON REVALIDAÇÃO DE HORÁRIOS
# =============================================================================
hdr "13b. Cron de revalidação de horários"

cat > /etc/cron.d/gateway-horarios << 'CRON'
# Gateway — squid -k reconfigure nas transições de horário
# Encerra conexões keep-alive e força revalidação das ACLs h_livre
0  7 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 11 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 17 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 19 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0  8 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 13 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 18 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
0 23 * * 1-5 root /usr/sbin/squid -k reconfigure 2>/dev/null || true
CRON
chmod 644 /etc/cron.d/gateway-horarios
ok "Cron: revalidação em 07/08/11/13/17/18/19/23h (seg-sex)"



# =============================================================================
# VERIFICAÇÃO FINAL
# =============================================================================
hdr "VERIFICAÇÃO FINAL"

final_check() {
    local ok_n=0 fail_n=0

    chk_svc() {
        if systemctl is-active "$1" &>/dev/null; then
            echo -e "  ${GRN}✓${NC} $1"
            ((ok_n++))
        else
            # nftables é oneshot — verificar também via ruleset
            if [[ "$1" == "nftables" ]] && nft list ruleset &>/dev/null 2>&1                && nft list ruleset | grep -q "table"; then
                echo -e "  ${GRN}✓${NC} $1 (ruleset ativo)"
                ((ok_n++))
            else
                echo -e "  ${RED}✗${NC} $1"
                ((fail_n++))
            fi
        fi
    }

    echo ""
    echo -e "${BLD}Serviços:${NC}"
    chk_svc nftables
    chk_svc squid
    # named OU bind9
    if systemctl is-active named &>/dev/null; then
        echo -e "  ${GRN}✓${NC} named"; ((ok_n++))
    elif systemctl is-active bind9 &>/dev/null; then
        echo -e "  ${GRN}✓${NC} bind9"; ((ok_n++))
    else
        echo -e "  ${RED}✗${NC} DNS (named/bind9)"; ((fail_n++))
    fi
    chk_svc chrony
    chk_svc nginx
    chk_svc fail2ban

    echo ""
    echo -e "${BLD}Kernel:${NC}"
    [[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] \
        && echo -e "  ${GRN}✓${NC} IP Forwarding ativo" \
        || { echo -e "  ${RED}✗${NC} IP Forwarding inativo"; ((fail_n++)); }

    # Erros acumulados durante o setup
    echo ""
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo -e "${BLD}${YLW}Avisos durante a instalação:${NC}"
        for e in "${ERRORS[@]}"; do
            echo -e "  ${YLW}!${NC} $e"
        done
    fi

    # Sumário
    source "$GW_CONF/config"
    echo ""
    echo -e "${BLD}${GRN}══════════════════════════════════════════════${NC}"
    echo -e "${BLD}${GRN}  GATEWAY CONFIGURADO${NC}"
    echo -e "${BLD}${GRN}══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  WAN    : ${BLD}$WAN_IP${NC} ($WAN_IFACE)"
    echo -e "  LAN    : ${BLD}$LAN_IP${NC} ($LAN_IFACE)"
    echo -e "  GW     : ${BLD}$GW_IP${NC}"
    echo -e "  Proxy  : ${BLD}$LAN_IP:$PROXY_PORT${NC}$([[ ${SQUID_HAS_SSL:-0} == 1 ]] && echo ' [SSL Bump]' || echo ' [tunnel]') | ${BLD}$LAN_IP:$PROXY_PORT_PLAIN${NC} [plaintext]"
    echo -e "  DNS    : ${BLD}$DNS1, $DNS2${NC} (primários) + $DNS3, $DNS4, $DNS5"
    echo -e "  CA     : ${BLD}http://$LAN_IP/ca/${NC}"
    echo -e "  WPAD   : ${BLD}http://$LAN_IP/wpad.dat${NC}"
    echo -e "  Config : ${BLD}$GW_CONF/${NC}"
    echo -e "  Listas : ${BLD}$LIST_DIR/${NC}"
    echo ""
    echo -e "  ${CYN}Comandos:${NC}"
    echo -e "    gateway-status              — status completo"
    echo -e "    reload-gateway              — recarregar tudo"
    echo -e "    nat-manager list            — listar NAT 1:1"
    echo -e "    nat-manager auto 192.168.0.X — adicionar NAT 1:1"
    echo -e "    fix-nftables                — diagnosticar/reparar firewall"
    echo -e "    squid-fix                   — diagnosticar/reparar proxy"
    echo ""
    echo -e "  ${YLW}Serviços OK: $ok_n | Falhas: $fail_n${NC}"
    [[ $fail_n -gt 0 ]] && \
        echo -e "  ${YLW}⚠  Execute 'gateway-status' para detalhes dos serviços com falha${NC}"
    echo ""
    echo -e "  ${YLW}⚠  Reinicie o servidor para aplicar as configurações de rede${NC}"
    echo -e "  ${YLW}⚠  Instale o CA nos clientes: http://$LAN_IP/ca/${NC}"
    echo ""
}

final_check
