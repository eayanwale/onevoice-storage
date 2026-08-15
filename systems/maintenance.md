
## July 2026 Nextcloud maintenance (TEST RUN, 2026-07-31)

- [ ] Verify EC2 public IP is still current (dynamic, not elastic) - check via `aws ec2 describe-instances --profile onevoice`
- [ ] Update Nextcloud core: currently 30.0.0. Nextcloud 30.0.17 is available. Get more information on how to update at https://docs.nextcloud.com/server/30/admin_manual/maintenance/upgrade.html.
1 update available
- [ ] Check Nextcloud app updates in Admin > Apps > Updates (not reliably listable via occ CLI)
- [ ] OS packages: 0
0 package(s) with updates available per `dnf check-update`
- [ ] Kernel/reboot: No reboot needed (running kernel matches latest installed: 6.1.176-220.360.amzn2023.x86_64)
- [ ] Disk usage: 35% used, 20G available on /
- [ ] Memory: 2.5Gi available of 3.7Gi
- [ ] Backups: No cron-based backup job found (user or root crontab)
- [ ] Investigate exited Docker container(s): ecs-agent (amazon/amazon-ecs-agent:latest)

_Generated automatically by nextcloud-maintenance-check.sh on ip-10-30-1-7.ec2.internal at 2026-07-31T06:20:20Z._

## July 2026 Nextcloud maintenance (TEST RUN, 2026-07-31)

- [ ] Verify EC2 public IP is still current (dynamic, not elastic) - check via `aws ec2 describe-instances --profile onevoice`
- [ ] Update Nextcloud core: currently 30.0.0. Nextcloud 30.0.17 is available. Get more information on how to update at https://docs.nextcloud.com/server/30/admin_manual/maintenance/upgrade.html.
1 update available
- [ ] Check Nextcloud app updates in Admin > Apps > Updates (not reliably listable via occ CLI)
- [ ] OS packages: 0
0 package(s) with updates available per `dnf check-update`
- [ ] Kernel/reboot: No reboot needed (running kernel matches latest installed: 6.1.176-220.360.amzn2023.x86_64)
- [ ] Disk usage: 35% used, 20G available on /
- [ ] Memory: 2.5Gi available of 3.7Gi
- [ ] Backups: No cron-based backup job found (user or root crontab)
- [ ] Investigate exited Docker container(s): ecs-agent (amazon/amazon-ecs-agent:latest)

_Generated automatically by nextcloud-maintenance-check.sh on ip-10-30-1-7.ec2.internal at 2026-07-31T06:38:22Z._

## August 2026 Nextcloud maintenance (automated check, 2026-08-15)

- [ ] Verify EC2 public IP is still current (dynamic, not elastic) - check via `aws ec2 describe-instances --profile onevoice`
- [ ] Update Nextcloud core: currently 30.0.0. Nextcloud 30.0.17 is available. Get more information on how to update at https://docs.nextcloud.com/server/30/admin_manual/maintenance/upgrade.html.
1 update available
- [ ] Check Nextcloud app updates in Admin > Apps > Updates (not reliably listable via occ CLI)
- [ ] OS packages: 1
0 package(s) with updates available per `dnf check-update`
- [ ] Kernel/reboot: No reboot needed (running kernel matches latest installed: 6.1.176-220.360.amzn2023.x86_64)
- [ ] Disk usage: 36% used, 20G available on /
- [ ] Memory: 2.6Gi available of 3.7Gi
- [ ] Backups: No cron-based backup job found (user or root crontab)
- [ ] Investigate exited Docker container(s): ecs-agent (amazon/amazon-ecs-agent:latest)

_Generated automatically by nextcloud-maintenance-check.sh on ip-10-30-1-7.ec2.internal at 2026-08-15T05:30:12Z._
