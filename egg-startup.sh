# Source of the "Startup" command in egg-laravel.json.
#
# The panel cannot store a multi-line startup command, so this file is joined into one line by
# scripts/build-egg-startup.sh. Rules for editing it:
#   - every statement ends with ";" (or is a "then"/"do"/"else"/"{" opener), because lines are
#     joined with a single space;
#   - lines starting with "#" are dropped, so comments go on their own line only;
#   - never write two opening curly braces in a row: the entrypoint turns them into "${";
#   - refer to egg variables as shell variables ($ACCESS_TOKEN), NOT with the panel placeholder
#     syntax. The panel would replace the placeholder with the real value before the
#     entrypoint prints the startup command, which put tokens into the console log.
#
# Repository access (GIT_AUTH):
#   auto        token if ACCESS_TOKEN is set, else deploy key if one exists, else anonymous
#   token       HTTPS with USERNAME/ACCESS_TOKEN, sent as a header - never stored in .git/config
#   deploy_key  SSH with /home/container/.ssh/deploy_key; generated on first start, the public
#               key is printed so it can be added as a read-only deploy key
#   none        anonymous HTTPS (public repositories)
cd /home/container || exit 1;
KEY=/home/container/.ssh/deploy_key;
BR="${BRANCH:-main}";
MODE="${GIT_AUTH:-auto}";
if [[ "$GITHUB_REPO_URL" =~ ^git@([^:]+):(.+)$ ]]; then
  GHOST="${BASH_REMATCH[1]}"; GPATH="${BASH_REMATCH[2]}";
elif [[ "$GITHUB_REPO_URL" =~ ^https?://([^@/]+@)?([^/]+)/(.+)$ ]]; then
  GHOST="${BASH_REMATCH[2]}"; GPATH="${BASH_REMATCH[3]}";
else
  echo -e "[ERROR] GITHUB_REPO_URL must look like https://host/owner/repo or git@host:owner/repo"; exit 1;
fi;
GPATH="${GPATH%/}"; GPATH="${GPATH%.git}";
if [ "$MODE" = "auto" ]; then
  if [ -n "$ACCESS_TOKEN" ]; then MODE=token; elif [ -f "$KEY" ]; then MODE=deploy_key; else MODE=none; fi;
fi;
case "$MODE" in token|deploy_key|none) ;; *) echo -e "[ERROR] GIT_AUTH must be auto, token, deploy_key or none"; exit 1;; esac;
if [ "$MODE" = "deploy_key" ]; then
  REMOTE="git@$GHOST:$GPATH.git";
  mkdir -p /home/container/.ssh && chmod 700 /home/container/.ssh;
  if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "pelican-${P_SERVER_UUID:-$HOSTNAME}" -f "$KEY" || { echo -e "[ERROR] ssh-keygen failed"; exit 1; };
    echo -e "[SETUP] New deploy key generated. Add this public key as a READ-ONLY deploy key to $GHOST/$GPATH, then restart:";
    cat "$KEY.pub";
  fi;
  if [ "$GHOST" = "github.com" ]; then
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > /home/container/.ssh/known_hosts; HKC=yes;
  else
    HKC=accept-new;
  fi;
  export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=/home/container/.ssh/known_hosts -o StrictHostKeyChecking=$HKC";
else
  REMOTE="https://$GHOST/$GPATH.git";
fi;
if [ "$MODE" = "token" ]; then
  GIT_B64=$(printf '%s:%s' "${USERNAME:-x-access-token}" "$ACCESS_TOKEN" | base64 | tr -d '\n');
fi;
g() { if [ "$MODE" = "token" ]; then git -c "http.extraHeader=Authorization: Basic $GIT_B64" "$@"; else git "$@"; fi; };
if [ -d .git ]; then
  git remote set-url origin "$REMOTE";
  if [ "${AUTO_UPDATE:-true}" = "true" ]; then
    echo -e "[SETUP] Updating the repository ($MODE)";
    if g fetch --prune --tags origin; then git reset --hard "${DEPLOY_REF:-origin/$BR}"; else echo -e "[WARN] git fetch failed - starting with the code already present"; fi;
  else
    echo -e "[SETUP] AUTO_UPDATE=false - keeping the code already present ($(git rev-parse --short HEAD))";
  fi;
else
  echo -e "[SETUP] Cloning the repository ($MODE)";
  if g clone -b "$BR" "$REMOTE" /home/container/tmp; then
    mv /home/container/tmp/.git . && rm -rf /home/container/tmp && git reset --hard;
    if [ -n "$DEPLOY_REF" ]; then git reset --hard "$DEPLOY_REF"; fi;
  else
    rm -rf /home/container/tmp; echo -e "[ERROR] Clone failed - check GITHUB_REPO_URL, BRANCH and the access method ($MODE)"; exit 1;
  fi;
fi;
unset ACCESS_TOKEN GIT_B64;
if [ -f composer.json ]; then
  echo -e "[SETUP] Install Composer packages"; composer install;
else
  echo -e "[ERROR] No valid composer.json file found for Composer"; exit 1;
fi;
if [ -f package.json ]; then
  echo -e "[SETUP] Install NPM packages";
  if [ "${NPM_IGNORE_SCRIPTS:-false}" = "true" ]; then npm install --ignore-scripts; else npm install; fi;
  if [ -f vite.config.js ]; then echo -e "[SETUP] Build Assets with Vite"; npm run build; else echo -e "[ERROR] No valid Vite file found for Vite"; fi;
else
  echo -e "[ERROR] No valid package.json file found for NPM";
fi;
php artisan migrate --no-interaction --force;
if [ -f /tmp/php-fpm.pid ]; then echo -e "[SETUP] Reloading PHP-FPM workers"; kill -USR2 $(cat /tmp/php-fpm.pid) 2>/dev/null; fi;
while true; do read -r cmd; if [ -n "$cmd" ]; then eval "$cmd" || true; fi; done;
