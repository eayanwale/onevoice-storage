#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y nginx

dnf install -y \
  php8.2 php8.2-fpm php8.2-cli \
  php8.2-gd php8.2-mbstring php8.2-xml \
  php8.2-zip php8.2-intl php8.2-mysqlnd php8.2-bcmath \
  php8.2-gmp php8.2-opcache

# --- Nextcloud download ---
NEXTCLOUD_VERSION="30.0.0"  # pin a version, bump deliberately later
cd /tmp
curl -O "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip"
unzip -q "nextcloud-${NEXTCLOUD_VERSION}.zip" -d /var/www/
rm -f "nextcloud-${NEXTCLOUD_VERSION}.zip"

# --- Ownership/permissions (nginx runs as 'nginx' on AL2023) ---
chown -R nginx:nginx /var/www/nextcloud
find /var/www/nextcloud/ -type d -exec chmod 750 {} \;
find /var/www/nextcloud/ -type f -exec chmod 640 {} \;

# --- php-fpm pool tweak: run as nginx user ---
sed -i 's/^user = .*/user = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.owner = .*/listen.owner = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf

# --- PHP session directory: must be writable by the nginx user, since php-fpm
# now runs as nginx (not the default apache/root owner from the base package) ---
mkdir -p /var/lib/php/session
chown -R nginx:nginx /var/lib/php/session
chmod 700 /var/lib/php/session

# --- nginx server block for Nextcloud ---
cat > /etc/nginx/conf.d/nextcloud.conf <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/nextcloud;

    client_max_body_size 512M;
    fastcgi_buffers 64 4K;

    location / {
        rewrite ^ /index.php$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/ {
        deny all;
    }

    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ \.(?:css|js|svg|gif|png|jpg|ico|woff2?)$ {
        expires 30d;
        access_log off;
    }
}
EOF

# remove default nginx conf so it doesn't conflict
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# --- certbot (binary only, no cert issuance at bake time — no DNS yet) ---
# dnf install -y python3-pip
# pip3 install certbot certbot-nginx

# --- enable services for boot (don't start here — AMI shouldn't start with live state) ---
systemctl enable nginx
systemctl enable php-fpm

echo "Nextcloud AMI provisioning complete."