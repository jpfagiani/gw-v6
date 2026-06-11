#!/bin/bash
# Remove tudo instalado pelo gw-v1.sh para reinstalação limpa

echo "=== REMOVENDO INSTALAÇÃO DO GATEWAY ==="

# 1. Parar e desabilitar serviços
for svc in gateway-panel squid named nftables nginx chrony fail2ban; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# 2. Remover pacotes
apt-get remove --purge -y \
    squid squid-openssl \
    bind9 bind9utils dnsutils \
    nginx \
    chrony \
    fail2ban \
    python3-pam \
    2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true

# 3. Remover arquivos de configuração
rm -rf /etc/squid/
rm -rf /var/cache/squid/
rm -rf /var/log/squid/
rm -rf /var/lib/squid/
rm -rf /etc/bind/
rm -rf /var/cache/bind/
rm -rf /etc/nginx/sites-available/gateway
rm -rf /etc/nginx/sites-enabled/gateway
rm -f  /var/www/html/index.html
rm -f  /var/www/html/wpad.dat
rm -rf /var/www/html/ca/
rm -rf /opt/gateway-panel/
rm -rf /etc/gateway/
rm -f  /etc/systemd/system/gateway-panel.service
rm -f  /etc/cron.d/gateway-horarios
rm -f  /usr/local/bin/nat-manager
rm -f  /usr/local/bin/gateway-status
rm -f  /usr/local/bin/reload-gateway
rm -f  /usr/local/bin/squid-fix
rm -f  /usr/local/bin/fix-nftables
rm -f  /etc/sysctl.d/99-gateway.conf
rm -f  /usr/local/share/ca-certificates/cdpni-ca.crt

# 4. Restaurar resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 5. Limpar nftables
nft flush ruleset 2>/dev/null || true
rm -f /etc/nftables.conf

# 6. Recarregar systemd
systemctl daemon-reload
update-ca-certificates 2>/dev/null || true

echo ""
echo "=== LIMPEZA CONCLUÍDA ==="
echo "Execute agora: sudo bash gw-v1.sh"