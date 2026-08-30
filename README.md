# incident-automation

Provisioning for the Incident Demo, delivered as a container so nobody has to
install cloud tooling locally.

The intended audience is MongoDB Solution Architects, who each stand up their
own environment rather than sharing a hosted one.

## Status

**GCP provisioning is complete and tested.** Atlas has not been started.

| Command | What it does |
|---|---|
| `gcp setup` | `bootstrap` + `apply` in one command. The usual entry point |
| `gcp bootstrap` | Creates the automation service account, grants its roles, issues a key, verifies it |
| `gcp apply` | Creates the media bucket, the runtime service account, its bucket-scoped role and key |
| `gcp status` | Reports what exists. Changes nothing |
| `gcp validate` | Activates the runtime key and reads the bucket as that identity. Changes nothing |
| `gcp destroy` | Deletes the bucket and the runtime service account. Takes `--yes` |
| `help` | Usage |

## Prerequisites

1. A GCP account, and a project you own. Setup does not create the project.
2. Billing enabled on it.
3. The Cloud Storage API enabled on it.
4. Podman.

`gcloud` on your machine is optional. If it is installed and authenticated,
mount its config and `bootstrap` uses it. If not, `bootstrap` signs you in
interactively with a URL and a verification code.

You do not need to create a service account by hand.

## Run it

```bash
podman build -f containers/Containerfile -t incident-automation .
mkdir -p output

podman run --rm \
  -v ~/.config/gcloud:/gcloud-host:ro \
  -v "$PWD/output:/output" \
  -e GCP_PROJECT_ID=your-project-id \
  -e GCS_BUCKET_BASE_NAME=incident-app \
  incident-automation gcp setup
```

Without gcloud on your machine, drop the `~/.config/gcloud` mount and add
`-it` for the interactive sign-in.

Everything afterwards reads the project and key from `output/`, so no flags
are needed:

```bash
podman run --rm -v "$PWD/output:/output" incident-automation gcp status
podman run --rm -v "$PWD/output:/output" incident-automation gcp validate
```

## What it creates

| Resource | Detail |
|---|---|
| Bootstrap service account | `incident-automation-bootstrap`, with `storage.admin`, `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `serviceusage.serviceUsageAdmin` |
| Bucket | `<base>-<slug>`, uniform access, public access prevented, labelled `managed-by=incident-automation` |
| Runtime service account | `incident-app-storage-<slug>`, with `roles/storage.objectViewer` **on the bucket only** |
| Keys | `output/gcp-bootstrap-key.json`, `output/gcp-runtime-key.json`, mode 600 |
| Records | `output/bootstrap.env`, `output/gcp.env` |

Two accounts, not one. The bootstrap account administers; the runtime account
is what the demo apps authenticate as, and it can do nothing but read objects
from its own bucket.

Bucket names are globally unique, so a fixed name would collide for the second
person who ever ran this. The generated slug also acts as an instance id,
letting two demos coexist in one project. Because the name cannot be
recomputed from inputs, the bucket is labelled — `status`, `validate` and
`destroy` rediscover it even if `output/` is lost.

### output/gcp.env

This is the contract with the demo apps:

```
GCP_PROJECT_ID=...
GCP_INSTANCE_SLUG=...
GCS_LOCATION=...
MEDIA_GCS_BUCKET=<base>-<slug>
GOOGLE_APPLICATION_CREDENTIALS=./output/gcp-runtime-key.json
RUNTIME_SA_EMAIL=...
```

Both apps already read `MEDIA_GCS_BUCKET` from the environment.

## Environment

| Variable | Required | Default |
|---|---|---|
| `GCP_PROJECT_ID` | first run only | then read from `output/bootstrap.env` |
| `GCS_BUCKET_BASE_NAME` | `apply` and `setup` | none. Max 56 characters, lowercase |
| `GCP_CREDENTIALS_JSON` | no | read from `output/gcp-bootstrap-key.json`. Overrides it when set, for CI where there is no `/output` |
| `GCS_LOCATION` | no | `us-central1` |
| `GCP_INSTANCE_SLUG` | no | generated. Set to pin or re-adopt an instance |
| `BOOTSTRAP_SA_NAME` | no | `incident-automation-bootstrap` |
| `RUNTIME_SA_NAME_BASE` | no | `incident-app-storage` |
| `HOST_OUTPUT_DIR` | no | `./output` — host path, so emitted files carry paths that resolve outside the container |

See `.env.example`.

## Re-running

Every verb is idempotent. An existing account, bucket, binding or live key is
reused rather than recreated. Key reuse matters more than it looks: `keys
create` mints a new credential on every call, accounts cap at ten, and an
orphaned key is impossible to tell apart from the live one.

New IAM and storage objects propagate through GCP subsystems independently, so
calls retry on the three symptoms that produces — `does not exist`,
`invalid_grant` / `Invalid JWT Signature`, and `PERMISSION_DENIED`. A run may
pause for a few seconds at those points on a fresh create. Anything else fails
immediately, so real errors are not buried.

## Tearing down

```bash
# bucket, runtime service account, runtime key, gcp.env
podman run --rm -v "$PWD/output:/output" incident-automation gcp destroy --yes

# bootstrap service account, its roles, its key, bootstrap.env
./dev-reset.sh -y
```

Order matters — `destroy` runs as the bootstrap account.

`dev-reset.sh` runs on your host with your own gcloud, and is the one step
that still requires gcloud to be installed. It is temporary: a teardown verb
will replace it.

## Layout

```
containers/   Containerfile and entrypoint
scripts/      common.sh plus one script per verb
output/       emitted keys and records. gitignored
dev-reset.sh  host-side bootstrap teardown, temporary
```

## Not done yet

- Enabling the Cloud Storage API automatically, so it stops being a manual
  prerequisite
- Regenerating the slug automatically when a bucket name is already taken
- A teardown verb for the bootstrap account, replacing `dev-reset.sh`
- Publishing the image, so users do not have to build it
- Everything Atlas

## Decisions

- **gcloud, not Terraform**, for the GCP side. It is a handful of resources in
  a project you already own, and skipping Terraform removes a state file that
  would have to survive between container runs. Resources are found by label
  instead. Atlas will use Terraform, where the resource count justifies it.
- **Podman**, not Docker.
- **One container, verb subcommands**, so later phases add verbs, not images.
- **Bring your own GCP project.** Creating one needs billing and org
  permissions a personal account often lacks, and failures there have nothing
  to do with the demo.
- **Secrets passed as arguments**, never baked into the image. The exception is
  `bootstrap`, which needs your own identity and so reads a mounted gcloud
  config or signs you in.
- **A privilege ladder.** You (owner) create the bootstrap account; it creates
  the runtime account; the runtime account can only read one bucket. The
  bootstrap account cannot create itself, because granting project-level roles
  needs permissions it deliberately does not have.
- **Base image is `gcr.io/google.com/cloudsdktool/google-cloud-cli`**, not the
  legacy `docker.io/google/cloud-sdk` mirror, which is amd64-only and forces
  emulation on Apple Silicon.
