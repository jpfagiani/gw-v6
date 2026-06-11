#!/bin/bash
# =============================================================================
# CDPNI — Script de Correção do Gateway
# Corrige 4 problemas identificados após instalação em máquina real:
#   1. Menu lateral do painel sem texto (CSS — baixo contraste)
#   2. Painel inacessível (porta 5000 não persiste no nftables)
#   3. Clientes sem IP nas listas bypassam Squid via nftables
#   4. WPAD muito permissivo (gov.br genérico + dnsResolve)
# Execute como root: sudo bash fix-gateway.sh
# =============================================================================
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'
BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYN}[INFO]${NC} $*"; }
hdr()  {
    echo -e "\n${BLD}${CYN}══════════════════════════════════════════════════${NC}"
    echo -e "${BLD}${CYN}  $*${NC}"
    echo -e "${BLD}${CYN}══════════════════════════════════════════════════${NC}"
}

[[ $EUID -ne 0 ]] && err "Execute como root: sudo bash $0"

# Carregar configuração do gateway
GW_CONF="/etc/gateway"
[[ ! -f "$GW_CONF/config" ]] && err "Configuração não encontrada em $GW_CONF/config — gateway instalado?"
# shellcheck source=/dev/null
source "$GW_CONF/config"

# Validar variáveis essenciais
for var in LAN_IP LAN_IFACE WAN_IFACE NET_INT NET_EXT PROXY_PORT; do
    [[ -z "${!var}" ]] && err "Variável $var não definida em $GW_CONF/config"
done

info "Gateway: LAN=$LAN_IP ($LAN_IFACE) | WAN=$WAN_IP ($WAN_IFACE)"
info "Redes: INT=$NET_INT | EXT=$NET_EXT"
info "Início: $(date '+%d/%m/%Y %H:%M:%S')"

# =============================================================================
# CORREÇÃO 1 — CSS do painel (menu lateral invisível)
# =============================================================================
hdr "1. Corrigindo CSS do painel (menu lateral)"

PANEL_APP="/opt/gateway-panel/app.py"
if [[ ! -f "$PANEL_APP" ]]; then
    warn "Painel não instalado em $PANEL_APP — pulando correção 1"
else
    # Backup
    cp "$PANEL_APP" "${PANEL_APP}.bak.$(date +%s)"
    ok "Backup: ${PANEL_APP}.bak.*"

    # Problema: --txm (#64748b) e --txs (#94a3b8) somem no fundo --bg2 (#162030)
    # Correção: aumentar brilho das cores de texto do sidebar
    python3 - << 'PYFIX'
import re

with open('/opt/gateway-panel/app.py', 'r') as f:
    content = f.read()

# Fix 1: CSS variables — aumentar contraste do texto sidebar
# --txm (seção headers): de #64748b para #a0b4c8 (mais claro)
# --txs (itens menu):    de #94a3b8 para #c8d8e8 (mais claro)
old_root = '--tx:#e2e8f0;--txs:#94a3b8;--txm:#64748b;'
new_root = '--tx:#e2e8f0;--txs:#c8d8e8;--txm:#a0b4c8;'
content = content.replace(old_root, new_root, 1)

# Fix 2: sidebar background mais escuro para aumentar contraste geral
# --bg2 de #162030 para #111c29 (mais escuro = maior contraste com texto claro)
old_bg = '--bg:#0f1923;--bg2:#162030;--bg3:#1c2d3f;--bd:#2a3f52;'
new_bg = '--bg:#0a1520;--bg2:#111c29;--bg3:#192534;--bd:#2a3f52;'
content = content.replace(old_bg, new_bg, 1)

# Fix 3: sidebar item hover e estado ativo mais visível
old_ni = '.ni:hover{background:var(--bg3)}'
new_ni = '.ni:hover{background:var(--bg3);color:#e2e8f0}'
content = content.replace(old_ni, new_ni, 1)

with open('/opt/gateway-panel/app.py', 'w') as f:
    f.write(content)

print("CSS corrigido com sucesso")
PYFIX

    if systemctl is-active gateway-panel &>/dev/null; then
        systemctl restart gateway-panel
        ok "Painel reiniciado com novo CSS"
    else
        warn "Painel não está rodando — verifique: systemctl status gateway-panel"
    fi
fi

# =============================================================================
# CORREÇÃO 2 — Porta 5000 permanente no nftables
# =============================================================================
hdr "2. Corrigindo porta 5000 no nftables (persistência)"

NFTCONF="/etc/nftables.conf"
[[ ! -f "$NFTCONF" ]] && err "nftables.conf não encontrado em $NFTCONF"

# Verificar se a regra já existe no arquivo
if grep -q "tcp dport 5000" "$NFTCONF"; then
    ok "Regra porta 5000 já existe em $NFTCONF"
else
    cp "$NFTCONF" "${NFTCONF}.bak.$(date +%s)"
    ok "Backup: ${NFTCONF}.bak.*"

    # Inserir regra antes da linha do proxy Squid (que já existe no chain input)
    # Usar Python para inserção segura
    python3 - << PYFIX2
with open('$NFTCONF', 'r') as f:
    content = f.read()

# Inserir após a linha do proxy Squid no chain input
squid_line = 'tcp dport { $PROXY_PORT'
panel_rule = '        ip saddr $NET_INT tcp dport 5000 ct state new accept\n'
insert_marker = '        # Proxy Squid'

if panel_rule.strip() not in content:
    # Encontrar o bloco do proxy e inserir logo depois
    old = '        # Proxy Squid'
    new = '        # Painel Web (porta 5000 — acesso restrito à LAN)\n        ip saddr $NET_INT tcp dport 5000 ct state new accept\n        # Proxy Squid'
    content = content.replace(old, new, 1)
    with open('$NFTCONF', 'w') as f:
        f.write(content)
    print("Regra porta 5000 adicionada ao nftables.conf")
else:
    print("Regra já existe")
PYFIX2

    # Validar e aplicar
    if nft -c -f "$NFTCONF" 2>/dev/null; then
        nft -f "$NFTCONF"
        ok "nftables recarregado com porta 5000 permanente"
    else
        warn "Erro na sintaxe do nftables.conf — restaurando backup"
        cp "${NFTCONF}.bak."* "$NFTCONF" 2>/dev/null || true
        err "Falha ao aplicar nftables.conf"
    fi
fi

# Verificar se regra está ativa em memória
if nft list chain inet filter input 2>/dev/null | grep -q "tcp dport 5000"; then
    ok "Porta 5000 ativa no nftables em memória"
else
    # Adicionar em runtime também (caso nftables.conf ainda não tenha sido recarregado)
    nft add rule inet filter input ip saddr "$NET_INT" tcp dport 5000 ct state new accept 2>/dev/null \
        && ok "Regra porta 5000 adicionada em runtime" \
        || warn "Falha ao adicionar regra em runtime — verifique manualmente"
fi

# =============================================================================
# CORREÇÃO 3 — nftables: remover regra que permite bypass do Squid
# =============================================================================
hdr "3. Corrigindo nftables — bloquear bypass do Squid"

# O problema: a regra abaixo permite que QUALQUER cliente da LAN acesse
# a internet diretamente, sem passar pelo Squid:
#   iif enp0s8 oif enp0s3 ip saddr 192.168.0.0/24 accept  ← MUITO PERMISSIVA
#
# Correção: remover essa regra genérica e manter apenas:
#   - IPs livres (@ips_livres) — acesso direto autorizado
#   - Intranet 10.0.0.0/8 — acesso direto (NAT 1:1)
#   - DNS e NTP — apenas para os servidores permitidos
#   - Tráfego para a própria WAN (NET_EXT) — necessário para o gateway funcionar
#
# Tráfego HTTP/HTTPS de clientes comuns deve passar pelo Squid:
#   Cliente → porta 3128/3129 no gateway → Squid → internet
#   (O nftables só precisa aceitar INPUT na porta do proxy, não FORWARD direto)

cp "$NFTCONF" "${NFTCONF}.bak.$(date +%s)"
ok "Backup: ${NFTCONF}.bak.*"

python3 - << PYFIX3
with open('$NFTCONF', 'r') as f:
    content = f.read()

# Remover a linha que libera todo forward da LAN para WAN
# Padrão: iif <LAN> oif <WAN> ip saddr <NET_INT> accept  (sem ip daddr)
import re

# Linha problemática — accept genérico sem daddr restrito
bad_line_comment = '        # LAN -> internet (proxy explícito — clientes devem configurar proxy)\n'
bad_line_comment2 = '        # Para proxy transparente seria necessário TPROXY (não configurado)\n'
bad_line_rule = f'        iif $LAN_IFACE oif $WAN_IFACE ip saddr $NET_INT accept\n'

removed = False
for line in [bad_line_comment, bad_line_comment2, bad_line_rule]:
    if line in content:
        content = content.replace(line, '', 1)
        removed = True

if removed:
    with open('$NFTCONF', 'w') as f:
        f.write(content)
    print("Regra de bypass removida do nftables.conf")
else:
    print("Regra de bypass não encontrada — pode já ter sido removida")
PYFIX3

# Validar e aplicar
if nft -c -f "$NFTCONF" 2>/dev/null; then
    nft -f "$NFTCONF"
    # Recarregar sets de IPs (ips_livres, ips_parciais, ips_restritos)
    [[ -x "$GW_CONF/load-sets.sh" ]] && bash "$GW_CONF/load-sets.sh" && ok "Sets de IPs recarregados"
    # Recarregar NAT 1:1
    [[ -x "$GW_CONF/load-nat.sh" ]] && bash "$GW_CONF/load-nat.sh" && ok "NAT 1:1 recarregado"
    ok "nftables aplicado — bypass do Squid bloqueado"
else
    warn "Erro na sintaxe — restaurando backup"
    # Restaurar o backup mais recente
    latest_bak=$(ls -t "${NFTCONF}.bak."* 2>/dev/null | head -1)
    [[ -n "$latest_bak" ]] && cp "$latest_bak" "$NFTCONF"
    nft -f "$NFTCONF" 2>/dev/null || true
    err "Falha ao aplicar nftables.conf — backup restaurado"
fi

# =============================================================================
# CORREÇÃO 4 — WPAD: reverter para bypass apenas de intranet real
# =============================================================================
hdr "4. Corrigindo WPAD (proxy.pac)"

WPAD_FILE="/var/www/html/wpad.dat"
[[ ! -f "$WPAD_FILE" ]] && warn "WPAD não encontrado em $WPAD_FILE — pulando"

if [[ -f "$WPAD_FILE" ]]; then
    cp "$WPAD_FILE" "${WPAD_FILE}.bak.$(date +%s)"
    ok "Backup: ${WPAD_FILE}.bak.*"

    # Calcular máscara da WAN para o WPAD
    wan_prefix=$(echo "${NET_EXT}" | cut -d/ -f2)
    wan_base=$(echo "${NET_EXT}" | cut -d/ -f1)
    case "$wan_prefix" in
        24) wan_mask="255.255.255.0" ;;
        16) wan_mask="255.255.0.0"   ;;
        8)  wan_mask="255.0.0.0"     ;;
        *)  wan_mask="255.255.255.0" ;;
    esac

    cat > "$WPAD_FILE" << WPAD
function FindProxyForURL(url, host) {
    // Loopback e nomes simples — sempre direto
    if (isInNet(host, "127.0.0.0",     "255.0.0.0"))     return "DIRECT";
    if (isPlainHostName(host))                            return "DIRECT";

    // Rede LAN local — direto
    if (isInNet(host, "192.168.0.0",   "255.255.255.0")) return "DIRECT";

    // Rede WAN do gateway — direto
    if (isInNet(host, "${wan_base}", "${wan_mask}"))      return "DIRECT";

    // Intranet 10.0.0.0/8 — DIRETO (preserva NAT 1:1 por cliente)
    // cartoriosap (10.200.x.x), policiapenal (10.200.x.x) etc.
    // NAT 1:1 de cada cliente é preservado pois não passa pelo Squid
    if (isInNet(host, "10.0.0.0",      "255.0.0.0"))     return "DIRECT";

    // Domínios gov SP específicos da intranet — direto pelo hostname
    // (para quando o browser ainda não resolveu o IP)
    if (dnsDomainIs(host, ".cartoriosap.sp.gov.br"))      return "DIRECT";
    if (dnsDomainIs(host, ".policiapenal.sp.gov.br"))     return "DIRECT";
    if (dnsDomainIs(host, ".sap.sp.gov.br"))              return "DIRECT";
    if (dnsDomainIs(host, ".tjsp.jus.br"))                return "DIRECT";
    if (dnsDomainIs(host, ".pje.jus.br"))                 return "DIRECT";

    // Todo o resto passa pelo proxy (controle de acesso pelo Squid)
    return "PROXY ${LAN_IP}:${PROXY_PORT}; DIRECT";
}
WPAD

    cp "$WPAD_FILE" /var/www/html/proxy.pac
    ok "WPAD atualizado — intranet vai direto, internet passa pelo Squid"

    # Recarregar nginx para garantir Content-Type correto
    systemctl is-active nginx &>/dev/null && systemctl reload nginx && ok "nginx recarregado"
fi

# =============================================================================
# CORREÇÃO 5 — squid.conf: remover tcp_outgoing_address duplicado e
#              never_direct/always_direct conflitantes que foram adicionados
# =============================================================================
hdr "5. Corrigindo squid.conf (diretivas conflitantes)"

SQUID_CONF="/etc/squid/squid.conf"
[[ ! -f "$SQUID_CONF" ]] && err "squid.conf não encontrado"

cp "$SQUID_CONF" "${SQUID_CONF}.bak.$(date +%s)"
ok "Backup: ${SQUID_CONF}.bak.*"

python3 - << 'PYFIX5'
with open('/etc/squid/squid.conf', 'r') as f:
    lines = f.readlines()

# Remover linhas que foram adicionadas incorretamente pela correção anterior
remove_patterns = [
    'tcp_outgoing_address ${WAN_IP} dst_intranet',
    'never_direct allow dst_intranet',
    '# tcp_outgoing_address — fallback para clientes que passam pelo proxy',
    '# O WPAD instrui DIRETO para intranet, mas se o cliente ignorar o WPAD',
    '# o Squid usa o WAN_IP do gateway (que tem acesso à intranet gov SP)',
    '# Sem isso o Squid usa o IP da LAN (192.168.x.x) e a conexão é recusada',
    '# never_direct para intranet — nunca tentar cache hierárquico',
]

new_lines = []
for line in lines:
    skip = False
    for pat in remove_patterns:
        if pat in line:
            skip = True
            break
    if not skip:
        new_lines.append(line)

with open('/etc/squid/squid.conf', 'w') as f:
    f.writelines(new_lines)

print(f"Removidas {len(lines) - len(new_lines)} linhas conflitantes do squid.conf")
PYFIX5

# Verificar se tcp_outgoing_address global está presente (deve existir um: sem ACL)
if ! grep -q "^tcp_outgoing_address" "$SQUID_CONF"; then
    warn "tcp_outgoing_address não encontrado — adicionando com WAN_IP"
    echo "" >> "$SQUID_CONF"
    echo "# Forçar Squid a usar IP da WAN como origem (necessário para intranet gov SP)" >> "$SQUID_CONF"
    echo "tcp_outgoing_address ${WAN_IP}" >> "$SQUID_CONF"
fi

# Validar squid.conf
parse_out=$(squid -k check 2>&1 || true)
fatal_count=$(echo "$parse_out" | grep -cE "^[0-9/: ]+FATAL" || true)
if [[ "$fatal_count" -gt 0 ]]; then
    warn "squid.conf com erros FATAIS:"
    echo "$parse_out" | grep "FATAL" | head -5
    warn "Restaurando backup..."
    latest_bak=$(ls -t "${SQUID_CONF}.bak."* 2>/dev/null | head -1)
    [[ -n "$latest_bak" ]] && cp "$latest_bak" "$SQUID_CONF"
    err "Falha ao validar squid.conf — backup restaurado"
else
    ok "squid.conf válido"
    squid -k reconfigure && ok "Squid reconfigurado" || {
        systemctl restart squid && ok "Squid reiniciado"
    }
fi

# =============================================================================
# VERIFICAÇÃO FINAL
# =============================================================================
hdr "VERIFICAÇÃO FINAL"

echo ""
echo -e "  ${BLD}Serviços:${NC}"
for svc in squid named nginx gateway-panel nftables; do
    if systemctl is-active "$svc" &>/dev/null; then
        echo -e "  ${GRN}✓${NC} $svc"
    else
        echo -e "  ${RED}✗${NC} $svc — verifique: systemctl status $svc"
    fi
done

echo ""
echo -e "  ${BLD}nftables — chain forward:${NC}"
# Verificar que a regra permissiva foi removida
if nft list chain inet filter forward 2>/dev/null | grep -q "ip saddr ${NET_INT} accept" && \
   ! nft list chain inet filter forward 2>/dev/null | grep -q "ip daddr\|@ips_livres"; then
    echo -e "  ${RED}✗${NC} Regra de bypass ainda presente — reinicie o script"
else
    echo -e "  ${GRN}✓${NC} Forward controlado — sem bypass genérico"
fi

echo ""
echo -e "  ${BLD}nftables — porta 5000:${NC}"
if nft list chain inet filter input 2>/dev/null | grep -q "tcp dport 5000"; then
    echo -e "  ${GRN}✓${NC} Porta 5000 liberada para $NET_INT"
else
    echo -e "  ${RED}✗${NC} Porta 5000 não encontrada no nftables"
fi

echo ""
echo -e "  ${BLD}Squid — diretivas:${NC}"
if grep -q "^tcp_outgoing_address" "$SQUID_CONF"; then
    echo -e "  ${GRN}✓${NC} tcp_outgoing_address configurado"
else
    echo -e "  ${YLW}⚠${NC} tcp_outgoing_address ausente"
fi
if grep -q "always_direct allow dst_intranet" "$SQUID_CONF"; then
    echo -e "  ${GRN}✓${NC} always_direct para intranet configurado"
else
    echo -e "  ${RED}✗${NC} always_direct para intranet ausente"
fi
if ! grep -q "never_direct allow dst_intranet" "$SQUID_CONF"; then
    echo -e "  ${GRN}✓${NC} never_direct conflitante removido"
else
    echo -e "  ${YLW}⚠${NC} never_direct ainda presente — remova manualmente"
fi

echo ""
echo -e "  ${BLD}WPAD:${NC}"
if grep -q "cartoriosap.sp.gov.br" /var/www/html/wpad.dat 2>/dev/null; then
    echo -e "  ${GRN}✓${NC} WPAD com bypass correto para intranet"
else
    echo -e "  ${RED}✗${NC} WPAD não encontrado ou incorreto"
fi
if ! grep -q "dnsResolve" /var/www/html/wpad.dat 2>/dev/null; then
    echo -e "  ${GRN}✓${NC} dnsResolve removido do WPAD"
else
    echo -e "  ${YLW}⚠${NC} dnsResolve ainda presente no WPAD"
fi

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${GRN}║   CORREÇÃO CONCLUÍDA                                 ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  1. CSS painel — menu lateral visível                ║${NC}"
echo -e "${BLD}${GRN}║  2. Porta 5000 — permanente no nftables              ║${NC}"
echo -e "${BLD}${GRN}║  3. Bypass Squid — bloqueado no nftables             ║${NC}"
echo -e "${BLD}${GRN}║  4. WPAD — bypass apenas para intranet real          ║${NC}"
echo -e "${BLD}${GRN}║  5. squid.conf — diretivas conflitantes removidas    ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Testar:                                             ║${NC}"
echo -e "${BLD}${GRN}║  Painel:   http://${LAN_IP}:5000                     ║${NC}"
echo -e "${BLD}${GRN}║  Cartório: new.cartoriosap.sp.gov.br (via NAT 1:1)   ║${NC}"
echo -e "${BLD}${GRN}║  Bloquear: cliente sem IP nas listas → sem internet  ║${NC}"
echo -e "${BLD}${GRN}║  Logs:     tail -f /var/log/squid/access.log         ║${NC}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════╝${NC}"