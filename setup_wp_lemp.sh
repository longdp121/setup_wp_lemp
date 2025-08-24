#!/usr/bin/env bash
# Setup LEMP + WordPress with .env guardrails (Ubuntu 24.04+)
# - Validates/creates .env (ignoring extra/no-value lines)
# - Ensures LEMP components exist & are running
# - Configures UFW for Nginx (you choose profile)
# - Creates DB & user if missing
# - Fresh WP download each run, configures wp-config.php, deploys to /var/www/[SITE_NAME]

set -Eeuo pipefail

REQUIRED_VARS=(DATABASE_NAME DATABASE_USER DATABASE_PASSWORD SITE_NAME BE_HOST BE_PORT FE_HOST FE_PORT)
ENV_FILE=".env"

log() { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR]\033[0m %s\n" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

# --- parse .env safely (ignore invalid/extra lines like 'EXTRA_VAR')
load_env_safe() {
  if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # strip surrounding quotes if present
        val="${val%$'\r'}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        export "$key=$val"
      fi
    done < "$ENV_FILE"
  fi
}

# update/insert KEY=VALUE in .env, preserving other lines
set_env_kv() {
  local k="$1" v="$2"
  v="${v//\\/\\\\}"; v="${v//\//\\/}" # escape for sed
  if grep -Eq "^[[:space:]]*$k=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^[[:space:]]*$k=.*|$k=$v|" "$ENV_FILE"
  else
    printf "%s=%s\n" "$k" "$v" >> "$ENV_FILE"
  fi
  export "$k=$2"
}

prompt_var() {
  local k="$1" prompt="${2:-Enter $1}"
  local secret="${3:-0}" val=""
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$prompt: " val; echo
  else
    read -r -p "$prompt: " val
  fi
  if [[ -z "$val" ]]; then err "$1 cannot be empty"; exit 1; fi
  set_env_kv "$k" "$val"
}

ensure_env() {
  log "Checking .env…"
  [[ -f "$ENV_FILE" ]] || { warn "No .env found; creating."; : > "$ENV_FILE"; }
  load_env_safe

  local missing=()
  for v in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
  done

  if ((${#missing[@]})); then
    log "Some required variables missing — please provide:"
    for v in "${missing[@]}"; do
      if [[ "$v" == "DATABASE_PASSWORD" ]]; then
        prompt_var "$v" "Value for $v" 1
      else
        prompt_var "$v" "Value for $v"
      fi
    done
  fi

  # Confirm values
  echo
  log "Confirming .env values:"
  for v in "${REQUIRED_VARS[@]}"; do
    if [[ "$v" == "DATABASE_PASSWORD" ]]; then
      echo "  $v=********"
    else
      echo "  $v=${!v}"
    fi
  done

  # Guarantee we can source again (in case just created)
  load_env_safe

  # Mandatory update/upgrade step
  log "Updating system packages (apt update && apt -y upgrade)…"
  sudo apt -y update && sudo apt -y upgrade
  ok "READY to go"
}

ensure_nginx() {
  if ! dpkg -s nginx >/dev/null 2>&1; then
    log "Installing Nginx…"
    sudo apt install -y nginx
  fi
  sudo systemctl enable --now nginx
  sudo systemctl is-active --quiet nginx && ok "Nginx is running"
}

ensure_ufw_for_nginx() {
  log "Checking UFW…"

  # install ufw if missing
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw missing — installing…"
    sudo apt -y install ufw
    ufw --version >/dev/null && ok "UFW installed"
  fi

  # helpers
  ufw_app_available() { sudo ufw app list 2>/dev/null | sed '1,2d' | sed '/^$/d' | grep -Fxq "$1"; }
  ufw_rule_present()  { sudo ufw status 2>/dev/null | grep -E -q "$1"; }
  ufw_is_inactive()   { sudo ufw status 2>/dev/null | grep -q "Status: inactive"; }

  # already allowed? (either a known nginx profile or the custom BE_PORT)
  local PORT_REGEX="\\b${BE_PORT}/tcp\\b[[:space:]]+ALLOW"
  if ufw_rule_present "(Nginx (Full|HTTP|HTTPS)).*ALLOW" || ufw_rule_present "$PORT_REGEX"; then
    ok "UFW already allows Nginx/port ${BE_PORT}; no changes needed"
    return 0
  fi

  # decide what to allow (prefer profile; fall back to port)
  local WANT_ENABLE=0
  local forced_profile="${UFW_PROFILE:-}"
  if [[ -n "$forced_profile" ]] && ufw_app_available "$forced_profile"; then
    log "Allowing UFW app profile: ${forced_profile}"
    sudo ufw allow "$forced_profile" || warn "Could not allow profile '$forced_profile'"
    WANT_ENABLE=1
  else
    # pick the best available profile
    if ufw_app_available "Nginx Full"; then
      log "Allowing UFW app profile: Nginx Full"
      sudo ufw allow "Nginx Full" || warn "Could not allow 'Nginx Full'"
      WANT_ENABLE=1
    else
      # allow HTTP/HTTPS if available
      local did_any=0
      if ufw_app_available "Nginx HTTP"; then
        sudo ufw allow "Nginx HTTP" && did_any=1 || warn "Could not allow 'Nginx HTTP'"
      fi
      if ufw_app_available "Nginx HTTPS"; then
        sudo ufw allow "Nginx HTTPS" && did_any=1 || warn "Could not allow 'Nginx HTTPS'"
      fi
      if (( did_any )); then
        WANT_ENABLE=1
      else
        # fall back to allowing the custom backend port
        log "No Nginx profiles available — allowing ${BE_PORT}/tcp directly"
        sudo ufw allow "${BE_PORT}/tcp" && WANT_ENABLE=1 || warn "Could not allow ${BE_PORT}/tcp"
      fi
    fi
  fi

  # enable only if we actually added rules and it’s inactive
  if (( WANT_ENABLE )) && ufw_is_inactive; then
    yes | sudo ufw enable >/dev/null 2>&1 || warn "Could not enable UFW (continuing)"
  fi

  # quick status peek for the first lines
  sudo ufw status | sed -n '1,20p'
}


ensure_mysql() {
  if ! dpkg -s mysql-server >/dev/null 2>&1; then
    log "Installing MySQL Server…"
    sudo apt install -y mysql-server
  fi
  sudo systemctl enable --now mysql
  sudo systemctl is-active --quiet mysql && ok "MySQL is running"

  # Basic hardening (non-interactive)
  log "Running mysql_secure_installation (non-interactive)…"
  sudo mysql_secure_installation <<'EOF' >/dev/null 2>&1 || true
n
y
y
y
y
y
EOF
  ok "mysql_secure_installation attempted/applied"
}

ensure_php84() {
  log "Ensuring PHP 8.4 (FPM + common extensions)…"

  # Ensure repo-helper tools (install only if missing)
  local tools=(software-properties-common ca-certificates lsb-release apt-transport-https)
  local tools_missing=()
  for t in "${tools[@]}"; do
    dpkg -s "$t" >/dev/null 2>&1 || tools_missing+=("$t")
  done
  (( ${#tools_missing[@]} )) && sudo apt install -y "${tools_missing[@]}"

  # Detect Ondřej’s PHP PPA in BOTH .list and .sources (Ubuntu 24.04 uses .sources)
  local need_update=0
  if ! grep -RqsE 'ondrej(/|-)php|ppa\.launchpadcontent\.net/ondrej/php' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
    sudo add-apt-repository -y ppa:ondrej/php
    need_update=1
  fi

  # Desired PHP packages
  local pkgs=(
    php8.4-fpm php8.4-cli php8.4-common php8.4-mysql
    php8.4-curl php8.4-gd php8.4-intl php8.4-mbstring php8.4-soap php8.4-xml php8.4-zip
  )

  # Compute what's actually missing via dpkg -s
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  # Only touch apt when necessary
  if (( need_update )) || (( ${#missing[@]} )); then
    sudo apt update
  fi
  if (( ${#missing[@]} )); then
    sudo apt install -y "${missing[@]}"
  else
    ok "PHP 8.4 packages already present — skipping install"
  fi

  # Ensure PHP-FPM is enabled and running
  sudo systemctl enable --now php8.4-fpm
  if systemctl is-active --quiet php8.4-fpm; then
    ok "PHP-FPM 8.4 is running"
  else
    err "PHP-FPM 8.4 failed to start"
    journalctl -u php8.4-fpm --no-pager -n 50 || true
    exit 1
  fi

  # Sanity check: socket path used by your nginx fastcgi_pass
  [[ -S /run/php/php8.4-fpm.sock ]] || warn "php8.4-fpm socket not at /run/php/php8.4-fpm.sock (check pool config)."
}


lemp_ready() {
  systemctl is-active --quiet nginx && \
  systemctl is-active --quiet mysql && \
  systemctl is-active --quiet php8.4-fpm
}

ensure_lemp() {
  log "Ensuring LEMP is ready…"
  ensure_nginx
  ensure_ufw_for_nginx
  ensure_mysql
  ensure_php84

  if lemp_ready; then
    ok "LEMP IS READY"
  else
    err "LEMP not fully ready — check services"; exit 1
  fi
}

mysql_exec() { sudo mysql -e "$1" >/dev/null; }

ensure_db_and_user() {
  local db="$DATABASE_NAME" user="$DATABASE_USER" pass="$DATABASE_PASSWORD"
  log "Ensuring MySQL database & user…"
  # Create DB if missing
  if ! sudo mysql -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db}'" | grep -qx "${db}"; then
    mysql_exec "CREATE DATABASE \`${db}\` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
    ok "Database '${db}' created"
  else
    ok "Database '${db}' already exists"
  fi
  # Create user if missing; grant privileges
  mysql_exec "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';"
  mysql_exec "GRANT ALL ON \`${db}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"
  ok "User '${user}' ensured & granted on ${db}"
}

configure_nginx_server_block() {
  local site="$SITE_NAME" host="$BE_HOST" port="$BE_PORT"
  log "Configuring Nginx server block for ${site}…"
  sudo mkdir -p "/var/www/${site}"

  # Write server block
  sudo tee "/etc/nginx/sites-available/${site}" >/dev/null <<CONF
server {
    listen ${port};
    server_name ${host} www.${host};
    root /var/www/${site};

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }
    location ~* \.(css|gif|ico|jpeg|jpg|js|png)\$ {
        expires max;
        log_not_found off;
    }

    location ~ /\.ht {
        deny all;
    }
}
CONF

  # Enable site
  [[ -e "/etc/nginx/sites-enabled/${site}" ]] || sudo ln -s "/etc/nginx/sites-available/${site}" "/etc/nginx/sites-enabled/${site}"

  # Test & reload
  sudo nginx -t && sudo systemctl reload nginx
  ok "Nginx site '${site}' enabled on port ${port}"
}

fresh_wp_download_and_config() {
  log "Fetching fresh WordPress to ./tmp …"
  rm -rf tmp && mkdir -p tmp
  curl -fsSL https://wordpress.org/latest.tar.gz | tar -xz --strip-components=1 -C tmp
  cp tmp/wp-config-sample.php tmp/wp-config.php

  # Inject DB creds
  sed -i "s/database_name_here/${DATABASE_NAME}/" tmp/wp-config.php
  sed -i "s/username_here/${DATABASE_USER}/"     tmp/wp-config.php
  sed -i "s/password_here/${DATABASE_PASSWORD}/" tmp/wp-config.php

  # Add FS_METHOD after DB_COLLATE
  sed -i "/DB_COLLATE/a define( 'FS_METHOD', 'direct' );" tmp/wp-config.php

  # Replace salts block with fresh salts from WP API
  curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ -o tmp/wp-salts.txt
  # Remove any existing sample salt lines and insert new ones after the comment header
  awk -v RFILE="tmp/wp-salts.txt" '
    BEGIN{printed=0; inblock=0}
    /^\s*define\( '\''AUTH_KEY'\''/ { 
      if (!printed) {
        while ((getline line < RFILE) > 0) print line;
        close(RFILE);
        printed=1; inblock=1;
      }
      next
    }
    inblock==1 {
      if ($0 ~ /^\s*define\( '\''NONCE_SALT'\''/) { inblock=0; next }
      next
    }
    { print }
  ' tmp/wp-config.php > tmp/wp-config.new && mv tmp/wp-config.new tmp/wp-config.php

  # Deploy to /var/www/[SITE_NAME] (fresh each run)
  local dest="/var/www/${SITE_NAME}"
  log "Deploying WordPress to ${dest} …"
  sudo mkdir -p "$dest"
  sudo rm -rf "${dest:?}/"*  # fresh
  sudo cp -a tmp/. "$dest"
  sudo chown -R www-data:www-data "$dest"
  ok "WordPress deployed to ${dest}"
}

main() {
  need_cmd sudo
  need_cmd curl
  need_cmd tar
  ensure_env
  ensure_lemp
  ensure_db_and_user
  configure_nginx_server_block
  fresh_wp_download_and_config
  ok "DONE"
}

main "$@"
