#!/bin/bash
set -euxo pipefail

sleep 10

DB_PASSWORD=$(aws ssm get-parameter \
  --name "${db_password_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

ADMIN_PASSWORD=$(aws ssm get-parameter \
  --name "${admin_password_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

CLOUDFLARE_TUNNEL_TOKEN=$(aws ssm get-parameter \
  --name "${cloudflare_tunnel_token_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

MCP_USERNAME=$(aws ssm get-parameter \
  --name "${mcp_username_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

MCP_APP_PASSWORD=$(aws ssm get-parameter \
  --name "${mcp_password_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

GITHUB_PAT=$(aws ssm get-parameter \
  --name "${github_pat_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

MIGRATION_ACCESS_KEY_ID=$(aws ssm get-parameter \
  --name "${migration_access_key_id_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

MIGRATION_SECRET_ACCESS_KEY=$(aws ssm get-parameter \
  --name "${migration_secret_key_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

mkdir -p /etc/cloudflared
echo "$${CLOUDFLARE_TUNNEL_TOKEN}" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token
systemctl enable --now cloudflared

cat > /home/ec2-user/nextcloud-mcp-server/.env <<EOF
NEXTCLOUD_HOST=https://${domain_name}
NEXTCLOUD_USERNAME=$${MCP_USERNAME}
NEXTCLOUD_PASSWORD=$${MCP_APP_PASSWORD}
EOF
chown ec2-user:ec2-user /home/ec2-user/nextcloud-mcp-server/.env
chmod 600 /home/ec2-user/nextcloud-mcp-server/.env
systemctl enable --now nextcloud-mcp

sudo -u ec2-user bash -c "echo '$${GITHUB_PAT}' | gh auth login --with-token"
sudo -u ec2-user gh auth setup-git
systemctl enable --now nextcloud-maintenance.timer

systemctl start php-fpm
systemctl start nginx

sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php.ini
systemctl restart php-fpm

if [ ! -f /var/www/nextcloud/config/config.php ]; then
  sudo -u nginx php /var/www/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-host "${db_host}" \
    --database-name "${db_name}" \
    --database-user "${db_user}" \
    --database-pass "$${DB_PASSWORD}" \
    --admin-user "${admin_user}" \
    --admin-pass "$${ADMIN_PASSWORD}" \
    --data-dir "/var/www/nextcloud/data"

  # class must be a sub-key, not the top-level value, or Nextcloud throws
  # "No class given for objectstore"
  sudo -u nginx php /var/www/nextcloud/occ config:system:set objectstore class \
    --value "OC\\Files\\ObjectStore\\S3"
  sudo -u nginx php /var/www/nextcloud/occ config:system:set objectstore arguments bucket \
    --value "${s3_bucket}"
  sudo -u nginx php /var/www/nextcloud/occ config:system:set objectstore arguments region \
    --value "${aws_region}"
  sudo -u nginx php /var/www/nextcloud/occ config:system:set objectstore arguments use_path_style \
    --value "false" --type boolean
  sudo -u nginx php /var/www/nextcloud/occ config:system:set objectstore arguments use_ssl \
    --value "true" --type boolean
  # no key/secret here on purpose — relies on the EC2 instance profile's IAM role

  # files_external ships with Nextcloud but isn't enabled by default
  sudo -u nginx php /var/www/nextcloud/occ app:enable files_external

  sudo -u nginx php /var/www/nextcloud/occ files_external:create \
    "Migration" amazons3 amazons3::accesskey \
    --config bucket="${migration_bucket}" \
    --config hostname="s3.${aws_region}.amazonaws.com" \
    --config region="${aws_region}" \
    --config use_ssl=true \
    --config use_path_style=false \
    --config key="$${MIGRATION_ACCESS_KEY_ID}" \
    --config secret="$${MIGRATION_SECRET_ACCESS_KEY}"

  sudo -u nginx php /var/www/nextcloud/occ files:scan --all

  # deletes on S3 storage crash Trashbin's move-to-trash handoff (upstream bug, #28) — disabled instance-wide, no undo/trash as a trade-off
  sudo -u nginx php /var/www/nextcloud/occ app:disable files_trashbin

  sudo -u nginx php /var/www/nextcloud/occ config:system:set trusted_domains 1 \
    --value "${elastic_ip}"

  if [ -n "${domain_name}" ]; then
    sudo -u nginx php /var/www/nextcloud/occ config:system:set trusted_domains 2 \
      --value "${domain_name}"
  fi

  # Nextcloud sits behind Cloudflare Tunnel (HTTPS at the edge, plain HTTP
  # locally) — without trusting that, protocol detection is inconsistent
  # between requests and corrupts session cookie encryption ("HMAC does not
  # match", spinning logins, getting bounced back to the login screen).
  sudo -u nginx php /var/www/nextcloud/occ config:system:set trusted_proxies 0 \
    --value "127.0.0.1"
  sudo -u nginx php /var/www/nextcloud/occ config:system:set overwriteprotocol \
    --value "https"

  echo "Nextcloud install complete."
else
  echo "Nextcloud already configured, skipping install."
fi

NC_DIR="/var/www/nextcloud"

# Stage the logo OUTSIDE the Nextcloud root. Writing it to
# <nextcloud>/branding/logo.png makes `occ integrity:check-core` report
#   EXTRA_FILE: branding/logo.png
# which turns Administration > Overview's code-integrity check into a hard
# failure. Nextcloud's signed manifest covers the whole tree, so ANY extra
# file under it fails — the logo is not special. theming:config reads the
# image and stores its own copy in appdata, so the source need not live there.
BRANDING_DIR="/var/lib/onevoice/branding"
LOGO_PATH="$${BRANDING_DIR}/logo.png"

mkdir -p "$${BRANDING_DIR}"

# Drop the in-tree copy left behind by earlier deploys of this script.
rm -rf "$${NC_DIR}/branding"

aws s3 cp "s3://${s3_bucket}/branding/logo.png" "$${LOGO_PATH}" --region "${aws_region}"
chown nginx:nginx "$${LOGO_PATH}"

cd "$${NC_DIR}"
sudo -u nginx php occ theming:config name "OneVoice"
sudo -u nginx php occ theming:config primary_color "#1a5d3a"
sudo -u nginx php occ theming:config logo "$${LOGO_PATH}"

declare -A NEW_USERS=(
  ["jsomori"]="Joseph Somori"
  ["eayanwale"]="Enoch Ayanwale"
  ["dcole"]="Dionne Cole"
  ["dsomori"]="Deborah Somori"
  ["nakinsanmi"]="Naomi Akinsanmi"
  ["aakinsanmi"]="Ayomide Akinsanmi"
  ["fbajere"]="Feyisola Bajere"
  ["gawogbade"]="Goodness Awogbade"
  ["famure"]="Fiyin Amure"
  ["fojo"]="Favor Ojo"
)

for USERNAME in "$${!NEW_USERS[@]}"; do
  DISPLAY_NAME="$${NEW_USERS[$USERNAME]}"

  if sudo -u nginx php /var/www/nextcloud/occ user:list | grep -q "^\s*$${USERNAME}:"; then
    echo "User $USERNAME already exists, skipping."
    continue
  fi

  GENERATED_PASSWORD=$(openssl rand -base64 18)

  sudo -u nginx OC_PASS="$${GENERATED_PASSWORD}" php /var/www/nextcloud/occ user:add \
    --password-from-env \
    --display-name="$${DISPLAY_NAME}" \
    "$${USERNAME}"

  aws ssm put-parameter \
    --name "/${organization}/${environment}/nextcloud/users/$${USERNAME}/password" \
    --value "$${GENERATED_PASSWORD}" \
    --type "SecureString" \
    --overwrite \
    --region "${aws_region}"

  echo "Created user $USERNAME, password stored in SSM at /${organization}/${environment}/nextcloud/users/$${USERNAME}/password"
done
