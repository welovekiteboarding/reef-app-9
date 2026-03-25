# Linear Setup For reef-app-9

## Team

- team name: `ReefApp9`
- team key: `RA9`
- GitHub repo: `welovekiteboarding/reef-app-9`

## Workflow States

- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Done`

## Environment Checklist

- set `LINEAR_API_KEY`
- confirm GitHub auth for `gh`
- confirm Codex is installed and available on the path

## Create The First Proof Issue

Create the first proof issue in Linear with:

- state: `Todo`
- title: `Create deterministic live-proof artifact`
- description: `Add a new file at docs/live-proof-setup-run-merge.md with a short note that this issue proves the fresh two-part startup plus queue and merge path.`

## Manual Notes

- `mix symphony.setup` will create the first proof issue through the Linear API after team and workflow bootstrap succeeds
- GitHub repo creation can be automated by `mix symphony.scaffold ... --github`
- run one queue cycle with `mix symphony.run --once`
- run the foreground queue with `mix symphony.run`
