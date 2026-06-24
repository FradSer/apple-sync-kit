# Headless / systemd Deployment

Shell profiles (`~/.bashrc`, `~/.zshrc`) only affect interactive shells. If
`note` or `event` runs inside a systemd-managed service (e.g. an agent
gateway), the service process inherits **none** of those exports. Credentials
must be supplied via a systemd `EnvironmentFile` drop-in instead.

## Quick start (recommended)

Use the bundled [`deploy-systemd.sh`](deploy-systemd.sh). It writes the env file
(mode `0600`), adds the drop-in, reloads, restarts the service, and verifies the
variables landed in the running process — idempotently, so it is safe to re-run.
Credentials are read from the environment (never argv, so they never leak to
`ps`):

```bash
# note — for event, swap in the EVENT_* vars and `event`
NOTE_SYNC_API_URL=https://<worker>.workers.dev \
NOTE_SYNC_API_TOKEN=<token> \
NOTE_ENCRYPTION_KEY=<base64 key> \
  ./deploy-systemd.sh note <service>      # e.g. openclaw-gateway
```

`<PREFIX>_SYNC_DEVICE_ID` is optional and defaults to the short hostname.

| CLI | env prefix | config namespace |
|-----|-----------|------------------|
| `note`  | `NOTE_`  | `note-sync`  |
| `event` | `EVENT_` | `event-sync` |

To redeploy on a host that is already configured, source the existing env file
first:

```bash
set -a; . ~/.config/note-sync/env.conf; set +a
./deploy-systemd.sh note openclaw-gateway
```

## Manual steps (fallback)

If you cannot run the script, replicate it by hand. Replace `<namespace>` /
`<PREFIX>` per the table above.

1. Write the sync vars to a dedicated env file (mode `0600`):

   ```bash
   mkdir -p ~/.config/<namespace>
   cat > ~/.config/<namespace>/env.conf << 'EOF'
   <PREFIX>_SYNC_API_URL=https://<your-worker>.workers.dev
   <PREFIX>_SYNC_API_TOKEN=<token>
   <PREFIX>_ENCRYPTION_KEY=<base64 key>
   <PREFIX>_SYNC_DEVICE_ID=<hostname>
   EOF
   chmod 600 ~/.config/<namespace>/env.conf
   ```

2. Add an `EnvironmentFile` drop-in to the service unit:

   ```bash
   mkdir -p ~/.config/systemd/user/<service>.service.d
   cat > ~/.config/systemd/user/<service>.service.d/<namespace>.conf << 'EOF'
   [Service]
   EnvironmentFile=/home/<user>/.config/<namespace>/env.conf
   EOF
   systemctl --user daemon-reload
   systemctl --user restart <service>
   ```

3. Verify the vars are loaded into the running process:

   ```bash
   pid=$(systemctl --user show -p MainPID --value <service>)
   tr '\0' '\n' < /proc/$pid/environ | grep <PREFIX>_
   ```
