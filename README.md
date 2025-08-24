# LEMP + WordPress One-Click (Ubuntu 24.04+)

Idempotent Bash script to bring up a **LEMP** stack (Nginx, MySQL, PHP-FPM 8.4) and deploy a fresh **WordPress** to `/var/www/[SITE_NAME]` — with a strict `.env` gate, safe defaults, and clean logs.

> Target OS: **Ubuntu 24.04 LTS** (works best). Requires `sudo` privileges and internet access.

---

## What it does

* Validates/creates `.env` (prompts only for missing required keys; ignores extra lines).
* `apt update && apt -y upgrade` to ensure a sane base.
* Installs & enables **Nginx**, ensures **UFW** rules once (no prompts on re-runs).
* Installs & hardens **MySQL** (non-interactive `mysql_secure_installation`), creates DB + user if missing.
* Installs **PHP 8.4** from Ondřej’s PPA (adds it once, installs only missing packages), enables `php8.4-fpm`.
* Writes an Nginx server block at `/etc/nginx/sites-available/[SITE_NAME]` listening on `BE_PORT`.
* Downloads **latest WordPress**, injects DB creds, fetches **fresh salts**, sets `FS_METHOD=direct`, deploys to `/var/www/[SITE_NAME]`, and fixes ownership (`www-data:www-data`).

**Re-run behavior**

* LEMP: left intact if healthy.
* WordPress: re-downloaded into `./tmp` and **re-deployed fresh** (the target folder is emptied).

---

## Requirements

* `sudo`, `curl`, `tar` (the script checks for needed tools).
* Outbound HTTPS (to fetch WordPress & salts API).

---

## .env contract

The script requires a `.env` file (it will create one and prompt for any missing keys).
Required variables:

```bash
REQUIRED_VARS=(DATABASE_NAME DATABASE_USER DATABASE_PASSWORD SITE_NAME BE_HOST BE_PORT FE_HOST FE_PORT)
```

**Optional variables**

* `UFW_PROFILE` — set to a specific UFW app profile (e.g., `Nginx Full`). If not set, the script auto-chooses a suitable profile or opens `BE_PORT/tcp`.

**Notes**

* `SITE_NAME` → site name and target directory `/var/www/[SITE_NAME]`.
* `BE_HOST`, `BE_PORT` → used as `server_name` and `listen` port in Nginx.
* `DATABASE_*` → the script creates the DB & user if they don’t already exist.

---

## Usage

```bash
chmod +x setup_wp_lemp.sh
./setup_wp_lemp.sh
```

You can run with `sudo` or let the script use `sudo` internally when needed.

---

## Nginx details

* Server block path: `/etc/nginx/sites-available/[SITE_NAME]` → symlinked to `sites-enabled/`.
* Root: `/var/www/[SITE_NAME]`
* PHP hand-off: `fastcgi_pass unix:/run/php/php8.4-fpm.sock;`
* After writing the server block, the script runs `nginx -t` and reloads Nginx.

---

## WordPress configuration

* `wp-config.php` is derived from the sample and patched with:

  * `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  * **Fresh salts** from the official salt API
  * `define('FS_METHOD', 'direct');` (convenient for dev)
* Ownership: `www-data:www-data` recursively on `/var/www/[SITE_NAME]`.

> **Security tip:** For production, consider removing `FS_METHOD=direct`, tightening file permissions, enabling TLS, and serving on `80/443` with Let’s Encrypt.

---

## Troubleshooting

* **Port not reachable**: Check `sudo ufw status`. If you’re not on 80/443, ensure `BE_PORT/tcp` is allowed.
* **Nginx test fails**: `sudo nginx -t` to see the error; fix and `sudo systemctl reload nginx`.
* **PHP-FPM socket mismatch**: Confirm `/run/php/php8.4-fpm.sock` exists; adjust `fastcgi_pass` if your pool/socket differs.
* **MySQL auth issues**: The script grants `ALL` on the specified DB to `DATABASE_USER` at `localhost`. Re-run the script to re-apply grants.

---

## Contributing

PRs welcome. Please keep changes:

* **Idempotent** (safe to re-run),
* **Non-interactive** unless absolutely needed,
* **Ubuntu-24.04-friendly**.

---

## License

MIT (recommended). Add a `LICENSE` file before publishing.
