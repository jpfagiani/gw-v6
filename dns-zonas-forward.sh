#!/bin/bash
# =============================================================================
# CDPNI — Zonas Forward Condicionais DNS
# Adiciona zonas de encaminhamento ao BIND9 sem reinstalar o gateway
# Execute como root: sudo bash dns-zonas-forward.sh
# =============================================================================
IFS=$'\n\t'
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*"; exit 1; }
hdr()  { echo -e "\n${BLD}${CYN}══════════════════════════════════════════${NC}";
         echo -e "${BLD}${CYN}  $*${NC}";
         echo -e "${BLD}${CYN}══════════════════════════════════════════${NC}"; }

[[ $EUID -ne 0 ]] && err "Execute como root: sudo bash $0"

# ===========================================================================
# CONFIGURAÇÃO — Ajuste os IPs dos DNS conforme necessário
# ===========================================================================
DNS1="10.14.8.20"   # DNS que resolve policiapenal.sp.gov.br
DNS2="10.1.6.222"   # DNS que resolve cartoriosap.sp.gov.br
DNS3="10.14.8.16"   # DNS alternativo

NAMED_LOCAL="/etc/bind/named.conf.local"

[[ ! -f "$NAMED_LOCAL" ]] && err "BIND9 não encontrado em $NAMED_LOCAL"

hdr "1. Verificando zonas existentes"

# Verificar quais zonas já existem
ZONAS=(
    "policiapenal.sp.gov.br"
    "gpu.policiapenal.sp.gov.br"
    "cartoriosap.sp.gov.br"
    "new.cartoriosap.sp.gov.br"
    "sap.sp.gov.br"
    "sp.gov.br"
    "tjsp.jus.br"
    "esaj.tjsp.jus.br"
    "pje.jus.br"
)

NOVAS=()
for zona in "${ZONAS[@]}"; do
    if grep -q "\"${zona}\"" "$NAMED_LOCAL" 2>/dev/null; then
        ok "Zona já existe: ${zona} — mantida"
    else
        NOVAS+=("$zona")
    fi
done

if [[ ${#NOVAS[@]} -eq 0 ]]; then
    ok "Todas as zonas já estão configuradas!"
    named-checkconf && systemctl reload named && ok "DNS recarregado" || warn "Verifique: named-checkconf"
    exit 0
fi

echo ""
echo -e "  ${BLD}Zonas a adicionar (${#NOVAS[@]}):${NC}"
for z in "${NOVAS[@]}"; do
    echo -e "  ${CYN}  + ${z}${NC}"
done

hdr "2. Adicionando zonas forward condicionais"

# Backup do named.conf.local
BAK_FILE="${NAMED_LOCAL}.bak.$(date +%s)"
cp "$NAMED_LOCAL" "$BAK_FILE"
ok "Backup: $BAK_FILE"

# Gerar o bloco de zonas a adicionar
ZONAS_BLOCK="
# ==========================================================================
# ZONAS FORWARD CONDICIONAIS — Intranet Gov SP
# Adicionadas por dns-zonas-forward.sh em $(date '+%d/%m/%Y %H:%M')
# Cada domínio encaminhado para o DNS que sabe resolvê-lo
# ==========================================================================
"

for zona in "${NOVAS[@]}"; do
    case "$zona" in
        "policiapenal.sp.gov.br"|"gpu.policiapenal.sp.gov.br")
            DNS_FOR="$DNS1"
            ;;
        "cartoriosap.sp.gov.br"|"new.cartoriosap.sp.gov.br")
            DNS_FOR="$DNS2"
            ;;
        "sap.sp.gov.br")
            DNS_FOR="$DNS2; $DNS1"
            ;;
        "sp.gov.br")
            DNS_FOR="$DNS1; $DNS2; $DNS3"
            ;;
        "tjsp.jus.br"|"esaj.tjsp.jus.br"|"pje.jus.br")
            DNS_FOR="$DNS1; $DNS2"
            ;;
        *)
            DNS_FOR="$DNS1; $DNS2"
            ;;
    esac

    ZONAS_BLOCK+="
zone \"${zona}\" {
    type forward;
    forwarders { ${DNS_FOR}; };
    forward only;
};
"
done

# Adicionar ao named.conf.local
echo "$ZONAS_BLOCK" >> "$NAMED_LOCAL"
ok "Zonas adicionadas a $NAMED_LOCAL"

hdr "3. Validando configuração"

if named-checkconf 2>/dev/null; then
    ok "named-checkconf: OK"
else
    warn "named-checkconf com erro — restaurando backup..."
    cp "$BAK_FILE" "$NAMED_LOCAL" 2>/dev/null
    named-checkconf
    err "Configuração inválida. Backup restaurado de: $BAK_FILE"
fi

hdr "4. Recarregando DNS"

if systemctl is-active named &>/dev/null; then
    systemctl reload named && ok "named recarregado" || {
        systemctl restart named && ok "named reiniciado" || err "Falha ao recarregar named"
    }
else
    systemctl restart named && ok "named iniciado" || err "Falha ao iniciar named"
fi

sleep 1

hdr "5. Testando resolução"

echo ""
echo -e "  ${BLD}Testando domínios críticos:${NC}"

for host in "gpu.policiapenal.sp.gov.br" "new.cartoriosap.sp.gov.br"; do
    result=$(dig @127.0.0.1 "$host" +short 2>/dev/null | head -1)
    if [[ -n "$result" ]]; then
        echo -e "  ${GRN}✔${NC} ${host} → ${result}"
    else
        echo -e "  ${YLW}⚠${NC} ${host} → sem resposta (verifique conectividade com ${DNS1}/${DNS2})"
    fi
done

echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}${GRN}║   DNS ZONAS FORWARD — CONCLUÍDO                 ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Zonas adicionadas: ${#NOVAS[@]}                             ║${NC}"
echo -e "${BLD}${GRN}║  policiapenal → DNS ${DNS1}          ║${NC}"
echo -e "${BLD}${GRN}║  cartoriosap  → DNS ${DNS2}           ║${NC}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}${GRN}║  Verificar: dig @127.0.0.1 gpu.policiapenal...  ║${NC}"
echo -e "${BLD}${GRN}║  Logs DNS:  journalctl -u named -f               ║${NC}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════╝${NC}"
