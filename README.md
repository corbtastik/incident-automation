# incident-automation

Provisioning for the Incident Demo, delivered as a container so nobody has to
install cloud tooling locally.

The intended audience is MongoDB Solution Architects, who each stand up their
own environment rather than sharing a hosted one.

## What this owns, and what it does not

**This project provisions infrastructure.** In GCP: a bucket and the identity
that reads it. In Atlas: a cluster, dedicated search nodes, a database user,
and a stream processing instance with its connections.

**The demo apps own the data model** — collections, Atlas Search and Vector
Search indexes, and the stream processors. Those are coupled to the shape of
the documents the apps write, so they version with the apps rather than with a
provisioning tool. The simulator creates them at startup.

The handoff between the two is `output/simulator.env` and
`output/visualizer.env`.

## Commands

| Command | What it does |
|---|---|
| `all setup` | GCP + Atlas + app configuration, in one command |
| `all status` | Report both sides |
| `all destroy` | Tear down both sides |
| `gcp setup` | `bootstrap` + `apply` |
| `gcp bootstrap` | Create the automation service account, grant roles, issue a key |
| `gcp apply` | Media bucket, runtime service account, bucket-scoped role and key |
| `gcp status` | Report GCP state — bucket, runtime identity, binding |
| `gcp validate` | Activate the runtime key and read the bucket as that identity |
| `gcp destroy` | Delete the bucket and runtime account |
| `gcp teardown` | Delete the bootstrap account. Run after `destroy` |
| `atlas status` | Report Atlas project state |
| `atlas infra apply` | Cluster, search nodes, db user, access list, stream instance, connections |
| `atlas infra validate` | Connect with the recorded URI and check the infrastructure |
| `atlas infra destroy` | Delete them |
| `env write` | Write the app configuration files from whatever is provisioned |

`apply`, `setup` and `destroy` take `--yes` and `--dry-run`. Everything named
`status` or `validate` changes nothing.

## Prerequisites

1. A GCP account and a project you own. Setup does not create the project.
2. Billing enabled on it.
3. An Atlas account, organisation, and project.
4. An Atlas **organisation API key**, created in the UI, with your project on
   its API access list. There is no way to mint the first one, so this is
   always supplied by you.
5. Podman.

The Cloud Storage and IAM APIs are turned on for you. `gcloud` on your machine
is optional — if it is installed and authenticated, mount its config; if not,
`gcp bootstrap` signs you in interactively.

## Configuration

Values can come from the command line or a file:

```bash
podman run --rm --env-file .env ...                    # read by podman
podman run --rm -v "$PWD/.env:/config/.env:ro" ...     # read by the container
```

Precedence is explicit `-e`, then the file, then values recorded by earlier
runs in `output/`, then defaults. `--env-file` cannot carry multi-line values,
so `GCP_CREDENTIALS_JSON` belongs on the command line — it is read from
`output/` anyway. Copy `.env.example` to `.env`; it is gitignored.

## Run it

```bash
podman build -f containers/Containerfile -t incident-automation .
mkdir -p output

podman run --rm \
  -v ~/.config/gcloud:/gcloud-host:ro \
  -v "$PWD/.env:/config/.env:ro" \
  -v "$PWD/output:/output" \
  incident-automation all setup
```

Roughly 25 minutes, nearly all of it Atlas — a cluster takes around 15 and its
search nodes another 9. Progress is printed every 15 seconds.

Without gcloud on your machine, drop the `~/.config/gcloud` mount and add
`-it` for the interactive sign-in.

Then check it:

```bash
podman run --rm -v "$PWD/.env:/config/.env:ro" -v "$PWD/output:/output" \
  incident-automation all status
```

## What it creates

**GCP**

| Resource | Detail |
|---|---|
| Bootstrap service account | `incident-automation-bootstrap`, with `storage.admin`, `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `serviceusage.serviceUsageAdmin` |
| Bucket | `<base>-<slug>`, uniform access, public access prevented, labelled `managed-by=incident-automation` |
| Runtime service account | `incident-app-storage-<slug>`, with `roles/storage.objectViewer` **on the bucket only** |

Two accounts, not one. The bootstrap account administers; the runtime account
is what the apps authenticate as, and it can do nothing but read objects from
its own bucket.

**Atlas**

| Resource | Detail |
|---|---|
| Cluster | `incident-<slug>`, M10 by default, tagged `managed-by=incident-automation` |
| Search nodes | Dedicated, 2 × S20_HIGHCPU_NVME by default |
| Database user | `incident-<slug>`, generated password |
| Access list | `0.0.0.0/0` |
| Stream instance | `incident-<slug>-spi`, SP30 by default |
| Connections | `incident-events` and `fix-events` |

The connection names are fixed rather than configurable: the pipelines
reference them by name, so a configurable name would produce processors that
never start.

Both sides use a generated slug. Bucket names are globally unique, so a fixed
name would collide for the second person to run this; the slug doubles as an
instance id, letting two demos coexist in one project. Because the name cannot
be recomputed from inputs, resources are labelled or named so `status`,
`validate` and `destroy` rediscover them even if `output/` is lost.

## Output

| File | Purpose |
|---|---|
| `simulator.env` | Copy to the simulator's config location |
| `visualizer.env` | Copy to the visualizer's config location |
| `incident-app-storage-key.json` | The runtime credential both apps use |
| `gcp.env`, `atlas.env` | Automation's own records |
| `gcp-bootstrap-key.json`, `gcp-runtime-key.json` | Automation's own credentials |

The two app files are written separately rather than as one shared file: both
apps read `PORT` with different defaults, so a single file would put one of
them on the wrong port.

**`GOOGLE_APPLICATION_CREDENTIALS` is deliberately left commented out.** Place
`incident-app-storage-key.json` wherever you keep app config and set the full
path yourself. A relative path resolves from the app's working directory, not
from the `.env` file, so an absolute path is the safe choice.

Any value that could not be filled in — because only one half has been
provisioned — is emitted commented out rather than as an empty string, and
`env write` exits non-zero listing what is missing. An empty value looks
configured and fails obscurely; an absent one does not.

## Environment

| Variable | Required | Default |
|---|---|---|
| `GCP_PROJECT_ID` | yes | — |
| `GCS_BUCKET_BASE_NAME` | for `apply` | — Max 56 characters, lowercase |
| `ATLAS_PUBLIC_KEY` | for `atlas` | — |
| `ATLAS_PRIVATE_KEY` | for `atlas` | — |
| `ATLAS_PROJECT_ID` | for `atlas` | — |
| `ATLAS_MODEL_API_KEY` | no | — Passed through to the app files |
| `GCS_LOCATION` | no | `us-central1` |
| `ATLAS_PROVIDER` / `ATLAS_REGION` | no | `GCP` / `CENTRAL_US` |
| `ATLAS_CLUSTER_TIER` | no | `M10` |
| `ATLAS_SEARCH_NODE_SIZE` / `_COUNT` | no | `S20_HIGHCPU_NVME` / `2` |
| `ATLAS_SPI_PROVIDER` / `ATLAS_SPI_REGION` / `ATLAS_SPI_TIER` | no | `GCP` / `US_CENTRAL1` / `SP30` |
| `GCP_INSTANCE_SLUG` / `ATLAS_INSTANCE_SLUG` | no | generated |
| `HOST_OUTPUT_DIR` | no | `./output` |
| `SKIP_API_ENABLE` | no | `false` |

Note the Atlas region naming differs between the two services: a cluster in
`CENTRAL_US` pairs with a stream instance in `US_CENTRAL1`.

## Re-running

Every verb is idempotent. An existing account, bucket, cluster, binding or
live key is reused rather than recreated. Key reuse matters more than it
looks: `keys create` mints a new credential on every call, accounts cap at
ten, and an orphaned key is impossible to tell apart from the live one.

New IAM and storage objects propagate through GCP subsystems independently, so
calls retry on the three symptoms that produces — `does not exist`,
`invalid_grant` / `Invalid JWT Signature`, and `PERMISSION_DENIED`. Atlas
capacity failures are handled separately and break out immediately naming the
provider and region, because a region that cannot take the tier is a real
failure to act on rather than something to retry through.

## Tearing down

```bash
podman run --rm -v "$PWD/.env:/config/.env:ro" -v "$PWD/output:/output" \
  incident-automation all destroy --dry-run     # review first

podman run --rm -v "$PWD/.env:/config/.env:ro" -v "$PWD/output:/output" \
  incident-automation all destroy --yes
```

`--dry-run` itemises what will be removed and what will be kept, including any
clusters or stream instances in the project that are **not** ours, named
explicitly so you can see your own work is out of scope. Nothing untagged is
ever deleted.

The bootstrap service account survives `all destroy`; remove it with
`gcp teardown` when you are finished entirely. `gcp teardown` refuses while a
bucket still exists, because `destroy` runs as that account.

Left in place deliberately: enabled GCP APIs, and the Atlas `0.0.0.0/0` access
list entry. Both are project-wide and may predate this tool.

## Layout

```
containers/   Containerfile and entrypoint
scripts/      common.sh plus one script per verb
output/       emitted configuration, keys and records. gitignored
```

## Not done yet

- Publishing the image, so users do not have to build it

## Decisions

- **CLI tools, not Terraform.** These are a handful of resources in projects
  you already own, and skipping Terraform removes a state file that would have
  to survive between container runs. Resources are found by label or name
  instead. `atlas api` is a passthrough over the whole Administration API, so
  anything without a first-class command — the stream processors — is still
  reachable from the same binary with the same credentials.
- **Podman**, not Docker.
- **One container, verb subcommands**, so later work adds verbs, not images.
- **Bring your own projects.** Creating them needs billing and organisation
  permissions a personal account often lacks, and failures there have nothing
  to do with the demo.
- **Secrets passed as arguments**, never baked into the image. The exception is
  `gcp bootstrap` and `gcp teardown`, which need your own identity and so read
  a mounted gcloud config or sign you in.
- **A privilege ladder.** You create the bootstrap account; it creates the
  runtime account; the runtime account can only read one bucket. The bootstrap
  account cannot create itself, because granting project-level roles needs
  permissions it deliberately does not have.
- **Base image is `gcr.io/google.com/cloudsdktool/google-cloud-cli`**, not the
  legacy `docker.io/google/cloud-sdk` mirror, which is amd64-only and forces
  emulation on Apple Silicon.
- **mongosh is in the image** because the data plane needs it — no Atlas API
  creates a collection, and `atlas infra validate` proves the connection
  string works rather than trusting that the control plane said so.
