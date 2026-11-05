# onward-bootstrap

Shared setup for the Onward Logistics labs. Every lab's infrastructure lives in its own
repository and is deployed by CloudFormation Git sync. This repository holds what has to exist
before Git sync can run, and the scripts that build or remove a lab in the right order.

## What it creates

| Stack | Scope | What it holds |
|---|---|---|
| `onward-dev-github-connection` | account, once | CodeConnections connection to GitHub (approved once in the console) |
| `onward-github-oidc` | account, once | GitHub Actions OIDC identity provider, so workflows use short-lived credentials instead of access keys. An existing provider is imported, never recreated, and is kept if the stack is deleted |
| `onward-dev-settings` | account, once | SSM parameter with the budget alert email (kept out of Git) |
| `onward-dev-budget` | account, once | Monthly cost budget with email alerts |
| `onward-dev-<lab>-<layer>` | per lab | Placeholder that Git sync replaces with the lab's real stack |
| `onward-dev-<lab>-git-sync` | per lab | Repository link, Git sync role (managed policies only) and one sync config per layer |

## How a lab plugs in

A lab repository has:

- `lab.env`, for example:
  ```bash
  LAB=delivery
  LAYERS=(network security registry service pipeline)
  ```
- `infra/<layer>/template.yaml` and `infra/<layer>/deployment.yaml` for each layer (up to 5).
- Optional hooks: `scripts/hooks/before-<layer>.sh` runs just before that layer is synced, and
  `scripts/hooks/before-teardown.sh` runs before the lab is deleted.

## Build or rebuild a lab

```bash
./deploy.sh ../<lab repo>                                  # usual run
BUDGET_EMAIL=you@example.com ./deploy.sh ../<lab repo>     # first run in an account
```

The script is safe to re-run. It:

1. Creates the GitHub connection if it is missing, and stops until it has been approved in the
   console (Developer Tools > Settings > Connections).
2. Imports or creates the GitHub OIDC provider.
3. Stores the budget email (when given) and deploys the budget.
4. Creates a placeholder stack for each layer.
5. Enables Git sync one layer at a time, waiting for each stack before the next, because later
   layers import earlier layers' outputs.

Git sync remembers the last commit it deployed to each stack name, even after the stack is
deleted. On a rebuild nothing would deploy until a push changed the layer's files, so when Git
sync reports "Nothing to sync" the script pushes a timestamp line to that layer's
`deployment.yaml` (commit `chore: trigger git sync for <layer>`).

## Remove a lab

```bash
./teardown.sh ../<lab repo>
```

Deletes the lab's stacks in reverse order and its Git sync stack. The account setup stays, so the
next `deploy.sh` needs no console step.
