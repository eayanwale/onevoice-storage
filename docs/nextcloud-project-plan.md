# OneVoice Nextcloud Migration — Project Plan

**Project:** Self-hosted Nextcloud on AWS EC2, replacing shared personal Dropbox for the OneVoice gospel/choir group
**Org variable:** `onevoice`
**Deployment tooling:** Terraform (infra) + Packer (golden AMI), applied manually/locally
**Naming convention:** `${var.organization}-${var.environment}-<resource>`

---

## Architecture Summary

VPC/IGW → EC2 (launched from Packer-baked AMI) + IAM instance role → S3 bucket (primary file storage) + RDS MySQL (app database), fronted by an Elastic IP. DNS/TLS layered on once a domain is acquired. Terraform and Packer are run manually/locally rather than through a CI/CD pipeline.

Terraform is split into two root modules with separate state files:

```
infra/
├── bootstrap/       # random_password, SSM parameter, (optionally) state bucket — applied once, rarely touched
│   ├── versions.tf
│   ├── main.tf
│   └── outputs.tf
├── main/            # everything else — reads bootstrap outputs via data sources
│   ├── versions.tf
│   ├── networking.tf   # Phase 1
│   ├── iam.tf           # Phase 2
│   ├── database.tf      # Phase 3
│   ├── compute.tf        # Phase 5
│   ├── dns.tf             # Phase 6 (deferred)
│   └── outputs.tf
└── packer/
    └── nextcloud.pkr.hcl # Phase 4
```

State backend: S3 only (SSE-KMS, versioning enabled) — no DynamoDB lock table.

---

## Phase Status

| Phase | Description | Status |
|---|---|---|
| Bootstrap | Password generation, SSM parameter, state bucket | ✅ Done |
| 1 — Networking | VPC, IGW, subnets, security groups, EIP, S3 gateway endpoint | ✅ Done |
| 2 — IAM | EC2 role, S3 access policy, instance profile | ✅ Done |
| 3 — Database | RDS MySQL, subnet group, security group, SSM-sourced password | ✅ Done |
| 4 — Golden AMI | Packer template + provisioner script (nginx, PHP 8.2, Nextcloud, certbot) | ✅ Done |
| 5 — Compute | EC2 instance/launch template, EBS volume, EIP association | ✅ Written up |
| 6 — DNS & TLS | Route53 record, certbot cert | ⏸️ Deferred — no domain yet |
| 7 — Nextcloud app config | Web installer, DB connection, S3 external storage, Group Folders, users | 🔄 In progress |
| 9 — Ops basics | CloudWatch alarms, RDS scheduled snapshots, onboarding docs | ⬜ Not started |

---

## Phase Details

### Phase 1 — Networking ✅
- VPC with public subnet (non-overlapping CIDR)
- Internet Gateway + route table
- Security group: 443/80 open, 22 restricted to admin IP
- Elastic IP allocated
- S3 gateway endpoint

### Phase 2 — IAM ✅
- IAM role for EC2 scoped to the Nextcloud S3 bucket (Get/Put/Delete/List)
- Instance profile attaching the role

### Phase 3 — Database ✅
- RDS MySQL instance
- DB subnet group (private subnets)
- Security group: 3306 inbound restricted to EC2 SG only
- Password read via `data "aws_ssm_parameter"` from bootstrap — main stack never owns the secret
- Outputs: RDS endpoint for downstream use in Phase 7

### Phase 4 — Golden AMI ✅
- Base: Amazon Linux 2023 (`al2023-ami-*-x86_64`), selected via `data "aws_ami"`
- Packer builds an EBS-backed AMI, shared to specified accounts/regions
- Provisioner installs: nginx, PHP 8.2 (+ gd, mbstring, xml, curl, zip, intl, mysqlnd, bcmath, gmp, opcache), Nextcloud (unpacked to `/var/www/nextcloud`), certbot (binary only — no cert issuance at bake time)
- nginx server block configured for PHP-FPM via Unix socket
- Services enabled but not started at bake time
- **Open item:** confirm `component = "clixx"` variable in the Packer file is intentional or leftover from a template

### Phase 5 — Compute ✅ (written, not yet reviewed against live infra)
- `data "aws_ami"` lookup (owner: self, filtered by name pattern `ami-nextcloud-*`)
- EC2 instance/launch template: public subnet, instance profile, Phase 1 SG
- EBS root volume sized for OS + app only (files live in S3)
- Elastic IP association
- **Open decision:** whether Phase 7's Nextcloud install runs via user-data on first boot, or manually via SSH

### Phase 6 — DNS & TLS ⏸️ Deferred
- Blocked: no domain registered yet
- Interim approach: access Nextcloud via the AWS-assigned public DNS name over plain HTTP (port 80)
- ACM is not usable here without adding a load balancer in front of the instance — not planned for this scope
- When a domain is acquired:
  - `data "aws_route53_zone"` lookup
  - `aws_route53_record` (A record → Elastic IP)
  - `certbot --nginx` run manually or via user-data once DNS propagates

### Phase 7 — Nextcloud Application Config 🔄 In Progress
1. Pull DB password from SSM (`aws ssm get-parameter --with-decryption`)
2. Confirm nginx + php-fpm are running on the instance
3. Run the web installer at `http://<EIP-DNS-name>/`
4. Enter DB connection details (RDS endpoint, DB name/user/password)
5. Enable `files_external` app, configure S3 bucket as external storage (verify role-based auth support vs. access key/secret)
6. Enable `groupfolders` app
7. Create groups: media, general, music, IT
8. Assign folders to groups with appropriate permission levels

### Phase 9 — Ops Basics ⬜ Not Started
- CloudWatch alarm on instance status checks
- RDS scheduled snapshots (via `aws_db_instance` automated backup window, or an AWS Backup plan targeting the RDS instance on a schedule)
- Onboarding documentation for the group (Nextcloud URL, sync client download links)

> Infra management note: Jenkins was descoped — `terraform apply` and Packer builds are run manually/locally. Revisit if the project grows to multiple maintainers or a second workload.

---

## Deferred / Open Decisions Log

- **Domain name:** not yet acquired; Phase 6 blocked until decided (Route53-registered vs. external registrar)
- **Phase 7 install method:** manual SSH install vs. user-data automation — not yet decided
- **S3 auth method in Nextcloud:** IAM role vs. access key/secret — needs verification against Nextcloud's S3 backend support
- **Packer `component` variable:** confirm intentional vs. template leftover
- **Nextcloud version pin:** currently placeholder `30.0.0` in provisioner script — confirm before final bake