#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y nginx

dnf install -y \
  php8.2 php8.2-fpm php8.2-cli \
  php8.2-gd php8.2-mbstring php8.2-xml \
  php8.2-zip php8.2-intl php8.2-mysqlnd php8.2-bcmath \
  php8.2-gmp php8.2-opcache

NEXTCLOUD_VERSION="30.0.0" # bump deliberately, not automatically
cd /tmp
curl -O "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip"
unzip -q "nextcloud-${NEXTCLOUD_VERSION}.zip" -d /var/www/
rm -f "nextcloud-${NEXTCLOUD_VERSION}.zip"

chown -R nginx:nginx /var/www/nextcloud
find /var/www/nextcloud/ -type d -exec chmod 750 {} \;
find /var/www/nextcloud/ -type f -exec chmod 640 {} \;

sed -i 's/^user = .*/user = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.owner = .*/listen.owner = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf

mkdir -p /var/lib/php/session
chown -R nginx:nginx /var/lib/php/session
chmod 700 /var/lib/php/session

cp /tmp/packer-files/rate-limit.conf /etc/nginx/conf.d/rate-limit.conf

cat > /etc/nginx/conf.d/nextcloud.conf <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/nextcloud;

    client_max_body_size 512M;
    fastcgi_buffers 64 4K;

    location / {
        limit_req zone=nextcloud_limit burst=20 nodelay;
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

    location ~ \.(?:css|js|mjs|svg|gif|png|jpg|ico|woff2?)$ {
        expires 30d;
        access_log off;
    }
}
EOF

rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# certbot: binary only, no cert issuance at bake time — no DNS yet
# dnf install -y python3-pip
# pip3 install certbot certbot-nginx

curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo
sudo yum install -y cloudflared
cp /tmp/packer-files/cloudflared.service /etc/systemd/system/cloudflared.service

dnf install -y git

dnf install -y 'dnf-command(config-manager)'
dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
dnf install -y gh --repo gh-cli

# github.com/cbcoutinho/nextcloud-mcp-server: full clone + uv sync, not a
# standalone uv-managed dependency project.
sudo -u ec2-user bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
sudo -u ec2-user bash -c '
  git clone https://github.com/cbcoutinho/nextcloud-mcp-server.git /home/ec2-user/nextcloud-mcp-server
  cd /home/ec2-user/nextcloud-mcp-server
  /home/ec2-user/.local/bin/uv sync
'

mkdir -p /home/ec2-user/scripts
chown ec2-user:ec2-user /home/ec2-user/scripts

cp /tmp/packer-files/nextcloud-maintenance-check.sh /home/ec2-user/scripts/nextcloud-maintenance-check.sh
chown ec2-user:ec2-user /home/ec2-user/scripts/nextcloud-maintenance-check.sh
chmod 700 /home/ec2-user/scripts/nextcloud-maintenance-check.sh

cp /tmp/packer-files/nextcloud-mcp.service /etc/systemd/system/nextcloud-mcp.service
cp /tmp/packer-files/nextcloud-maintenance.service /etc/systemd/system/nextcloud-maintenance.service
cp /tmp/packer-files/nextcloud-maintenance.timer /etc/systemd/system/nextcloud-maintenance.timer
systemctl daemon-reload

systemctl enable nginx
systemctl enable php-fpm
systemctl enable cloudflared
systemctl enable nextcloud-mcp
# nextcloud-maintenance.service is a oneshot triggered by the timer, not enabled directly
systemctl enable nextcloud-maintenance.timer

echo "Nextcloud AMI provisioning complete."
