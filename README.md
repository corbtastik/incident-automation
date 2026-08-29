# incident-automation

Provisioning for the Incident Demo, delivered as a container so nobody has to
install cloud tooling locally.

The intended audience is MongoDB Solution Architects, who each stand up their
own environment rather than sharing a hosted one.

## Status

**Phase 0 complete.** The container authenticates and can create the scoped
service account that later phases run as. No buckets, no Atlas resources yet.

Implemented and tested:

| Command | What it does |
|---|---|
| `gcp bootstrap` | Creates the automation service account, grants its roles, issues a key, and verifies the key works |
| `gcp status` | Reports the authenticated identity and checks the Storage API is reachable. Changes nothing |
| `help` | Usage |

## Prerequisites

1. A GCP account, and a project you own. Setup does not create the project.
2. Billing enabled on it.
3. The Cloud Storage API enabled on it.
4. Podman.
5. `gcloud` authenticated on your machine (`gcloud auth login`), or be ready
   to sign in interactively — see below.

You do **not** need to create a service account by hand. That is what
`gcp bootstrap` is for.

## Run it

Build:

```bash
podman build -f containers/Containerfile -t incident-automation .
```

Bootstrap, once. This is the only command that runs as you:

```bash
mkdir -p output

podman run --rm \
  -v ~/.config/gcloud:/gcloud-host:ro \
  -v "$PWD/output:/output" \
  -e GCP_PROJECT_ID=your-project-id \
  incident-automation gcp bootstrap
```

It creates `incident-automation-bootstrap@<project>.iam.gserviceaccount.com`,
grants it four roles, writes `output/gcp-bootstrap-key.json` and
`output/bootstrap.env`, then activates the new key and proves it can reach the
Storage API.

Everything afterwards is non-interactive, and reads the project and key from
`output/`:

```bash
podman run --rm -v "$PWD/output:/output" incident-automation gcp status
```

### Without gcloud on your machine

Drop the `~/.config/gcloud` mount and add `-it`. The container will print a
URL and a code for browser sign-in:

```bash
podman run --rm -it \
  -v "$PWD/output:/output" \
  -e GCP_PROJECT_ID=your-project-id \
  incident-automation gcp bootstrap
```

## What bootstrap creates

| Resource | Detail |
|---|---|
| Service account | `incident-automation-bootstrap` |
| Roles | `storage.admin`, `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `serviceusage.serviceUsageAdmin` |
| Key | `output/gcp-bootstrap-key.json`, mode 600 |
| Record | `output/bootstrap.env` |

Re-running is safe. An existing account is reused and an existing live key is
kept, so repeated runs do not accumulate credentials — service accounts cap at
ten keys, and an orphaned one is impossible to tell apart from the live one.

New IAM objects propagate through GCP subsystems independently, so bootstrap
retries on the three symptoms that means: `does not exist`, `invalid_grant` /
`Invalid JWT Signature`, and `PERMISSION_DENIED`. A run may pause for a few
seconds at those points on a fresh create.

## Environment

| Variable | Required | Default |
|---|---|---|
| `GCP_PROJECT_ID` | yes, for the first bootstrap | read from `output/bootstrap.env` afterwards |
| `GCP_CREDENTIALS_JSON` | no | read from `output/gcp-bootstrap-key.json`. Overrides it when set, for CI where there is no `/output` |
| `BOOTSTRAP_SA_NAME` | no | `incident-automation-bootstrap` |
| `HOST_OUTPUT_DIR` | no | `./output` — host path, so emitted files carry paths that resolve outside the container |

See `.env.example`.

## Resetting

`dev-reset.sh` undoes a bootstrap: removes the role bindings, deletes the
service account, and clears `output/`. It runs on your host with your own
gcloud, not in the container.

```bash
./dev-reset.sh        # prompts
./dev-reset.sh -y     # no prompt
```

Temporary — it goes away once `gcp destroy` exists.

## Layout

```
containers/   Containerfile and entrypoint
scripts/      the scripts each verb runs
output/       emitted key and record. gitignored
dev-reset.sh  host-side teardown, temporary
```

## Decisions

- **gcloud, not Terraform**, for the GCP phase. It is a handful of resources
  in a project you already own, and skipping Terraform removes a state file
  that has to survive between container runs.
- **Podman**, not Docker.
- **One container, verb subcommands** (`<noun> <verb>`), so later phases add
  verbs rather than images.
- **Bring your own GCP project.** Creating one needs billing and org
  permissions a personal account often lacks, and failures there have nothing
  to do with the demo.
- **Secrets passed as arguments**, never baked into the image. The one
  exception is bootstrap, which needs your own identity and so reads a mounted
  gcloud config or signs you in.
- **A scoped bootstrap account.** It cannot create itself — granting
  project-level roles needs permissions it deliberately does not have — so the
  first authentication is always human. Everything after runs as the scoped
  account.
