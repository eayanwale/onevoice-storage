#!/bin/bash
set -euxo pipefail

# --- Wait for network/cloud-init to settle ---
sleep 10

# --- Pull DB password from SSM (same param bootstrap created) ---
DB_PASSWORD=$(aws ssm get-parameter \
  --name "${db_password_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

# --- Pull admin password from SSM (same param bootstrap created) ---
ADMIN_PASSWORD=$(aws ssm get-parameter \
  --name "${admin_password_ssm_path}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${aws_region}")

# --- Start services (enabled at bake time, not started) ---
systemctl start php-fpm
systemctl start nginx

# Increase PHP memory limit to 512M
sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php.ini

# Restart PHP-FPM to apply
systemctl restart php-fpm

# --- Run Nextcloud CLI install (idempotent-ish: skip if already configured) ---
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

  # --- Configure S3 as primary storage ---
  # NOTE: the class must be set as a sub-key, not the top-level value,
  # or Nextcloud throws "No class given for objectstore" / crashes the mount.
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
  # no key/secret set here on purpose — relies on the EC2 instance profile's IAM role

  # --- Trusted domain (Elastic IP; swap for real domain once Phase 6 DNS is live) ---
  sudo -u nginx php /var/www/nextcloud/occ config:system:set trusted_domains 1 \
    --value "${elastic_ip}"

  # --- Optional: also trust a DNS name if provided (index 2, doesn't overwrite the IP) ---
  if [ -n "${domain_name}" ]; then
    sudo -u nginx php /var/www/nextcloud/occ config:system:set trusted_domains 2 \
      --value "${domain_name}"
  fi

  echo "Nextcloud install complete."
else
  echo "Nextcloud already configured, skipping install."
fi

# --- Nextcloud theming (logo pulled from S3, correct nginx user) ---
NC_DIR="/var/www/nextcloud"
LOGO_PATH="$${NC_DIR}/branding/logo.png"

mkdir -p "$${NC_DIR}/branding"
aws s3 cp "s3://${s3_bucket}/branding/logo.png" "$${LOGO_PATH}" --region "${aws_region}"
chown nginx:nginx "$${LOGO_PATH}"

cd "$${NC_DIR}"
sudo -u nginx php occ theming:config name "OneVoice"
sudo -u nginx php occ theming:config primary_color "#1a5d3a"
sudo -u nginx php occ theming:config logo "$${LOGO_PATH}"

# --- Add initial users (idempotent: skip existing) ---
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