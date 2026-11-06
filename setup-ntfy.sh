#!/usr/bin/env bash
# =============================================================================
# setup-ntfy.sh : installe et configure un serveur ntfy + crée les comptes
# Cible : Debian 13 + Apache2 (reverse proxy). A lancer en root.
#   chmod +x setup-ntfy.sh && sudo ./setup-ntfy.sh
# =============================================================================
set -euo pipefail

# ---------- Couleurs / helpers ----------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
info() { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[x]${N} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Lance ce script en root : sudo ./setup-ntfy.sh"

ask() { # ask "question" "défaut" -> écrit dans REPLY
  local q="$1" d="${2:-}"
  if [[ -n "$d" ]]; then read -rp "$q [$d] : " REPLY; REPLY="${REPLY:-$d}"
  else read -rp "$q : " REPLY; fi
}
yesno() { # yesno "question" "o|n" -> code retour 0 si oui
  local q="$1" d="${2:-n}" a
  read -rp "$q (o/n) [$d] : " a; a="${a:-$d}"
  [[ "$a" =~ ^[oOyY] ]]
}
genpass() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-16; }

# ---------- 1. Questions ----------
echo "=============== Configuration ntfy ==============="
ask "Nom de domaine pour ntfy" "ntfy.leo44.cloud"; DOMAIN="$REPLY"
ask "Nombre de comptes à créer" "2"; NB="$REPLY"
[[ "$NB" =~ ^[1-9][0-9]*$ ]] || die "Nombre de comptes invalide"

USERS=(); PASSES=(); ROLES=(); IPHONES=(); TOPICS=()
ANY_IPHONE=0

for ((i=1; i<=NB; i++)); do
  echo; echo "----- Compte $i / $NB -----"
  ask "Nom d'utilisateur" ""; u="$REPLY"
  [[ "$u" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Nom invalide (lettres, chiffres, _ . - seulement)"

  read -rsp "Mot de passe (vide = généré automatiquement) : " p; echo
  [[ -n "$p" ]] || { p="$(genpass)"; warn "Mot de passe généré pour $u"; }

  if yesno "Ce compte est admin ?" "n"; then r="admin"; else r="user"; fi
  if yesno "Ce compte utilise un iPhone ?" "n"; then ip="oui"; ANY_IPHONE=1; else ip="non"; fi

  t="-"
  if [[ "$r" == "user" ]]; then
    ask "Topics autorisés pour $u (motif, * = joker)" "${u}-*"; t="$REPLY"
  fi

  USERS+=("$u"); PASSES+=("$p"); ROLES+=("$r"); IPHONES+=("$ip"); TOPICS+=("$t")
done

echo
if yesno "Activer HTTPS automatiquement avec certbot (le DNS doit déjà pointer ici) ?" "o"; then
  HTTPS=1; BASE_URL="https://${DOMAIN}"
else
  HTTPS=0; BASE_URL="http://${DOMAIN}"
fi

# ---------- 2. Installation ----------
info "Installation des paquets..."
apt-get update -qq
apt-get install -y -qq curl gnupg openssl sudo apache2

if ! command -v ntfy >/dev/null 2>&1; then
  info "Ajout du dépôt officiel ntfy..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://archive.heckel.io/apt/pubkey.txt | gpg --dearmor -o /etc/apt/keyrings/ntfy.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.heckel.io/apt debian main" \
    > /etc/apt/sources.list.d/ntfy.list
  apt-get update -qq
  apt-get install -y -qq ntfy
else
  info "ntfy déjà installé."
fi

# ---------- 3. server.yml ----------
info "Écriture de /etc/ntfy/server.yml..."
[[ -f /etc/ntfy/server.yml ]] && cp /etc/ntfy/server.yml "/etc/ntfy/server.yml.bak.$(date +%s)"

mkdir -p /var/cache/ntfy/attachments /var/lib/ntfy
cat > /etc/ntfy/server.yml <<EOF
base-url: "${BASE_URL}"
listen-http: "127.0.0.1:2586"
behind-proxy: true

cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "24h"

auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
enable-login: true

attachment-cache-dir: "/var/cache/ntfy/attachments"
attachment-total-size-limit: "2G"
attachment-file-size-limit: "20M"
EOF

if [[ $ANY_IPHONE -eq 1 ]]; then
  cat >> /etc/ntfy/server.yml <<EOF

# iPhone : nécessaire pour recevoir les notifications instantanément (APNs via ntfy.sh)
upstream-base-url: "https://ntfy.sh"
EOF
  info "Au moins un iPhone -> upstream-base-url activé."
fi

chown -R ntfy:ntfy /var/cache/ntfy /var/lib/ntfy
systemctl enable ntfy >/dev/null 2>&1 || true
systemctl restart ntfy
sleep 2
systemctl is-active --quiet ntfy || die "ntfy ne démarre pas : journalctl -u ntfy -e"

# ---------- 4. Apache (reverse proxy + WebSocket) ----------
info "Configuration Apache..."
a2enmod proxy proxy_http proxy_wstunnel rewrite headers >/dev/null

cat > "/etc/apache2/sites-available/ntfy.conf" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}

    ProxyPreserveHost On
    SetEnv proxy-nokeepalive 1
    SetEnv proxy-sendchunks 1

    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://127.0.0.1:2586/\$1 [P,L]

    ProxyPass / http://127.0.0.1:2586/
    ProxyPassReverse / http://127.0.0.1:2586/

    ErrorLog \${APACHE_LOG_DIR}/ntfy_error.log
    CustomLog \${APACHE_LOG_DIR}/ntfy_access.log combined
</VirtualHost>
EOF

a2ensite ntfy >/dev/null
apache2ctl configtest
systemctl reload apache2

if [[ $HTTPS -eq 1 ]]; then
  info "HTTPS avec certbot..."
  apt-get install -y -qq certbot python3-certbot-apache
  certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect \
    || warn "certbot a échoué (DNS ?). Relance plus tard : certbot --apache -d ${DOMAIN}"
fi

# ---------- 5. Création des comptes ----------
info "Création des comptes..."
RECAP="/root/ntfy-comptes.txt"
umask 077
{
  echo "# Comptes ntfy - généré le $(date '+%F %T')"
  echo "# Serveur : ${BASE_URL}"
  echo
} > "$RECAP"

for idx in "${!USERS[@]}"; do
  u="${USERS[$idx]}"; p="${PASSES[$idx]}"; r="${ROLES[$idx]}"; ip="${IPHONES[$idx]}"; t="${TOPICS[$idx]}"

  if sudo -u ntfy ntfy user list 2>/dev/null | grep -q "user ${u} "; then
    warn "$u existe déjà -> mot de passe mis à jour"
    sudo -u ntfy env NTFY_PASSWORD="$p" ntfy user change-pass "$u"
  else
    sudo -u ntfy env NTFY_PASSWORD="$p" ntfy user add --role="$r" "$u"
  fi

  if [[ "$r" == "user" && "$t" != "-" ]]; then
    sudo -u ntfy ntfy access "$u" "$t" read-write
  fi

  {
    echo "Utilisateur : $u"
    echo "Mot de passe: $p"
    echo "Rôle        : $r"
    echo "iPhone      : $ip"
    echo "Topics      : $t"
    echo "-----------------------------------"
  } >> "$RECAP"
done

systemctl restart ntfy

# ---------- 6. Résumé ----------
echo
echo "================ TERMINÉ ================"
info "Serveur      : ${BASE_URL}"
info "Comptes      : ${#USERS[@]} (récap + mots de passe : ${RECAP}, lisible par root seulement)"
if [[ $ANY_IPHONE -eq 1 ]]; then
  warn "iPhone : dans l'app ntfy -> Réglages -> Utilisateurs -> ajoute ${BASE_URL} + login/mot de passe,"
  warn "         puis abonne-toi au topic. Sans upstream-base-url, les push iOS seraient retardés."
fi
echo
echo "Test (depuis ce serveur) :"
echo "  curl -u ${USERS[0]}:MOT_DE_PASSE -d 'ça marche' ${BASE_URL}/${USERS[0]}-test"
echo
echo "Commandes utiles :"
echo "  sudo -u ntfy ntfy user list"
echo "  sudo -u ntfy ntfy user del NOM"
echo "  sudo -u ntfy ntfy access NOM 'topic' read-write"
