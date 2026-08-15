#!/usr/bin/env bash
#
# EndlessClient — installation automatique complète (Debian 12 / Ubuntu 24.04)
#
# Automatise DEPLOYMENT.md de bout en bout :
#   endlessclient.dev        -> boutique      (plus-website, Next.js, :3000)
#   www.endlessclient.dev    -> redirection   -> endlessclient.dev
#   api.endlessclient.dev    -> API + WS      (plus-backend, Rust, :8080)
#   admin.endlessclient.dev  -> dashboard     (plus-admin-dashboard, statique)
#   cdn.endlessclient.dev    -> objets S3     (MinIO, :9000)
#
# Interne uniquement : PostgreSQL :5432, render-service :8090, console MinIO :9001
#
# Tous les mots de passe sont generes aleatoirement et recapitules a la fin dans
#   /opt/endless/secrets/IDENTIFIANTS.txt   (chmod 600)
#
# Usage :
#   sudo ./install.sh --email vous@exemple.com
#   sudo ./install.sh --help
#
# -E : le piege ERR defini plus bas doit aussi se declencher dans les fonctions
# et les sous-shells, sinon un echec y sort en silence.
set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Valeurs par defaut
# ─────────────────────────────────────────────────────────────────────────────
DOMAIN="endlessclient.dev"
LETSENCRYPT_EMAIL=""
REPO_URL="https://github.com/Th3DarkSand8tch/AstralClient.git"
REPO_BRANCH=""
SRC_DIR=""                      # checkout existant a reutiliser (sinon clone)
SERVICE_USER="endless"
BASE_DIR="/opt/endless"
DB_NAME="endless_plus"
DB_USER="endless"
BUCKET="endless-cosmetics"
S3_USER="endless-api"
MINIO_ROOT_USER="endless-root"
ADMIN_HTTP_USER="admin"
STRIPE_SECRET=""
STRIPE_WEBHOOK_SECRET=""
ADMIN_UUID=""
ADMIN_NAME=""
SKIP_TLS=0
SKIP_RENDER=0
SKIP_DNS_CHECK=0
SEED_DEMO=0
PATCH_POLYPLUS=0
ASSUME_YES=0
DEBUG=0

LOG_FILE="/var/log/endless-install.log"
DEBUG_LOG="/var/log/endless-install.debug.log"

# Pilotes de verbosite, bascules d'un bloc par --debug. NULL doit etre defini
# ici, avant le moindre usage : toutes les redirections du script passent par
# lui, et `set -u` ferait tout sauter sur une variable non definie.
NULL="/dev/null"
APT_Q="-qq"
NPM_FLAGS="--no-audit --no-fund"
CARGO_FLAGS=""

# ─────────────────────────────────────────────────────────────────────────────
# Sortie
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_STEP=$'\033[1;36m'; C_OK=$'\033[0;32m'
  C_WARN=$'\033[0;33m'; C_ERR=$'\033[1;31m'
else
  C_RESET=""; C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> [%02d] %s%s\n' "$C_STEP" "$STEP_NO" "$*" "$C_RESET"; }
ok()   { printf '%s     ok   %s%s\n' "$C_OK" "$*" "$C_RESET"; }
note() { printf '%s     note %s%s\n' "$C_WARN" "$*" "$C_RESET"; }
die()  { printf '\n%s     ERREUR %s%s\n\n' "$C_ERR" "$*" "$C_RESET" >&2; exit 1; }

# Sans ce piege, `set -e` rend la main sans un mot : on revient au prompt sans
# savoir quelle commande a echoue ni a quelle ligne. Pour un installeur non
# interactif c'est le pire mode d'echec possible.
on_error() {
  local code=$?          # doit rester la premiere instruction
  local line="$1" cmd="$2"
  printf '\n%s     ERREUR ligne %s (code %s)%s\n' "$C_ERR" "$line" "$code" "$C_RESET" >&2
  printf '%s       commande : %s%s\n' "$C_ERR" "$cmd" "$C_RESET" >&2
  if (( DEBUG )); then
    printf '%s       pile d appel :%s\n' "$C_ERR" "$C_RESET" >&2
    local i
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
      printf '         %s() <- %s:%s\n' \
        "${FUNCNAME[i]}" "${BASH_SOURCE[i]##*/}" "${BASH_LINENO[i-1]}" >&2
    done
    printf '\n       trace complete : %s\n' "$DEBUG_LOG" >&2
  else
    printf '\n       relancez avec --debug pour la trace complete de chaque commande\n' >&2
  fi
  # La trace xtrace part sur son propre descripteur et ne contient donc PAS la
  # sortie des commandes : c'est le journal qui porte le message d'erreur reel.
  # Sans ce rappel, on reste devant un "code 1" sans explication.
  if [[ -s "$LOG_FILE" ]]; then
    printf '\n       dernieres lignes du journal (la vraie erreur est ici) :\n' >&2
    tail -n 30 "$LOG_FILE" 2>/dev/null | sed 's/^/         /' >&2 || true
  fi
  printf '\n       journal        : %s\n\n' "$LOG_FILE" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<'USAGE'
EndlessClient — installation automatique

  sudo ./install.sh [options]

Options principales
  --domain <dom>            Domaine racine                (defaut: endlessclient.dev)
  --email <mail>            Email Let's Encrypt           (defaut: admin@<domaine>)
  --repo-url <url>          Depot git a cloner
  --branch <nom>            Branche a utiliser
  --src-dir <chemin>        Reutilise un checkout existant au lieu de cloner

Stripe (les 4 variables doivent exister ; vides = acceptees, absentes = refus)
  --stripe-secret <sk_...>          Cle secrete Stripe
  --stripe-webhook-secret <whsec_>  Secret de signature du webhook

Premier administrateur
  --admin-uuid <uuid>       UUID Minecraft (avec tirets)
  --admin-name <pseudo>     Pseudo Minecraft, resolu via l'API Mojang

Ajustements
  --skip-tls                Pas de certbot : tout en HTTP (DNS pas encore pret)
  --skip-render             N'installe pas le service de rendu des couvertures
  --skip-dns-check          Ne verifie pas que les enregistrements A pointent ici
  --seed-demo               Charge le catalogue de demonstration (TRUNCATE !)
  --patch-polyplus          Reecrit BackendUrl.kt vers https://api.<domaine>
  --yes                     Aucune question, tout en automatique
  --debug                   Trace complete : chaque commande avec son numero de
                            ligne dans /var/log/endless-install.debug.log, plus
                            apt/npm/cargo verbeux et sortie jamais etouffee
  -h, --help                Cette aide

Exemple
  sudo ./install.sh --email moi@exemple.com --admin-name Wyvest --yes
USAGE
}

# ─────────────────────────────────────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)                DOMAIN="${2:?}"; shift 2 ;;
    --email)                 LETSENCRYPT_EMAIL="${2:?}"; shift 2 ;;
    --repo-url)              REPO_URL="${2:?}"; shift 2 ;;
    --branch)                REPO_BRANCH="${2:?}"; shift 2 ;;
    --src-dir)               SRC_DIR="${2:?}"; shift 2 ;;
    --stripe-secret)         STRIPE_SECRET="${2:?}"; shift 2 ;;
    --stripe-webhook-secret) STRIPE_WEBHOOK_SECRET="${2:?}"; shift 2 ;;
    --admin-uuid)            ADMIN_UUID="${2:?}"; shift 2 ;;
    --admin-name)            ADMIN_NAME="${2:?}"; shift 2 ;;
    --skip-tls)              SKIP_TLS=1; shift ;;
    --skip-render)           SKIP_RENDER=1; shift ;;
    --skip-dns-check)        SKIP_DNS_CHECK=1; shift ;;
    --seed-demo)             SEED_DEMO=1; shift ;;
    --patch-polyplus)        PATCH_POLYPLUS=1; shift ;;
    --yes|-y)                ASSUME_YES=1; shift ;;
    --debug)                 DEBUG=1; shift ;;
    -h|--help)               usage; exit 0 ;;
    *)                       usage; die "option inconnue : $1" ;;
  esac
done

SRC_ROOT="${SRC_DIR:-$BASE_DIR/src}"
STATE_DIR="$BASE_DIR/secrets"
CRED_FILE="$STATE_DIR/IDENTIFIANTS.txt"
ENV_FILE="$STATE_DIR/backend.env"
HTPASSWD_FILE="/etc/nginx/endless-admin.htpasswd"

HOST_SHOP="$DOMAIN"
HOST_WWW="www.$DOMAIN"
HOST_API="api.$DOMAIN"
HOST_ADMIN="admin.$DOMAIN"
HOST_CDN="cdn.$DOMAIN"
ALL_HOSTS=("$HOST_SHOP" "$HOST_WWW" "$HOST_API" "$HOST_ADMIN" "$HOST_CDN")

[[ -n "$LETSENCRYPT_EMAIL" ]] || LETSENCRYPT_EMAIL="admin@$DOMAIN"

if (( SKIP_TLS )); then SCHEME="http"; else SCHEME="https"; fi
URL_SHOP="$SCHEME://$HOST_SHOP"
URL_API="$SCHEME://$HOST_API"
URL_ADMIN="$SCHEME://$HOST_ADMIN"
URL_CDN="$SCHEME://$HOST_CDN"

# ─────────────────────────────────────────────────────────────────────────────
# Aides
# ─────────────────────────────────────────────────────────────────────────────
# GIT_TERMINAL_PROMPT=0 et BatchMode : une invite d'authentification git ou ssh
# echoue immediatement au lieu de figer l'installation sur une question que
# personne ne lit. sudo remet l'environnement a zero, donc ces variables doivent
# etre posees dans la commande elle-meme, pas exportees par le parent.
as_service_user() {
  sudo -u "$SERVICE_USER" bash -lc \
    "export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'; $1"
}

gen_secret() { openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-40; }

# `npm ci` exige un lockfile et echoue sinon. Or seul render-service en versionne
# un : plus-website et plus-admin-dashboard listent package-lock.json dans leur
# .gitignore, donc un depot fraichement clone n'en a pas. On retombe alors sur
# `npm install`, qui resout depuis package.json et ecrit le lockfile au passage.
js_install() {
  local dir="$1" label="$2" prefix="${3:-}"
  local cmd
  if [[ -f "$dir/package-lock.json" ]]; then
    cmd="npm ci $NPM_FLAGS"
  else
    note "$label : aucun package-lock.json versionne, bascule sur npm install"
    cmd="npm install $NPM_FLAGS"
  fi
  as_service_user "cd '$dir' && $prefix$cmd"
}

# Relit une valeur deja generee lors d'une execution precedente, sinon en cree
# une. Sans cela, relancer le script casserait Postgres et MinIO, dont les mots
# de passe sont deja poses.
remember() {
  # Deux declarations distinctes : bash developpe tous les mots de la commande
  # avant que `local` n'assigne, donc `local key=... file=".../$key"` lirait un
  # $key encore inexistant — et `set -u` transforme ca en arret immediat.
  local key="$1"
  local file="$STATE_DIR/$key"
  if [[ -s "$file" ]]; then
    cat "$file"
  else
    local value; value="$(gen_secret)"
    printf '%s' "$value" > "$file"
    chmod 600 "$file"
    printf '%s' "$value"
  fi
}

wait_for_port() {
  local port="$1" timeout="${2:-60}" waited=0
  while (( waited < timeout )); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>"$NULL"; then exec 3>&- 2>"$NULL" || true; return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

confirm() {
  (( ASSUME_YES )) && return 0
  local answer
  read -r -p "     $1 [o/N] " answer
  [[ "$answer" =~ ^([oO]|[yY])$ ]]
}

dash_uuid() {
  local u="${1//-/}"
  [[ ${#u} -eq 32 ]] || { printf '%s' "$1"; return; }
  printf '%s-%s-%s-%s-%s' "${u:0:8}" "${u:8:4}" "${u:12:4}" "${u:16:4}" "${u:20:12}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "a lancer en root : sudo ./install.sh [options]"
[[ -r /etc/os-release ]] || die "/etc/os-release introuvable : distribution non supportee."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) die "ce script cible Debian 12 / Ubuntu 24.04 (detecte : ${PRETTY_NAME:-inconnu})." ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

if (( DEBUG )); then
  # La sortie normalement jetee redevient visible, et les gestionnaires de
  # paquets cessent de se taire.
  NULL="/dev/stderr"
  APT_Q=""
  NPM_FLAGS="--no-audit --no-fund --loglevel verbose"
  CARGO_FLAGS="--verbose"

  # La trace part sur son propre descripteur : le terminal reste lisible et le
  # fichier contient tout. PS4 donne fichier:ligne:fonction pour chaque commande.
  : > "$DEBUG_LOG"
  chmod 600 "$DEBUG_LOG"
  exec 9>>"$DEBUG_LOG"
  export BASH_XTRACEFD=9
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}(): '
  set -x
fi

printf '\n%s  EndlessClient — installation automatique%s\n' "$C_STEP" "$C_RESET"
printf '  domaine   %s\n' "$DOMAIN"
printf '  systeme   %s\n' "${PRETTY_NAME:-inconnu}"
printf '  journal   %s\n' "$LOG_FILE"
if (( SKIP_TLS )); then
  printf '  TLS       desactive (--skip-tls)\n'
else
  printf "  TLS       Let's Encrypt, %s\n" "$LETSENCRYPT_EMAIL"
fi

if (( DEBUG )); then
  printf '  debug     %s\n' "$DEBUG_LOG"
  printf '%s  !! la trace contient les mots de passe en clair (set -x) : fichier en\n' "$C_WARN"
  printf '     0600, a supprimer une fois le diagnostic termine.%s\n' "$C_RESET"
  # Etat de la machine : la moitie des pannes d'installation se lisent ici.
  {
    printf '\n===== environnement =====\n'
    printf '%s\n' "$(uname -a)"
    printf '%s\n' "${PRETTY_NAME:-inconnu}"
    printf -- '--- memoire ---\n';  free -h        2>&1 || true
    printf -- '--- disque ---\n';   df -h /  /opt  2>&1 || true
    printf -- '--- versions ---\n'
    for tool in bash git curl node npm psql nginx openssl; do
      printf '%-8s %s\n' "$tool" "$(command -v "$tool" 2>&1 || echo absent)"
    done
    printf '=========================\n\n'
  } >&9 2>&1
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Paquets systeme"
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update $APT_Q
apt-get -y $APT_Q install \
  build-essential pkg-config libssl-dev git curl ca-certificates \
  nginx ufw unzip zip jq openssl dnsutils apache2-utils \
  postgresql postgresql-contrib
ok "outils de base, nginx, postgresql"

if ! command -v node >"$NULL" 2>&1 || [[ "$(node --version | sed 's/^v\([0-9]*\).*/\1/')" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get -y $APT_Q install nodejs
fi
ok "node $(node --version), npm $(npm --version)"

# ─────────────────────────────────────────────────────────────────────────────
step "DNS"
# ─────────────────────────────────────────────────────────────────────────────
if (( SKIP_DNS_CHECK )); then
  note "verification ignoree (--skip-dns-check)"
else
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>"$NULL" || true)"
  [[ -n "$public_ip" ]] && ok "IP publique de ce serveur : $public_ip" || true
  dns_ok=1
  for host in "${ALL_HOSTS[@]}"; do
    resolved="$(dig +short "$host" A | tr '\n' ' ' | sed 's/ *$//')"
    if [[ -z "$resolved" ]]; then
      note "$host ne resout pas"; dns_ok=0
    elif [[ -n "$public_ip" && "$resolved" != *"$public_ip"* ]]; then
      note "$host -> $resolved (attendu $public_ip)"; dns_ok=0
    else
      ok "$host -> $resolved"
    fi
  done
  if (( ! dns_ok )) && (( ! SKIP_TLS )); then
    note "certbot echouera tant que les 5 enregistrements A ne pointent pas ici."
    confirm "Continuer quand meme ?" || die "abandon : corrigez le DNS, ou relancez avec --skip-tls."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Utilisateur de service et arborescence"
# ─────────────────────────────────────────────────────────────────────────────
if ! id -u "$SERVICE_USER" >"$NULL" 2>&1; then
  useradd --system --create-home --home-dir "$BASE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "utilisateur '$SERVICE_USER' cree"
else
  ok "utilisateur '$SERVICE_USER' deja present"
fi
mkdir -p "$BASE_DIR"/{src,bin,web,secrets}
chown "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR"/{src,bin,web}
# Les secrets restent a root : le service n'a besoin de lire que backend.env,
# qui est explicitement passe en 0640 root:$SERVICE_USER plus bas.
chown root:"$SERVICE_USER" "$STATE_DIR"
chmod 750 "$STATE_DIR"
ok "$BASE_DIR/{src,bin,web,secrets}"

# ─────────────────────────────────────────────────────────────────────────────
step "Pare-feu"
# ─────────────────────────────────────────────────────────────────────────────
ufw allow OpenSSH >"$NULL"
ufw allow 'Nginx Full' >"$NULL"
ufw --force enable >"$NULL"
ok "ufw : SSH + HTTP/HTTPS uniquement, le reste passe par nginx en loopback"

# ─────────────────────────────────────────────────────────────────────────────
step "Sources"
# ─────────────────────────────────────────────────────────────────────────────
# plus-website/package-lock.json epingle skinview3d sur
# git+ssh://git@github.com/Polyfrost/skinview3d.git. Sur un serveur neuf il n'y a
# ni cle SSH ni known_hosts : git pose sa question de verification d'hote et
# `npm ci` se fige indefiniment, sans message. Le depot est public, donc on
# reecrit vers https. Sans ca, l'etape "Boutique" ne se termine jamais.
as_service_user 'git config --global --unset-all url."https://github.com/".insteadOf || true'
as_service_user 'git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"'
as_service_user 'git config --global --add url."https://github.com/".insteadOf "git@github.com:"'
ok "github.com reecrit en https pour '$SERVICE_USER' (dependances git)"

if [[ -n "$SRC_DIR" ]]; then
  [[ -d "$SRC_ROOT" ]] || die "--src-dir : $SRC_ROOT n'existe pas."
  chown -R "$SERVICE_USER:$SERVICE_USER" "$SRC_ROOT"
  ok "checkout existant : $SRC_ROOT"
elif [[ -d "$SRC_ROOT/.git" ]]; then
  as_service_user "cd '$SRC_ROOT' && git pull --ff-only" || note "git pull a echoue, on garde le checkout en place"
  ok "depot mis a jour : $SRC_ROOT"
else
  rm -rf "$SRC_ROOT"; mkdir -p "$SRC_ROOT"; chown "$SERVICE_USER:$SERVICE_USER" "$SRC_ROOT"
  if [[ -n "$REPO_BRANCH" ]]; then
    as_service_user "git clone --branch '$REPO_BRANCH' '$REPO_URL' '$SRC_ROOT'"
  else
    as_service_user "git clone '$REPO_URL' '$SRC_ROOT'"
  fi
  ok "depot clone dans $SRC_ROOT"
fi

BACKEND_SRC="$SRC_ROOT/plus-backend-main"
SHOP_SRC="$SRC_ROOT/plus-website"
DASH_SRC="$SRC_ROOT/plus-admin-dashboard"
RENDER_SRC="$BACKEND_SRC/render-service"

# Verifier les trois composants d'un coup, et montrer ce qui est reellement la.
# Un depot ou une branche qui ne contient pas plus-website faisait echouer
# l'etape "Boutique" des sa premiere redirection, sans aucun message.
for required in "$BACKEND_SRC" "$SHOP_SRC" "$DASH_SRC"; do
  # Tester -d ne suffit pas : ce depot declare plus-website et
  # plus-admin-dashboard comme sous-modules (gitlink, mode 160000) mais ne
  # fournit aucun .gitmodules. Un clone cree donc des dossiers VIDES, que -d
  # accepte, et l'echec ne surgit qu'au npm install, sans rapport apparent.
  if [[ -d "$required" && -n "$(ls -A "$required" 2>/dev/null)" ]]; then continue; fi
  if [[ -d "$required" ]]; then
    note "$(basename "$required") existe mais est VIDE."
    note "Ce depot le declare comme sous-module sans .gitmodules : aucun clone ne"
    note "peut le remplir. Transferez votre copie locale sur le serveur, puis"
    note "relancez avec --src-dir, ou copiez le dossier dans $SRC_ROOT."
  fi
  note "contenu reel de $SRC_ROOT :"
  ls -1 "$SRC_ROOT" | sed 's/^/            /'
  die "$(basename "$required") introuvable — mauvais depot ou mauvaise branche ? voir --repo-url, --branch, --src-dir"
done
ok "plus-backend-main, plus-website et plus-admin-dashboard presents"

# ─────────────────────────────────────────────────────────────────────────────
step "Identifiants"
# ─────────────────────────────────────────────────────────────────────────────
DB_PASSWORD="$(remember db_password)"
MINIO_ROOT_PASSWORD="$(remember minio_root_password)"
S3_SECRET="$(remember s3_secret)"
ADMIN_PASSWORD="$(remember admin_password)"
ADMIN_HTTP_PASSWORD="$(remember admin_http_password)"
ok "5 secrets generes ou relus depuis $STATE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
step "PostgreSQL"
# ─────────────────────────────────────────────────────────────────────────────
systemctl enable --now postgresql >"$NULL"
role_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")"
if [[ "$role_exists" == "1" ]]; then
  sudo -u postgres psql -qc "ALTER ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD'" >"$NULL"
  ok "role '$DB_USER' mis a jour"
else
  sudo -u postgres psql -qc "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD'" >"$NULL"
  ok "role '$DB_USER' cree"
fi

db_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
if [[ "$db_exists" != "1" ]]; then
  sudo -u postgres psql -qc "CREATE DATABASE $DB_NAME OWNER $DB_USER" >"$NULL"
  ok "base '$DB_NAME' creee"
else
  ok "base '$DB_NAME' deja presente"
fi

# pg_trgm exige le superutilisateur : on l'installe ici pour que le role
# applicatif n'ait pas besoin de ce privilege pendant les migrations.
sudo -u postgres psql -d "$DB_NAME" -qc 'CREATE EXTENSION IF NOT EXISTS pg_trgm' >"$NULL"
ok "extension pg_trgm installee"

listen="$(sudo -u postgres psql -tAc 'SHOW listen_addresses')"
if [[ "$listen" == "localhost" || "$listen" == "127.0.0.1" ]]; then
  ok "postgres en loopback ($listen)"
else
  note "postgres ecoute sur '$listen' — a restreindre a localhost"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Stockage objet (MinIO)"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v minio >"$NULL" 2>&1; then
  curl -fsSLo /tmp/minio.deb https://dl.min.io/server/minio/release/linux-amd64/minio.deb
  dpkg -i /tmp/minio.deb >"$NULL"
  rm -f /tmp/minio.deb
  ok "minio installe"
else
  ok "minio deja installe"
fi

if ! command -v mc >"$NULL" 2>&1; then
  curl -fsSLo /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc
  install -m 0755 /tmp/mc /usr/local/bin/mc
  rm -f /tmp/mc
  ok "client mc installe"
fi

id -u minio-user >"$NULL" 2>&1 || \
  useradd --system --home-dir /var/lib/minio --shell /usr/sbin/nologin minio-user
mkdir -p /var/lib/minio
chown -R minio-user:minio-user /var/lib/minio

cat > /etc/default/minio <<EOF
MINIO_VOLUMES="/var/lib/minio"
MINIO_OPTS="--address 127.0.0.1:9000 --console-address 127.0.0.1:9001"
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
EOF
chmod 600 /etc/default/minio

systemctl enable minio >"$NULL"
systemctl restart minio
wait_for_port 9000 90 || die "MinIO n'ecoute pas sur 9000 — voir: journalctl -u minio -n 50"
ok "minio en ecoute sur 127.0.0.1:9000 (console 9001)"

mc alias set endless "http://127.0.0.1:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >"$NULL"
mc mb --ignore-existing "endless/$BUCKET" >"$NULL"
# Une cle dediee a l'API plutot que les identifiants root.
if mc admin user info endless "$S3_USER" >"$NULL" 2>&1; then
  mc admin user remove endless "$S3_USER" >"$NULL"
fi
mc admin user add endless "$S3_USER" "$S3_SECRET" >"$NULL"
mc admin policy attach endless readwrite --user "$S3_USER" >"$NULL" 2>&1 || true
ok "bucket '$BUCKET' et cle applicative '$S3_USER' prets"
note "le bucket reste prive : les lectures passent par des URL presignees"

# ─────────────────────────────────────────────────────────────────────────────
step "Compilation du backend (Rust 1.92, long a la premiere execution)"
# ─────────────────────────────────────────────────────────────────────────────
if ! as_service_user 'command -v cargo' >"$NULL" 2>&1; then
  as_service_user 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'
  ok "rustup installe pour '$SERVICE_USER'"
fi
as_service_user "source \$HOME/.cargo/env && cd '$BACKEND_SRC' && cargo build --release $CARGO_FLAGS"

BACKEND_BIN="$(find "$BACKEND_SRC/target/release" -maxdepth 1 -type f -name 'plus-backend*' ! -name '*.d' | head -n1)"
[[ -n "$BACKEND_BIN" ]] || die "binaire plus-backend introuvable dans $BACKEND_SRC/target/release"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$BACKEND_BIN" "$BASE_DIR/bin/plus-backend"
ok "binaire installe : $BASE_DIR/bin/plus-backend"

# ─────────────────────────────────────────────────────────────────────────────
step "Service de rendu des couvertures"
# ─────────────────────────────────────────────────────────────────────────────
RENDER_ENABLED=0
if (( SKIP_RENDER )); then
  note "ignore (--skip-render) : les cosmetiques seront enregistres sans couverture"
elif [[ ! -d "$RENDER_SRC" ]]; then
  note "render-service absent du depot ; ignore"
else
  apt-get -y $APT_Q install chromium >"$NULL" 2>&1 || apt-get -y $APT_Q install chromium-browser >"$NULL" 2>&1 || true
  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
  if [[ -z "$CHROMIUM_BIN" ]]; then
    note "aucun chromium installable ; service de rendu ignore"
  else
    js_install "$RENDER_SRC" "render-service" "PUPPETEER_SKIP_DOWNLOAD=true "
    as_service_user "cd '$RENDER_SRC' && node scripts/fetch-default-skin.mjs" || note "skin par defaut non recuperee"

    cat > /etc/systemd/system/endless-render.service <<EOF
[Unit]
Description=EndlessClient cosmetic render service
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$RENDER_SRC
Environment=PORT=8090
Environment=PUPPETEER_EXECUTABLE_PATH=$CHROMIUM_BIN

# Chromium ecrit un profil et un cache sous \$HOME. Le HOME de $SERVICE_USER est
# $BASE_DIR, que ProtectSystem=strict rend en lecture seule : Chrome meurt au
# lancement, et comme server.js lance le navigateur avant d'ouvrir le port, le
# service ne repond jamais. StateDirectory fournit un repertoire inscriptible.
StateDirectory=endless-render
Environment=HOME=/var/lib/endless-render

ExecStart=/usr/bin/node src/server.js
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$RENDER_SRC

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable endless-render >"$NULL"
    systemctl restart endless-render
    # Le premier lancement de Chrome est lent sur un petit VPS.
    if wait_for_port 8090 150; then
      RENDER_ENABLED=1
      ok "endless-render actif sur 127.0.0.1:8090 ($CHROMIUM_BIN)"
    else
      note "endless-render n'a pas demarre — voir: journalctl -u endless-render -n 50"
      note "l'installation continue : les cosmetiques seront simplement sans couverture"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Configuration du backend"
# ─────────────────────────────────────────────────────────────────────────────
if (( RENDER_ENABLED )); then RENDER_URL="http://127.0.0.1:8090"; else RENDER_URL=""; fi

# Les quatre STRIPE_* sont obligatoires : vides oui, absentes non — le processus
# refuse de demarrer si l'une manque.
cat > "$ENV_FILE" <<EOF
RUST_LOG=info,sea_orm=warn,sqlx=warn

BIND_ADDR=127.0.0.1:8080

DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME

# Les URL presignees sont construites a partir de ceci : ce doit etre le nom
# d'hote public, sinon toutes les images 404 dans le navigateur et en jeu.
S3_BUCKET_NAME=$BUCKET
S3_BUCKET_REGION=us-east-1
S3_BUCKET_ENDPOINT=$URL_CDN
AWS_ACCESS_KEY_ID=$S3_USER
AWS_SECRET_ACCESS_KEY=$S3_SECRET

ADMIN_PASSWORD=$ADMIN_PASSWORD

STRIPE_SECRET=$STRIPE_SECRET
STRIPE_WEBHOOK_SECRET=$STRIPE_WEBHOOK_SECRET
STRIPE_SUCCESS_URL=$URL_SHOP/checkout/success
STRIPE_CANCEL_URL=$URL_SHOP/checkout/cancel

RENDER_SERVICE_URL=$RENDER_URL

CORS_ORIGINS=$URL_SHOP,$SCHEME://$HOST_WWW,$URL_ADMIN

# L'API ne voit que nginx : on fait confiance a l'adresse qu'il transmet.
CLIENT_IP_SOURCE=RightmostXForwardedFor
EOF
chown root:"$SERVICE_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
ok "$ENV_FILE (0640 root:$SERVICE_USER)"
[[ -n "$STRIPE_SECRET" ]] || note "STRIPE_SECRET vide : le catalogue existant se sert, mais aucun cosmetique ne peut etre cree"

cat > /etc/systemd/system/endless-backend.service <<EOF
[Unit]
Description=EndlessClient Poly+ API
After=network-online.target postgresql.service minio.service
Wants=network-online.target
Requires=postgresql.service

[Service]
User=$SERVICE_USER
EnvironmentFile=$ENV_FILE
ExecStart=$BASE_DIR/bin/plus-backend serve
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable endless-backend >"$NULL"
systemctl restart endless-backend
# Les migrations tournent avant que la socket ne s'ouvre : attendre le port,
# c'est attendre la fin des migrations.
wait_for_port 8080 300 || die "l'API n'ecoute pas sur 8080 — voir: journalctl -u endless-backend -n 60"
ok "endless-backend actif, migrations appliquees"

# ─────────────────────────────────────────────────────────────────────────────
step "Boutique (plus-website)"
# ─────────────────────────────────────────────────────────────────────────────
# NEXT_PUBLIC_* est inline a la compilation : le fichier doit exister avant.
printf 'NEXT_PUBLIC_BACKEND_URL=%s\n' "$URL_API" > "$SHOP_SRC/.env.local"
chown "$SERVICE_USER:$SERVICE_USER" "$SHOP_SRC/.env.local"
js_install "$SHOP_SRC" "boutique"
as_service_user "cd '$SHOP_SRC' && npm run build"

# next.config.ts declare output: "standalone". Dans ce mode `next start` refuse
# de demarrer : Next attend qu'on lance .next/standalone/server.js. Et il n'y
# copie ni les assets statiques ni public/, c'est a l'integrateur de le faire.
if [[ -f "$SHOP_SRC/.next/standalone/server.js" ]]; then
  as_service_user "cd '$SHOP_SRC' && mkdir -p .next/standalone/.next && cp -r .next/static .next/standalone/.next/"
  if [[ -d "$SHOP_SRC/public" ]]; then
    as_service_user "cd '$SHOP_SRC' && cp -r public .next/standalone/"
  fi
  SHOP_WORKDIR="$SHOP_SRC/.next/standalone"
  SHOP_EXEC="/usr/bin/node server.js"
  ok "build standalone : assets statiques et public/ copies"
else
  SHOP_WORKDIR="$SHOP_SRC"
  SHOP_EXEC="/usr/bin/npm run start"
fi

cat > /etc/systemd/system/endless-shop.service <<EOF
[Unit]
Description=EndlessClient shop
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$SHOP_WORKDIR
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=127.0.0.1
ExecStart=$SHOP_EXEC
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$SHOP_SRC/.next

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable endless-shop >"$NULL"
systemctl restart endless-shop
wait_for_port 3000 180 || note "la boutique n'a pas ouvert le port 3000 — voir: journalctl -u endless-shop -n 60"
ok "endless-shop actif sur 127.0.0.1:3000, API pointee sur $URL_API"

# ─────────────────────────────────────────────────────────────────────────────
step "Dashboard admin (plus-admin-dashboard)"
# ─────────────────────────────────────────────────────────────────────────────
# Le selecteur de backend est compile en dur dans les sources et ne propose que
# 127.0.0.1 et plus.polyfrost.org : sans ce remplacement le dashboard deploye
# interroge le serveur de Polyfrost, pas le votre.
for f in "$DASH_SRC/src/lib/settings.ts" "$DASH_SRC/src/routes/index.tsx"; do
  if [[ -f "$f" ]] && grep -q 'plus\.polyfrost\.org' "$f"; then
    sed -i "s#https://plus\.polyfrost\.org#$URL_API#g" "$f"
    ok "backend reecrit vers $URL_API dans $(basename "$f")"
  fi
done

# Reecrire les options ne suffit pas : DEFAULT_ENV vaut ENV_OPTIONS[0].value,
# soit http://127.0.0.1:8080. Depuis un navigateur sur https://admin.<domaine>
# cette adresse designe la machine du visiteur, et un appel http:// depuis une
# page https est de toute facon bloque en contenu mixte. Resultat vu par
# l'utilisateur : "Network error: TypeError: Failed to fetch".
if [[ -f "$DASH_SRC/src/lib/settings.ts" ]] && grep -q '^export const DEFAULT_ENV' "$DASH_SRC/src/lib/settings.ts"; then
  sed -i "s#^export const DEFAULT_ENV = .*#export const DEFAULT_ENV = \"$URL_API\";#" \
    "$DASH_SRC/src/lib/settings.ts"
  ok "environnement par defaut du dashboard : $URL_API"
fi

js_install "$DASH_SRC" "dashboard"
as_service_user "cd '$DASH_SRC' && npm run build"
rm -rf "$BASE_DIR/web/admin"
cp -r "$DASH_SRC/dist" "$BASE_DIR/web/admin"
chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/web/admin"
chmod a+rX "$BASE_DIR"
chmod -R a+rX "$BASE_DIR/web"
ok "bundle statique deploye dans $BASE_DIR/web/admin"

# Le champ mot de passe du dashboard protege l'API, pas la page : on met aussi
# une authentification HTTP devant le site.
htpasswd -bc "$HTPASSWD_FILE" "$ADMIN_HTTP_USER" "$ADMIN_HTTP_PASSWORD" >"$NULL" 2>&1
chmod 640 "$HTPASSWD_FILE"
chown root:www-data "$HTPASSWD_FILE"
ok "authentification HTTP posee sur $HOST_ADMIN (utilisateur '$ADMIN_HTTP_USER')"

# ─────────────────────────────────────────────────────────────────────────────
step "nginx"
# ─────────────────────────────────────────────────────────────────────────────
cat > /etc/nginx/conf.d/upgrade-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default

# D'abord un vhost HTTP seul : certbot a besoin d'un serveur qui repond sur le
# port 80 avant que le moindre certificat n'existe, et une conf TLS referencant
# des certificats absents ferait echouer `nginx -t`.
cat > /etc/nginx/sites-available/endlessclient <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_HOSTS[*]};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
EOF
ln -sf /etc/nginx/sites-available/endlessclient /etc/nginx/sites-enabled/endlessclient
nginx -t >"$NULL" || die "configuration nginx invalide"
systemctl enable nginx >"$NULL"
systemctl restart nginx
ok "vhost HTTP temporaire en place"

CERT_DIR=""
if (( SKIP_TLS )); then
  note "TLS ignore (--skip-tls) : tout sera servi en clair"
else
  apt-get -y $APT_Q install certbot python3-certbot-nginx
  cert_args=()
  for host in "${ALL_HOSTS[@]}"; do cert_args+=(-d "$host"); done
  if certbot certonly --webroot -w /var/www/html "${cert_args[@]}" \
       --agree-tos -m "$LETSENCRYPT_EMAIL" --no-eff-email --non-interactive --keep-until-expiring; then
    CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
    [[ -d "$CERT_DIR" ]] || CERT_DIR="$(find /etc/letsencrypt/live -maxdepth 1 -type d -name "$DOMAIN*" | head -n1)"
    ok "certificat obtenu pour les 5 hotes"
  else
    note "certbot a echoue : bascule en HTTP seul"
    note "corrigez le DNS puis relancez ce script pour repasser en HTTPS"
    SKIP_TLS=1
    SCHEME="http"
    URL_SHOP="http://$HOST_SHOP"; URL_API="http://$HOST_API"
    URL_ADMIN="http://$HOST_ADMIN"; URL_CDN="http://$HOST_CDN"
  fi
fi

if (( SKIP_TLS )); then
  # HTTP seul : meme routage, sans TLS ni redirection.
  cat > /etc/nginx/sites-available/endlessclient <<'NGINX'
server {
    listen 80; listen [::]:80;
    server_name @@API@@;
    client_max_body_size 64m;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For   $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
server {
    listen 80; listen [::]:80;
    server_name @@SHOP@@;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
server {
    listen 80; listen [::]:80;
    server_name @@WWW@@;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 http://@@SHOP@@$request_uri; }
}
server {
    listen 80; listen [::]:80;
    server_name @@ADMIN@@;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        auth_basic           "EndlessClient admin";
        auth_basic_user_file @@HTPASSWD@@;
        root @@WEBROOT@@;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
server {
    listen 80; listen [::]:80;
    server_name @@CDN@@;
    client_max_body_size 64m;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
        proxy_buffering off;
    }
}
NGINX
else
  cat > /etc/nginx/sites-available/endlessclient <<'NGINX'
# ─── http -> https ────────────────────────────────────────────────────────
server {
    listen 80; listen [::]:80;
    server_name @@SHOP@@ @@WWW@@ @@API@@ @@ADMIN@@ @@CDN@@;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

# ─── API ──────────────────────────────────────────────────────────────────
server {
    @@LISTEN443@@
@@HTTP2@@
    server_name @@API@@;

    ssl_certificate     @@CERTDIR@@/fullchain.pem;
    ssl_certificate_key @@CERTDIR@@/privkey.pem;

    # Les bundles de cosmetiques sont televerses par ici
    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Ecraser plutot qu'ajouter : CLIENT_IP_SOURCE fait confiance a la
        # valeur la plus a droite, un en-tete fourni par le client ne doit
        # donc pas survivre.
        proxy_set_header X-Forwarded-For   $remote_addr;

        # /websocket porte les mises a jour d'equipement et le temps de jeu
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}

# ─── boutique ─────────────────────────────────────────────────────────────
server {
    @@LISTEN443@@
@@HTTP2@@
    server_name @@SHOP@@;

    ssl_certificate     @@CERTDIR@@/fullchain.pem;
    ssl_certificate_key @@CERTDIR@@/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    @@LISTEN443@@
@@HTTP2@@
    server_name @@WWW@@;
    ssl_certificate     @@CERTDIR@@/fullchain.pem;
    ssl_certificate_key @@CERTDIR@@/privkey.pem;
    return 301 https://@@SHOP@@$request_uri;
}

# ─── dashboard admin ──────────────────────────────────────────────────────
server {
    @@LISTEN443@@
@@HTTP2@@
    server_name @@ADMIN@@;

    ssl_certificate     @@CERTDIR@@/fullchain.pem;
    ssl_certificate_key @@CERTDIR@@/privkey.pem;

    auth_basic           "EndlessClient admin";
    auth_basic_user_file @@HTPASSWD@@;

    root @@WEBROOT@@;
    index index.html;
    location / { try_files $uri $uri/ /index.html; }
}

# ─── stockage objet ───────────────────────────────────────────────────────
server {
    @@LISTEN443@@
@@HTTP2@@
    server_name @@CDN@@;

    ssl_certificate     @@CERTDIR@@/fullchain.pem;
    ssl_certificate_key @@CERTDIR@@/privkey.pem;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Les signatures couvrent la requete telle qu'envoyee : toute
        # reecriture liee au buffering les casse.
        proxy_request_buffering off;
        proxy_buffering off;
    }
}
NGINX
fi

# La directive `http2 on;` n'existe qu'a partir de nginx 1.25.1. Debian 12
# livre 1.22.1, ou elle fait echouer `nginx -t` avec "unknown directive". Sur
# ces versions HTTP/2 s'active par un parametre de `listen`. On choisit donc la
# syntaxe selon la version reellement installee.
NGINX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
if [[ -n "$NGINX_VER" ]] && \
   [[ "$(printf '%s\n%s\n' '1.25.1' "$NGINX_VER" | sort -V | head -n1)" == "1.25.1" ]]; then
  LISTEN443='listen 443 ssl; listen [::]:443 ssl;'
  HTTP2_LINE='    http2 on;'
  ok "nginx $NGINX_VER : syntaxe http2 moderne"
else
  LISTEN443='listen 443 ssl http2; listen [::]:443 ssl http2;'
  HTTP2_LINE=''
  ok "nginx ${NGINX_VER:-inconnu} : http2 active via listen (< 1.25.1)"
fi

sed -i \
  -e "s#@@LISTEN443@@#$LISTEN443#g" -e "s#^@@HTTP2@@\$#$HTTP2_LINE#g" \
  -e "s#@@SHOP@@#$HOST_SHOP#g"  -e "s#@@WWW@@#$HOST_WWW#g" \
  -e "s#@@API@@#$HOST_API#g"    -e "s#@@ADMIN@@#$HOST_ADMIN#g" \
  -e "s#@@CDN@@#$HOST_CDN#g"    -e "s#@@CERTDIR@@#$CERT_DIR#g" \
  -e "s#@@HTPASSWD@@#$HTPASSWD_FILE#g" -e "s#@@WEBROOT@@#$BASE_DIR/web/admin#g" \
  /etc/nginx/sites-available/endlessclient

# Montrer ce que nginx reproche : sans ca on meurt sur "configuration invalide"
# sans savoir quelle directive, ni a quelle ligne.
if ! nginx -t >"$NULL" 2>&1; then
  nginx -t 2>&1 | sed 's/^/         /' >&2 || true
  die "configuration nginx invalide (detail ci-dessus)"
fi
systemctl reload nginx
ok "nginx sert les 5 hotes"
if (( ! SKIP_TLS )) && systemctl list-timers 2>"$NULL" | grep -q certbot; then
  ok "renouvellement automatique du certificat actif"
fi

# Le backend a ete configure avant que certbot ne puisse echouer : si on est
# retombe en HTTP, l'endpoint S3 et les origines CORS enregistres sont faux.
if (( SKIP_TLS )) && grep -q '^S3_BUCKET_ENDPOINT=https://' "$ENV_FILE"; then
  sed -i \
    -e "s#^S3_BUCKET_ENDPOINT=.*#S3_BUCKET_ENDPOINT=$URL_CDN#" \
    -e "s#^STRIPE_SUCCESS_URL=.*#STRIPE_SUCCESS_URL=$URL_SHOP/checkout/success#" \
    -e "s#^STRIPE_CANCEL_URL=.*#STRIPE_CANCEL_URL=$URL_SHOP/checkout/cancel#" \
    -e "s#^CORS_ORIGINS=.*#CORS_ORIGINS=$URL_SHOP,http://$HOST_WWW,$URL_ADMIN#" \
    "$ENV_FILE"
  systemctl restart endless-backend
  wait_for_port 8080 120 || note "l'API n'est pas repartie apres la bascule HTTP"
  # NEXT_PUBLIC_* est fige a la compilation : la boutique doit etre rebatie.
  printf 'NEXT_PUBLIC_BACKEND_URL=%s\n' "$URL_API" > "$SHOP_SRC/.env.local"
  chown "$SERVICE_USER:$SERVICE_USER" "$SHOP_SRC/.env.local"
  if as_service_user "cd '$SHOP_SRC' && npm run build"; then
    systemctl restart endless-shop
  else
    note "reconstruction de la boutique echouee ; elle pointe encore sur https://"
  fi
  ok "configuration realignee sur HTTP"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Catalogue de demonstration"
# ─────────────────────────────────────────────────────────────────────────────
if (( ! SEED_DEMO )); then
  note "ignore (utilisez --seed-demo ; attention : TRUNCATE des tables cosmetiques)"
elif [[ ! -f "$SRC_ROOT/startlocal/seed.sql" ]]; then
  note "startlocal/seed.sql introuvable ; ignore"
else
  sudo -u postgres psql -d "$DB_NAME" -q -v ON_ERROR_STOP=1 -f "$SRC_ROOT/startlocal/seed.sql"
  ok "catalogue de demonstration charge (5 capes, 1 emote, 1 bundle)"
  note "les textures ne sont pas dans le bucket : ces cosmetiques 404 tant qu'ils ne sont pas re-televerses"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Premier administrateur"
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "$ADMIN_UUID" && -n "$ADMIN_NAME" ]]; then
  raw="$(curl -fsS "https://api.mojang.com/users/profiles/minecraft/$ADMIN_NAME" 2>"$NULL" | jq -r '.id // empty')"
  if [[ -n "$raw" ]]; then
    ADMIN_UUID="$(dash_uuid "$raw")"
  else
    note "pseudo '$ADMIN_NAME' non resolu par l'API Mojang"
  fi
fi

if [[ -n "$ADMIN_UUID" ]]; then
  sudo -u postgres psql -d "$DB_NAME" -q <<SQL
INSERT INTO "user" (minecraft_uuid, role)
VALUES ('$ADMIN_UUID', 'admin')
ON CONFLICT (minecraft_uuid) DO UPDATE SET role = 'admin';
SQL
  ok "$ADMIN_UUID promu administrateur"
else
  note "aucun administrateur defini (--admin-uuid ou --admin-name)"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "PolyPlus"
# ─────────────────────────────────────────────────────────────────────────────
if (( ! PATCH_POLYPLUS )); then
  note "BackendUrl.kt non modifie (--patch-polyplus pour le faire)"
else
  mapfile -t kt_files < <(find "$SRC_ROOT/PolyPlus" -name BackendUrl.kt 2>"$NULL" || true)
  if (( ${#kt_files[@]} == 0 )); then
    note "BackendUrl.kt introuvable ; PolyPlus n'est peut-etre pas dans ce depot"
  else
    for f in "${kt_files[@]}"; do
      sed -i "s#PRODUCTION(\"[^\"]*\")#PRODUCTION(\"$URL_API\")#" "$f"
      ok "$(realpath --relative-to="$SRC_ROOT" "$f") pointe sur $URL_API"
    done
    note "le mod doit ensuite etre recompile ; voir DEPLOYMENT.md §21 : PolyPlus ne"
    note "compile pas contre le OneConfig de ce depot (1.1.4 attendu vs 1.1.7-dev)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Sauvegardes et journaux"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /var/backups/endless
cat > /usr/local/bin/endless-backup <<'BACKUP'
#!/usr/bin/env bash
# Base ET bucket ensemble : les lignes cosmetiques referencent des cles objet,
# restaurer l'un sans l'autre laisse des cosmetiques dont les assets 404.
set -euo pipefail
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="/var/backups/endless"
sudo -u postgres pg_dump -Fc @@DB@@ > "$dest/@@DB@@-$stamp.dump"
mc mirror --overwrite --remove "endless/@@BUCKET@@" "$dest/bucket"
find "$dest" -name '@@DB@@-*.dump' -mtime +14 -delete
BACKUP
sed -i -e "s#@@DB@@#$DB_NAME#g" -e "s#@@BUCKET@@#$BUCKET#g" /usr/local/bin/endless-backup
chmod 0755 /usr/local/bin/endless-backup

cat > /etc/systemd/system/endless-backup.service <<'EOF'
[Unit]
Description=EndlessClient backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/endless-backup
EOF

cat > /etc/systemd/system/endless-backup.timer <<'EOF'
[Unit]
Description=Nightly EndlessClient backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now endless-backup.timer >"$NULL"
ok "sauvegarde quotidienne active (/var/backups/endless)"
note "une sauvegarde sur le meme disque n'est pas une sauvegarde : copiez-la ailleurs"

sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=2G/' /etc/systemd/journald.conf
systemctl restart systemd-journald
ok "journal systeme plafonne a 2G"

# ─────────────────────────────────────────────────────────────────────────────
step "Verification"
# ─────────────────────────────────────────────────────────────────────────────
CHECKS_OK=1
for unit in postgresql minio endless-backend endless-shop nginx; do
  if systemctl is-active --quiet "$unit"; then ok "$unit actif"; else note "$unit INACTIF"; CHECKS_OK=0; fi
done
if (( RENDER_ENABLED )); then
  systemctl is-active --quiet endless-render && ok "endless-render actif" || note "endless-render INACTIF"
fi

paths="$(curl -fsS --max-time 15 "$URL_API/openapi.json" 2>"$NULL" | jq '.paths | keys | length' 2>"$NULL" || true)"
if [[ -n "$paths" ]]; then ok "$URL_API/openapi.json repond, $paths routes"
else note "$URL_API/openapi.json injoignable"; CHECKS_OK=0; fi

count="$(curl -fsS --max-time 15 "$URL_API/cosmetics" 2>"$NULL" | jq '.cosmetics | length' 2>"$NULL" || true)"
[[ -n "$count" ]] && ok "$URL_API/cosmetics repond, $count cosmetique(s)" || true

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL_SHOP/" 2>"$NULL" || true)"
[[ "$code" == "200" ]] && ok "boutique $URL_SHOP -> 200" || note "boutique $URL_SHOP -> ${code:-injoignable}"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -u "$ADMIN_HTTP_USER:$ADMIN_HTTP_PASSWORD" "$URL_ADMIN/" 2>"$NULL" || true)"
[[ "$code" == "200" ]] && ok "dashboard $URL_ADMIN -> 200 (avec auth HTTP)" || note "dashboard $URL_ADMIN -> ${code:-injoignable}"

# 101 ou 426, jamais 200 : un 200 signifie que nginx n'a pas relaye l'upgrade.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$URL_API/websocket" 2>"$NULL" || true)"
if [[ "$code" == "101" || "$code" == "426" ]]; then ok "websocket -> $code"
else note "websocket -> ${code:-injoignable} (attendu 101 ou 426)"; fi

# ─────────────────────────────────────────────────────────────────────────────
step "Fichier d'identifiants"
# ─────────────────────────────────────────────────────────────────────────────
umask 077
cat > "$CRED_FILE" <<EOF
================================================================================
 EndlessClient — identifiants generes
 Serveur   : $(hostname -f 2>"$NULL" || hostname)
 Domaine   : $DOMAIN
 Genere le : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
================================================================================

 !! CONFIDENTIEL !! Ce fichier contient tous les secrets du deploiement.
    Copiez-le dans votre gestionnaire de mots de passe, puis supprimez-le
    d'ici ou gardez-le en 0600. Ne le mettez JAMAIS dans une archive livree
    ni dans un depot git.

--------------------------------------------------------------------------------
 ADRESSES
--------------------------------------------------------------------------------
 Boutique              $URL_SHOP
 API                   $URL_API
 Documentation API     $URL_API/scalar
 Dashboard admin       $URL_ADMIN
 Assets (CDN)          $URL_CDN

--------------------------------------------------------------------------------
 DASHBOARD ADMIN — deux barrieres distinctes
--------------------------------------------------------------------------------
 1) Authentification HTTP (protege la page)
    Utilisateur        $ADMIN_HTTP_USER
    Mot de passe       $ADMIN_HTTP_PASSWORD

 2) Mot de passe API (protege /cosmetics/manage/*, a saisir dans le dashboard)
    Mot de passe       $ADMIN_PASSWORD

    Envoye tel quel dans l'en-tete Authorization, sans prefixe "Bearer".
    Comparaison de chaine brute, sans limitation de debit ni verrouillage.

--------------------------------------------------------------------------------
 BASE DE DONNEES (PostgreSQL, 127.0.0.1:5432)
--------------------------------------------------------------------------------
 Base                  $DB_NAME
 Utilisateur           $DB_USER
 Mot de passe          $DB_PASSWORD
 URL                   postgresql://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME

--------------------------------------------------------------------------------
 STOCKAGE OBJET (MinIO, 127.0.0.1:9000 — console 127.0.0.1:9001)
--------------------------------------------------------------------------------
 Bucket                $BUCKET
 Racine  utilisateur   $MINIO_ROOT_USER
 Racine  mot de passe  $MINIO_ROOT_PASSWORD
 API     cle           $S3_USER
 API     secret        $S3_SECRET
 Endpoint public       $URL_CDN

 La console MinIO n'est pas exposee. Pour y acceder :
   ssh -L 9001:127.0.0.1:9001 <vous>@$DOMAIN   puis http://127.0.0.1:9001

--------------------------------------------------------------------------------
 STRIPE
--------------------------------------------------------------------------------
 Cle secrete           ${STRIPE_SECRET:-<vide, a renseigner>}
 Secret du webhook     ${STRIPE_WEBHOOK_SECRET:-<vide, a renseigner>}
 URL du webhook        $URL_API/stripe/webhook
 Evenements a abonner  checkout.session.completed
                       checkout.session.async_payment_succeeded
                       charge.refunded

 Sans cle valide le catalogue existant se sert, mais aucun cosmetique ne peut
 etre cree : un televersement provisionne un produit et un prix chez Stripe.
 Un secret de webhook errone echoue de la pire facon : les paiements passent
 et les cosmetiques ne sont jamais attribues.

--------------------------------------------------------------------------------
 ADMINISTRATEUR MINECRAFT
--------------------------------------------------------------------------------
 UUID                  ${ADMIN_UUID:-<aucun, voir la commande ci-dessous>}

 En ajouter un :
   sudo -u postgres psql -d $DB_NAME \\
     -c "INSERT INTO \"user\" (minecraft_uuid, role) VALUES ('UUID-AVEC-TIRETS','admin') ON CONFLICT (minecraft_uuid) DO UPDATE SET role='admin';"

--------------------------------------------------------------------------------
 EXPLOITATION
--------------------------------------------------------------------------------
 Etat        systemctl status endless-backend endless-shop endless-render minio
 Journaux    journalctl -u endless-backend -f
 Redemarrer  systemctl restart endless-backend
 Config API  $ENV_FILE   (0640 root:$SERVICE_USER)
 nginx       /etc/nginx/sites-available/endlessclient
 Sauvegarde  /usr/local/bin/endless-backup  ->  /var/backups/endless
 Mise a jour $BASE_DIR/src, puis voir DEPLOYMENT.md section 16

--------------------------------------------------------------------------------
 A FAIRE
--------------------------------------------------------------------------------
 [ ] Copier ce fichier hors du serveur, puis le supprimer d'ici
 [ ] Renseigner les cles Stripe et declarer le webhook
 [ ] Copier /var/backups/endless sur une autre machine
 [ ] Repeter une restauration au moins une fois
 [ ] certbot renew --dry-run
================================================================================
EOF
chmod 600 "$CRED_FILE"
chown root:root "$CRED_FILE"
ok "$CRED_FILE (0600 root:root)"

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s  Installation terminee%s\n\n' "$C_STEP" "$C_RESET"
printf '  Boutique          %s\n' "$URL_SHOP"
printf '  API               %s\n' "$URL_API"
printf '  Dashboard admin   %s\n' "$URL_ADMIN"
printf '  Assets            %s\n' "$URL_CDN"
printf '\n  Identifiants      %s\n' "$CRED_FILE"
printf '  Les lire          sudo cat %s\n' "$CRED_FILE"
printf '  Les recuperer     scp root@%s:%s .\n\n' "$DOMAIN" "$CRED_FILE"
if (( DEBUG )); then
  printf '  Trace debug       %s\n' "$DEBUG_LOG"
  printf '%s  Elle contient les mots de passe en clair : supprimez-la apres usage.%s\n\n' "$C_WARN" "$C_RESET"
fi
(( CHECKS_OK )) || printf '%s  Des verifications ont echoue — relisez la section Verification ci-dessus.%s\n\n' "$C_WARN" "$C_RESET"
(( SKIP_TLS )) && printf '%s  Servi en HTTP : relancez sans --skip-tls une fois le DNS propage.%s\n\n' "$C_WARN" "$C_RESET" || true
exit 0
