# Required deployment workflow

After any change that affects the application, run `./deploy.sh` before reporting completion. Do not ask the user to rebuild, reinstall, restart, or verify which copy is running.

Completion requires all of the following:

- The release build succeeds.
- The local bundle passes `--selftest`.
- `/Applications/MyTimer.app` is replaced with the local bundle.
- The installed and local executable hashes match.
- Only the installed executable is launched.
- The installed bundle passes `--selftest`.

Never treat launching `MyTimer.app` from the repository as a completed deployment. The login item points to `/Applications/MyTimer.app` and can relaunch a stale installed copy.
