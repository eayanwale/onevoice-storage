# OneVoice Storage

Self-hosted Nextcloud on AWS, replacing a shared personal Dropbox for the OneVoice gospel/choir group. Deployed with Terraform (infra) and Packer (golden AMI), applied manually/locally — no CI/CD.

## Architecture

```
VPC/IGW → EC2 (Packer-baked AMI) + IAM instance role → S3 (primary storage) + RDS MySQL
                                                       ↳ Elastic IP (DNS/TLS once a domain is acquired)
```

- **Storage:** Nextcloud's primary object storage is an S3 bucket, accessed via the EC2 instance's IAM role (no static keys).
- **Database:** RDS MySQL in private subnets, reachable only from the app server's security group.
- **Compute:** EC2 instance built from a Packer AMI (nginx, PHP 8.2, Nextcloud, certbot), configured on first boot via `user-data.sh` (idempotent — pulls secrets from SSM, runs `occ` install, sets up S3 object storage, theming, and initial user accounts).
- **State backend:** S3 only, SSE-KMS + versioning + `use_lockfile` for native locking — no DynamoDB table.

See [docs/nextcloud-project-plan.md](docs/nextcloud-project-plan.md) for full phase-by-phase status and design decisions.

## Repo layout

```
infra/
└── bootstrap/           # random_password, SSM parameters, state bucket — applied once, rarely touched

onevoice-storage/
├── terraform/            # main stack — reads bootstrap state via data "terraform_remote_state"
│   ├── vpc.tf             # VPC, subnets, security groups, S3 gateway endpoint
│   ├── iam.tf             # EC2 role + S3/SSM access policies
│   ├── db.tf              # RDS MySQL
│   ├── s3.tf              # Primary storage bucket + branding asset
│   ├── compute.tf         # EC2 instance, key pair, EBS data volume, EIP
│   ├── data.tf             # remote state, AMI lookup, SSM lookups
│   ├── scripts/user-data.sh  # first-boot Nextcloud install/config
│   └── keys/               # EC2 key pair — public half only, see Security below
└── packer/
    ├── nextcloud.pkr.hcl   # golden AMI template
    └── setup.sh            # AMI provisioning script
```

## Prerequisites

- Terraform >= 1.7.0, AWS provider ~> 5.0
- Packer with the `amazon` plugin
- An AWS CLI profile named `onevoice` with credentials for the target account

## Deploying

1. **Bootstrap** (once, rarely touched):
   ```
   cd infra/bootstrap
   terraform init && terraform apply
   ```
   Creates the Terraform state bucket and generates the DB/admin passwords in SSM.

2. **Golden AMI**:
   ```
   cd onevoice-storage/packer
   packer build nextcloud.pkr.hcl
   ```
   Bakes an AMI (`ami-nextcloud-*`) with nginx, PHP, Nextcloud, and certbot pre-installed.

3. **Main stack**:
   ```
   cd onevoice-storage/terraform
   terraform init && terraform apply
   ```
   Provisions the VPC, IAM role, RDS instance, S3 bucket, and EC2 instance. The instance runs `scripts/user-data.sh` on first boot to install and configure Nextcloud automatically. Check the `server_ip` output for the app's public address.

## Security notes

- The EC2 key pair's **public** half (`keys/nextcloud-key.pub`) is meant to be the only committed artifact; the private key and any `.pem` files are excluded via `.gitignore`.
- DB and admin credentials are generated with `random_password` and stored in SSM (`SecureString`), never in Terraform variables or state-visible plaintext.
- SSH (22) is restricted to a single admin IP in `vpc.tf`; 80/443 are open for Nextcloud access until a domain + TLS (Phase 6) is in place.

## Status

Networking, IAM, database, golden AMI, and compute are deployed. DNS/TLS is deferred pending a domain. Nextcloud app config (install, DB, S3 storage, theming, users) is automated via user-data; group folders are still manual. See the project plan doc for the full breakdown.
