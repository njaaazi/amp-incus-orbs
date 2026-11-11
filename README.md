# amp-incus-orbs

Runs [Amp](https://ampcode.com) self-hosted Orbs as Incus system containers, one container per Orb.

There's no official Incus example. This uses Amp's documented [dispatch program contract](https://ampcode.com/docs/orbs/self-hosted): Amp sends the provider a job, and `dispatch.sh` turns it into Incus commands.

**Status: experimental.** See [Known gaps](#known-gaps) before relying on it.

## How it works

```
Amp  <--outbound HTTPS only--  amp orb provider  -->  dispatch.sh  -->  Incus
                                                                         ├─ project "default"  (your other VMs and containers)
                                                                         └─ project "orbs"     (amp-* containers)
```

| Amp job | What `dispatch.sh` does |
|---|---|
| `spawn` | Creates or starts the container, waits for DNS, then starts `amp orb bootstrap` |
| `pause` | Removes the token, stops the container and saves a snapshot copy if Amp asks |
| `delete` | Removes the container |

Safeguards:

- The script only uses the `orbs` project and refuses any name that doesn't start with `amp-`.
- Each Orb has a memory limit, set by `ORB_MEMORY` in `setup/setup-incus.sh` (default 2 GiB).
- `MAX_RUNNING_ORBS` limits how many run at once (default 2).

## Setup

On a Debian 13 machine or VM:

```bash
sudo PROVIDER_USER=debian ./setup/setup-incus.sh
```

In Amp, go to **Settings → Orbs → Add Provider** and copy the `aop_live_` token. Then run:

```bash
sudo set-amp-token
```

Then lock it down, which also adds the daily cleanup:

```bash
sudo ./setup/lock-down.sh
```

It stops Orbs reaching private networks, runs the provider as an `amp-orb` account limited to the `orbs` project, and blocks privileged containers there. `set-amp-token` prints `ACCEPTED`, `REJECTED` or `FAILED`. To use it, start a thread and choose your provider under **Orb → Self-Hosted**.

The service isn't enabled at boot. To turn that on, run `sudo systemctl enable amp-orb-provider`.

## Custom Orb types

By default every Orb starts from `amp-orb-base`: Debian 13 with Amp, git, Node and a few tools. A project that needs more, such as a database with data already loaded, can have its own Orb type with its own image. Each thread gets an instant copy of that image, so its changes stay in that thread.

A type is a file on the host at `/etc/amp-orbs/types/<type>.conf`:

```bash
IMAGE=amp-orb-mariadb           # the image new Orbs of this type start from
MEMORY=3GiB                     # optional, replaces the default per-Orb limit
READY_CMD="mariadb-admin ping"  # optional, must succeed inside the Orb before Amp starts work
```

Type names use lowercase letters, digits and hyphens, up to 21 characters. A thread asking for a type with no file gets the base image.

To add one, using the MariaDB example in [`examples/mariadb`](examples/mariadb):

1. Build the image. Stdin goes to the provision script, here a SQL dump to load:
   ```bash
   sudo ORB_BUILD_DB_NAME=app ./setup/build-image.sh amp-orb-mariadb \
     examples/mariadb/provision.sh examples/mariadb/AGENTS.md < dump.sql
   ```
   The provision script runs as root inside a copy of the base image. Variables named `ORB_BUILD_*` are passed to it. The optional AGENTS.md becomes the Orb user's global Amp instructions.
2. Install the type:
   ```bash
   sudo install -D -m 644 examples/mariadb/mariadb.conf /etc/amp-orbs/types/mariadb.conf
   ```
3. In Amp, add `standard` and `mariadb` to the provider's Orb types, with `standard` as the default. In the project that needs it, set your provider and `mariadb` as the Default Orb.

Run `build-image.sh` again to refresh the data. New threads get the new image, and existing threads keep their copy. Snapshots are kept per type, so a thread never resumes from another type's copy.

Only load data you're happy to have in every thread's copy. For production data, anonymize it first.

## Measured results

From one test on a Debian 13 VM with 3 GB of RAM and a 1 GiB limit per Orb, running one real Amp thread.

| Measurement | Result |
|---|---|
| `spawn`, from Amp | about 0.9 s |
| `pause` with a snapshot, from Amp | about 1.3 s |
| RAM while idle (mostly the two `amp` processes) | about 210 MB |
| RAM after the task (334 MB of it file cache) | about 525 MB |
| Peak RAM during the task, including file cache | 975 MB, no processes killed |
| Paused Orb | stopped, so no RAM |

RAM use depends on your project. Heavier builds will need a higher limit.

## Lessons learned

- `incus init`, `launch` and `project create` wait for YAML on stdin when it isn't a terminal, which looks like a hang. Close stdin.
- `limits.memory` on a project counts stopped instances, so paused Orbs and snapshots use up the allowance. Limit each Orb instead, and limit how many run.
- Amp pauses and restarts an Orb to save a snapshot. Bootstrap exits straight away if DNS isn't ready after the restart, so wait for DNS first.

## Known gaps

- `setup-incus.sh` was built from steps run by hand and rerun on an already configured VM. It hasn't been run from start to finish on a fresh machine.
- The daily cleanup removes stopped Orbs unused for 30 days and snapshots older than 14. A removed Orb's thread starts fresh on its next message, so uncommitted work in it is lost. Change this with `ORB_CLEANUP_ORB_DAYS` and `ORB_CLEANUP_SNAPSHOT_DAYS`.
- A paused Orb loses running processes. Files survive.
- Deleting a thread's Orb hasn't been confirmed from Amp. That job was only run by hand.
- Orbs can't reach private addresses, so a self-hosted Git server or service on your network would need its own ACL rule. They can still reach the public internet.
