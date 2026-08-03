# Changelog

All notable changes to `onevoice-storage` are tracked here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

Latest tagged release: `v1.3.0` (2026-07-18)

## [Unreleased]

### Completed

#### Cloudflare Tunnel + custom domain
- Deployed `cloudflared` on the EC2 instance, tunneling inbound traffic instead of relying on the instance's public IP with 80/443 open directly.
- Registered a personal `.dev` domain and created a subdomain for Nextcloud, currently `onevoice.knoch.dev`, routed through the tunnel over HTTPS.
- **Why:** members were hitting `http://<server-ip>` directly and getting browser "Not Secure" warnings, since there was no domain/TLS yet (this was the open DNS/TLS item from Phase 6 in the project plan).
- **Naming note:** the subdomain will move to `1v.nextcloud.knoch.dev` later, once the broader `knoch.dev` naming convention is applied across other subdomains/projects. Not urgent, just noted so it doesn't get lost.
- **Status:** live and complete.

#### Memory upgrade (t3.small → t3.medium)
- Bumped the EC2 instance type in `compute.tf` from `t3.small` to `t3.medium`.
- **Root cause:** the OOM killer was repeatedly terminating `php-fpm` workers under memory pressure on `t3.small`.
- **Status:** applied, issue resolved. Instance now has headroom; this also makes the "SSH in for a quick config tweak" pain point (see MCP server below) a nice-to-have rather than urgent.
- **Cost impact:** worth updating the cost table in the README/project plan next time it's touched — `t3.medium` runs higher than the `~$15.18/mo` currently listed for `t3.small`.

### Planned (not yet started / not yet applied)

#### Bake config drift into the golden AMI (Cloudflare Tunnel, nginx rate limiting, MCP server + maintenance automation)
- Three things have been running live on the EC2 instance, applied by hand over SSH, with no representation in `packer/setup.sh` or Terraform: `cloudflared`, nginx rate limiting (`limit_req_zone`/`limit_req`), and the Nextcloud MCP server + its monthly maintenance-check timer.
- **Why:** a rebuild from the golden AMI today would come up missing all three — Cloudflare Tunnel ingress, rate limiting, and the MCP/maintenance automation documented in `docs/nextcloud-maintenance-automation.md` would all need to be manually reapplied over SSH again.
- **What's done:** `packer/setup.sh`, `packer/nextcloud.pkr.hcl` (new `files/` provisioner), `terraform/scripts/user-data.sh`, `terraform/compute.tf`, and `terraform/data.tf` have all been updated — cloudflared/gh CLI/uv+MCP server install and the new systemd units are baked in at Packer build time, and `user-data.sh` now pulls 5 new secrets from SSM at boot (tunnel token; MCP username, app password, token encryption key; GitHub PAT) to start them. Also reconciled `domain_name` (was hardcoded `""`) to `onevoice.knoch.dev`, since that's been live since the Cloudflare Tunnel work above.
- **Status:** code complete, sitting on a feature branch not yet pushed/PR'd — blocked on a GitHub App permission gap (write access to Issues and Contents both return `403 Resource not accessible by integration`; the app shows as not installed on the account). Also needs: the 5 SSM SecureString parameters created out-of-band before any instance using the new `user-data.sh` launches (Terraform only grants read access, it can't generate a Cloudflare token or a GitHub PAT itself), and `terraform validate`/`packer validate` run for real (only reviewed by eye so far, no CLI access in the environment that wrote this).
- Tracked as issues #41 (Cloudflare Tunnel), #42 (nginx rate limiting), #43 (MCP server + maintenance timer), parented under #44.

#### Remove the Elastic IP
- Remove `aws_eip` (and any associated output/reference) from `compute.tf`.
- **Why:** a static IP was only needed for DNS/TLS before a domain existed. Cloudflare Tunnel now handles ingress, so the EIP is dead weight.
- **Mechanics:** delete the resource block, `terraform plan` to confirm a clean single-resource destroy, `terraform apply`. No dependent resources expected, but worth double-checking `data.tf` and `monitoring.tf` don't reference the EIP's address anywhere.

#### S3 → Cloudflare R2 migration
- Move object storage off AWS S3 onto Cloudflare R2 for both buckets currently defined in `s3.tf`:
  - The primary Nextcloud objectstore bucket (Nextcloud's `objectstore` backend, currently authenticated via the EC2 instance's IAM role).
  - The migration bucket (mounted as Nextcloud External Storage, currently authenticated via a dedicated IAM user/access key since External Storage doesn't support instance-role auth).
- **Why:** R2 is noticeably cheaper than S3, especially with no egress fees.
- **Open question to resolve before starting:** the primary bucket's auth model changes meaningfully. There's no IAM-role equivalent on R2, so that bucket will need R2 API tokens or S3-compatible access keys instead of instance-role auth. The migration bucket's auth model (already access-key based) should translate over more directly.
- **Status:** not started, needs a design pass on auth before touching Terraform.

#### MCP server on the app server
- Research and stand up an MCP server on the EC2 (and eventually on-prem) host.
- **Why:** originally motivated by OOM kills making SSH access annoying/urgent; now that the `t3.medium` upgrade resolved the immediate issue, this becomes a convenience item — quick config changes and status checks without SSH-ing in every time.
- **Status:** research phase, nothing built yet.

#### On-prem compute migration (Optiplex 7040)
- Stand up a refurbished Optiplex 7040 as an on-prem compute target.
- Run Nextcloud in a Docker container on that box.
- Front it with its own Cloudflare Tunnel, same pattern as the AWS setup, specifically to avoid exposing the home router's public IP.
- **Status:** hardware chosen, no build work started yet. Will likely need its own architecture notes once started, since this is a meaningfully different deployment shape (Docker + on-prem) from the current Packer/EC2/Terraform stack.

---

*Compiled from the current AWS-based architecture (EC2 + S3 + RDS via Terraform/Packer, no CI/CD) documented in the repo README and project plan.*
