#!/usr/bin/env bash
#
# EndlessClient — mise a jour du deploiement, en une commande.
#
#   sudo ./update.sh              # tout : sauvegarde, sources, backend, boutique, dashboard
#   sudo ./update.sh --only shop  # un seul composant
#   sudo ./update.sh --help
#
# Complement de install.sh : celui-ci installe, celui-la met a jour. Il ne
# touche ni aux secrets, ni au schema, ni a nginx, ni aux certificats.
#
# -E : le piege ERR doit se declencher aussi dans les fonctions et sous-shells.
set -Eeuo pipefail

SERVICE_USER="endless"
BASE_DIR="/opt/endless"
DB_NAME="endless_plus"
BACKUP_DIR="/var/backups/endless"
LOG_FILE="/var/log/endless-update.log"
DEBUG_LOG="/var/log/endless-update.debug.log"

ONLY=""
SKIP_BACKUP=0
SKIP_PULL=0
DEBUG=0

NULL="/dev/null"
NPM_FLAGS="--no-audit --no-fund"
CARGO_FLAGS=""

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

on_error() {
  local code=$?
  local line="$1" cmd="$2"
  printf '\n%s     ERREUR ligne %s (code %s)%s\n' "$C_ERR" "$line" "$code" "$C_RESET" >&2
  printf '%s       commande : %s%s\n' "$C_ERR" "$cmd" "$C_RESET" >&2
  if (( DEBUG )); then
    local i
    printf '%s       pile d appel :%s\n' "$C_ERR" "$C_RESET" >&2
    for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
      printf '         %s() <- %s:%s\n' \
        "${FUNCNAME[i]}" "${BASH_SOURCE[i]##*/}" "${BASH_LINENO[i-1]}" >&2
    done
    printf '\n       trace complete : %s\n' "$DEBUG_LOG" >&2
  else
    printf '\n       relancez avec --debug pour la trace de chaque commande\n' >&2
  fi
  if [[ -s "$LOG_FILE" ]]; then
    printf '\n       dernieres lignes du journal (la vraie erreur est ici) :\n' >&2
    tail -n 30 "$LOG_FILE" 2>/dev/null | sed 's/^/         /' >&2 || true
  fi
  printf '\n       les composants deja mis a jour tournent toujours.\n' >&2
  printf '       journal : %s\n\n' "$LOG_FILE" >&2
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<'USAGE'
EndlessClient — mise a jour

  sudo ./update.sh [options]

Options
  --only <composant>   backend | shop | dashboard | render  (defaut: tout)
  --no-backup          Ne pas sauvegarder la base avant (deconseille)
  --no-pull            Ne pas faire de git pull, recompiler ce qui est en place
  --debug              Trace complete dans /var/log/endless-update.debug.log
  -h, --help           Cette aide

Exemples
  sudo ./update.sh                     # tout
  sudo ./update.sh --only backend      # apres un changement cote API
  sudo ./update.sh --no-pull --only shop
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)      ONLY="${2:?}"; shift 2 ;;
    --no-backup) SKIP_BACKUP=1; shift ;;
    --no-pull)   SKIP_PULL=1; shift ;;
    --debug)     DEBUG=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "option inconnue : $1" ;;
  esac
done

case "$ONLY" in
  ""|backend|shop|dashboard|render) : ;;
  *) die "--only accepte : backend, shop, dashboard, render" ;;
esac

wanted() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

as_service_user() {
  sudo -u "$SERVICE_USER" bash -lc \
    "export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'; $1"
}

wait_for_port() {
  local port="$1" timeout="${2:-60}" waited=0
  while (( waited < timeout )); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>"$NULL"; then exec 3>&- 2>"$NULL" || true; return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# `npm ci` exige un lockfile, que plus-website et plus-admin-dashboard ne
# versionnent pas. On retombe sur `npm install` dans ce cas.
js_install() {
  local dir="$1" label="$2"
  if [[ -f "$dir/package-lock.json" ]]; then
    as_service_user "cd '$dir' && npm ci $NPM_FLAGS"
  else
    note "$label : pas de package-lock.json, npm install"
    as_service_user "cd '$dir' && npm install $NPM_FLAGS"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "a lancer en root : sudo ./update.sh [options]"
[[ -d "$BASE_DIR" ]] || die "$BASE_DIR introuvable — lancez d'abord install.sh"

SRC_ROOT="$BASE_DIR/src"
BACKEND_SRC="$SRC_ROOT/plus-backend-main"
SHOP_SRC="$SRC_ROOT/plus-website"
DASH_SRC="$SRC_ROOT/plus-admin-dashboard"
RENDER_SRC="$BACKEND_SRC/render-service"
ENV_FILE="$BASE_DIR/secrets/backend.env"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

if (( DEBUG )); then
  NULL="/dev/stderr"
  NPM_FLAGS="--no-audit --no-fund --loglevel verbose"
  CARGO_FLAGS="--verbose"
  : > "$DEBUG_LOG"; chmod 600 "$DEBUG_LOG"
  exec 9>>"$DEBUG_LOG"
  export BASH_XTRACEFD=9
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}(): '
  set -x
fi

# L'URL publique de l'API est deja sur disque : la boutique la porte dans son
# .env.local, ecrit par install.sh. Plus fiable que de la redemander.
URL_API=""
if [[ -f "$SHOP_SRC/.env.local" ]]; then
  URL_API="$(sed -n 's/^NEXT_PUBLIC_BACKEND_URL=//p' "$SHOP_SRC/.env.local" | head -n1)"
fi
if [[ -z "$URL_API" && -f "$ENV_FILE" ]]; then
  # Repli : deduire du endpoint S3, qui vaut https://cdn.<domaine>
  URL_API="$(sed -n 's|^S3_BUCKET_ENDPOINT=\(https\?\)://cdn\.|\1://api.|p' "$ENV_FILE" | head -n1)"
fi

printf '\n%s  EndlessClient — mise a jour%s\n' "$C_STEP" "$C_RESET"
printf '  sources   %s\n' "$SRC_ROOT"
printf '  API       %s\n' "${URL_API:-inconnue}"
printf '  portee    %s\n' "${ONLY:-tout}"
printf '  journal   %s\n' "$LOG_FILE"
(( DEBUG )) && printf '  debug     %s (contient des secrets)\n' "$DEBUG_LOG" || true

# ─────────────────────────────────────────────────────────────────────────────
step "Sauvegarde de la base"
# ─────────────────────────────────────────────────────────────────────────────
# Les migrations s'appliquent au demarrage du backend et ne sont pas reversibles
# en place : sans dump prealable, un retour arriere est impossible.
if (( SKIP_BACKUP )); then
  note "ignoree (--no-backup) : aucun retour arriere possible si une migration echoue"
else
  mkdir -p "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dump="$BACKUP_DIR/${DB_NAME}-pre-update-$stamp.dump"
  sudo -u postgres pg_dump -Fc "$DB_NAME" > "$dump"
  ok "$dump ($(du -h "$dump" | cut -f1))"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Sources"
# ─────────────────────────────────────────────────────────────────────────────
if (( SKIP_PULL )); then
  note "git pull ignore (--no-pull)"
elif [[ -d "$SRC_ROOT/.git" ]]; then
  before="$(as_service_user "cd '$SRC_ROOT' && git rev-parse --short HEAD")"
  as_service_user "cd '$SRC_ROOT' && git pull --ff-only" || note "git pull a echoue, on garde ce qui est en place"
  after="$(as_service_user "cd '$SRC_ROOT' && git rev-parse --short HEAD")"
  if [[ "$before" == "$after" ]]; then ok "deja a jour ($after)"; else ok "$before -> $after"; fi
else
  note "$SRC_ROOT n'est pas un depot git ; rien a tirer"
fi

# plus-website et plus-admin-dashboard sont des gitlinks sans .gitmodules : un
# git pull ne les met jamais a jour. Le dire, plutot que de laisser croire que
# la boutique a suivi.
for d in "$SHOP_SRC" "$DASH_SRC"; do
  if [[ ! -d "$d" || -z "$(ls -A "$d" 2>/dev/null)" ]]; then
    die "$(basename "$d") est absent ou vide — a transferer sur le serveur (sous-module sans .gitmodules)"
  fi
done
note "plus-website et plus-admin-dashboard ne suivent pas le git pull (sous-modules)"
note "leur mise a jour passe par un transfert manuel de vos sources"

# ─────────────────────────────────────────────────────────────────────────────
if wanted backend; then
step "Backend"
# ─────────────────────────────────────────────────────────────────────────────
  as_service_user "source \$HOME/.cargo/env && cd '$BACKEND_SRC' && cargo build --release $CARGO_FLAGS"
  new_bin="$(find "$BACKEND_SRC/target/release" -maxdepth 1 -type f -name 'plus-backend*' ! -name '*.d' | head -n1)"
  [[ -n "$new_bin" ]] || die "binaire plus-backend introuvable apres compilation"

  # Arreter avant de remplacer : deux instances sur la meme base pendant qu'une
  # migration tourne est la facon la plus sure de la corrompre.
  systemctl stop endless-backend
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$new_bin" "$BASE_DIR/bin/plus-backend"
  systemctl start endless-backend

  if wait_for_port 8080 300; then
    ok "endless-backend redemarre, migrations appliquees"
  else
    die "l'API n'ecoute pas sur 8080 — voir: journalctl -u endless-backend -n 60"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
if wanted render && [[ -d "$RENDER_SRC" ]]; then
step "Service de rendu"
# ─────────────────────────────────────────────────────────────────────────────
  if systemctl list-unit-files 2>"$NULL" | grep -q '^endless-render'; then
    as_service_user "cd '$RENDER_SRC' && PUPPETEER_SKIP_DOWNLOAD=true npm install $NPM_FLAGS"
    systemctl restart endless-render
    if wait_for_port 8090 150; then
      ok "endless-render redemarre"
    else
      note "endless-render n'a pas repris — voir: journalctl -u endless-render -n 50"
    fi
  else
    note "endless-render n'est pas installe ; ignore"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
if wanted shop; then
step "Boutique (plus-website)"
# ─────────────────────────────────────────────────────────────────────────────
  # NEXT_PUBLIC_* est fige a la compilation : le fichier doit exister avant.
  if [[ -n "$URL_API" ]]; then
    printf 'NEXT_PUBLIC_BACKEND_URL=%s\n' "$URL_API" > "$SHOP_SRC/.env.local"
    chown "$SERVICE_USER:$SERVICE_USER" "$SHOP_SRC/.env.local"
  fi

  js_install "$SHOP_SRC" "boutique"
  as_service_user "cd '$SHOP_SRC' && npm run build"

  # output: "standalone" dans next.config.ts : Next n'y copie ni les assets
  # statiques ni public/, et `next start` refuse de demarrer dans ce mode.
  if [[ -f "$SHOP_SRC/.next/standalone/server.js" ]]; then
    as_service_user "cd '$SHOP_SRC' && mkdir -p .next/standalone/.next && cp -r .next/static .next/standalone/.next/"
    if [[ -d "$SHOP_SRC/public" ]]; then
      as_service_user "cd '$SHOP_SRC' && cp -r public .next/standalone/"
    fi
    ok "build standalone : assets statiques et public/ copies"
  fi

  systemctl restart endless-shop
  if wait_for_port 3000 180; then
    ok "endless-shop redemarre, API pointee sur ${URL_API:-?}"
  else
    die "la boutique n'ecoute pas sur 3000 — voir: journalctl -u endless-shop -n 60"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
if wanted dashboard; then
step "Dashboard admin"
# ─────────────────────────────────────────────────────────────────────────────
  # Ces reecritures sont a refaire a chaque mise a jour : le selecteur de
  # backend est compile en dur, et DEFAULT_ENV vaut http://127.0.0.1:8080, ce
  # qui donne "TypeError: Failed to fetch" depuis un navigateur distant.
  if [[ -n "$URL_API" ]]; then
    for f in "$DASH_SRC/src/lib/settings.ts" "$DASH_SRC/src/routes/index.tsx"; do
      if [[ -f "$f" ]] && grep -q 'plus\.polyfrost\.org' "$f"; then
        sed -i "s#https://plus\.polyfrost\.org#$URL_API#g" "$f"
        ok "backend reecrit dans $(basename "$f")"
      fi
    done
    if [[ -f "$DASH_SRC/src/lib/settings.ts" ]] && grep -q '^export const DEFAULT_ENV' "$DASH_SRC/src/lib/settings.ts"; then
      sed -i "s#^export const DEFAULT_ENV = .*#export const DEFAULT_ENV = \"$URL_API\";#" \
        "$DASH_SRC/src/lib/settings.ts"
      ok "environnement par defaut : $URL_API"
    fi
  else
    note "URL de l'API inconnue : reecritures du dashboard sautees"
  fi

  js_install "$DASH_SRC" "dashboard"
  as_service_user "cd '$DASH_SRC' && npm run build"

  # Ne remplacer le bundle en place qu'une fois le nouveau produit : un build
  # rate ne doit pas laisser admin.<domaine> sur un repertoire vide.
  [[ -d "$DASH_SRC/dist" ]] || die "aucun dist/ produit par le build du dashboard"
  rm -rf "$BASE_DIR/web/admin.old"
  if [[ -d "$BASE_DIR/web/admin" ]]; then mv "$BASE_DIR/web/admin" "$BASE_DIR/web/admin.old"; fi
  cp -r "$DASH_SRC/dist" "$BASE_DIR/web/admin"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/web/admin"
  chmod -R a+rX "$BASE_DIR/web/admin"
  rm -rf "$BASE_DIR/web/admin.old"
  ok "bundle statique redeploye"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "nginx"
# ─────────────────────────────────────────────────────────────────────────────
if nginx -t >"$NULL" 2>&1; then
  systemctl reload nginx
  ok "configuration valide, nginx recharge"
else
  nginx -t 2>&1 | sed 's/^/         /' >&2 || true
  note "configuration nginx invalide : NON rechargee, l'ancienne reste active"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Verification"
# ─────────────────────────────────────────────────────────────────────────────
CHECKS_OK=1
for unit in postgresql minio endless-backend endless-shop nginx; do
  if systemctl is-active --quiet "$unit"; then ok "$unit actif"; else note "$unit INACTIF"; CHECKS_OK=0; fi
done
systemctl is-active --quiet endless-render && ok "endless-render actif" || true

if [[ -n "$URL_API" ]]; then
  paths="$(curl -fsS --max-time 15 "$URL_API/openapi.json" 2>"$NULL" | jq '.paths | keys | length' 2>"$NULL" || true)"
  if [[ -n "$paths" ]]; then
    ok "$URL_API/openapi.json repond, $paths routes"
  else
    note "$URL_API/openapi.json injoignable"; CHECKS_OK=0
  fi

  count="$(curl -fsS --max-time 15 "$URL_API/cosmetics" 2>"$NULL" | jq '.cosmetics | length' 2>"$NULL" || true)"
  [[ -n "$count" ]] && ok "$URL_API/cosmetics repond, $count cosmetique(s)" || true
fi

printf '\n%s  Mise a jour terminee%s\n\n' "$C_STEP" "$C_RESET"
if (( SKIP_BACKUP )); then
  printf '  Sauvegarde        ignoree (--no-backup)\n'
else
  printf '  Sauvegarde        %s\n' "$BACKUP_DIR"
fi
printf '  Journal           %s\n' "$LOG_FILE"
printf '  Etat              systemctl status endless-backend endless-shop\n'
printf '  Retour arriere    voir DEPLOYMENT.md section 17 (Restore)\n\n'
(( CHECKS_OK )) || printf '%s  Des verifications ont echoue — relisez ci-dessus.%s\n\n' "$C_WARN" "$C_RESET"
exit 0
