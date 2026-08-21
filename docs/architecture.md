# Architecture

Diagrams of the two deployment targets, and of what actually differs between
them. Drawn from the Terraform and the provisioning scripts, not from memory —
if the code and a diagram disagree, the code is right and the diagram is stale.

Sources are single SVG files in [`diagrams/`](diagrams/). They render inline on
GitHub, open in any browser, and follow your light/dark setting. They are plain
text, so they diff and review like code.

| File | Shows |
| --- | --- |
| [`aws-architecture.svg`](diagrams/aws-architecture.svg) | The AWS stack: VPC, EC2, RDS, the two buckets, the managed control plane |
| [`bluehost-architecture.svg`](diagrams/bluehost-architecture.svg) | The Bluehost VPS: one host, every service local, B2 and SES outbound |
| [`deployment-comparison.svg`](diagrams/deployment-comparison.svg) | The shared application spine and the six roles that swap |

---

## AWS — `onevoice.knoch.dev`

![AWS architecture](diagrams/aws-architecture.svg)

**The request path is short and the control plane is wide.** Public traffic
never enters through the IGW — `cloudflared` dials out to Cloudflare, so the
security group's 80/443 rules are open to the world but carry nothing.

The four diagonals are the instance's four managed-service relationships, and
each is a deliberately different auth story:

- **primary bucket** — the EC2 instance role, no static keys anywhere on disk;
- **migration bucket** — a scoped IAM *user* with an access key, because
  Nextcloud's External Storage app cannot use an instance role;
- **SSM Parameter Store** — eight SecureStrings, read once at first boot;
- **CloudWatch** — the agent pushing memory and disk, which EC2 does not
  publish itself.

Two things the diagram shows that are worth knowing before you touch the
network:

- The **S3 gateway endpoint is routed on `priv-rt` only**
  ([`vpc.tf`](../aws/terraform/vpc.tf)), but the instance sits in `pub-a` on
  `main-rt` ([`compute.tf`](../aws/terraform/compute.tf)) — so its S3 traffic
  leaves through the internet gateway, not the endpoint.
- **`nextcloud-sg` opens 80/443 to `0.0.0.0/0`** while the tunnel is
  outbound-only. Those rules carry no traffic, but the instance does have a
  public IP.

Operational detail, secrets layout and the gotcha log: [`aws/README.md`](../aws/README.md).

---

## Bluehost VPS — `cloud.knoch.dev`

![Bluehost VPS architecture](diagrams/bluehost-architecture.svg)

**Everything AWS managed for the other host is now a process inside this box.**
The stack is closed to the outside: firewalld admits only SSH, and the sole way
a request reaches nginx is back down the tunnel `cloudflared` opened.

- **SELinux enforcing** is the single largest departure from Amazon Linux.
  Without the `semanage fcontext` rules and the `httpd_can_network_*` booleans
  in `provision.sh`, nginx cannot read the docroot, php-fpm cannot write
  `config/`, and every outbound S3 call is denied.
- **B2 does not keep Nextcloud off the local volume.** Previews, chunked-upload
  staging and `oc_filecache` all land on the 50 GB disk — previews are the one
  that will fill it.
- **MCP and the maintenance timer are off here** so two hosts don't file
  duplicate monthly issues and PRs.

Install steps, the `onevoice.env` shape and the EL10 platform facts:
[`bluehost/README.md`](../bluehost/README.md).

---

## What actually swaps

![One application, two substrates](diagrams/deployment-comparison.svg)

Comparing the two diagrams box for box overstates the difference. The
application layer is genuinely identical — same Nextcloud 30, same theming and
seed users, and an nginx server block that is byte-identical between the two.
What changes is which thing fills six supporting roles, and whether that thing
is a Terraform resource or a line in a shell script.

Read a row across and you have the whole porting decision for that role. The
rows are not interchangeable in cost or blast radius:

- **Swapping the database was forced.** Pointing this clone at prod's RDS would
  not produce a copy — it would attach a second Nextcloud to prod's
  `oc_filecache` with a different data directory, corrupting both.
- **Swapping object-store auth was mechanical.** A VPS has no IMDS, so there is
  no instance role to read and an explicit key becomes mandatory.

---

## Keeping these current

The diagrams are hand-authored SVG — no build step, no toolchain, no export.
Edit the `<text>` and coordinates directly and the change shows up in the next
GitHub render.

Update them when any of these change, since each is drawn explicitly:

- instance type, RDS class, or subnet CIDRs;
- the set of SSM parameters, or where secrets come from on either host;
- which services run on the instance (the six chips inside the EC2 box);
- the CloudWatch alarm set, or anything about the alerting path;
- an `onevoice.env` flag that turns a component on or off.
