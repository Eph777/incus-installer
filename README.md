# incus-installer

A simple script to install or update [Incus](https://linuxcontainers.org/incus/) on Ubuntu, using the official [Zabbly](https://github.com/zabbly/incus) package repository.

## What it does

- Adds the Zabbly repository and its signing key
- Installs Incus if it isn't installed yet
- Updates Incus if it is already installed (and tells you whether a new version was installed)

It is safe to run more than once.

## Requirements

- Ubuntu 22.04 (Jammy) or 24.04 (Noble)
- Root access

## Usage

```bash
git clone https://github.com/<your-username>/incus-installer.git
cd incus-installer
sudo bash incus-installer.sh
```

After a fresh install, initialize Incus:

```bash
sudo incus admin init
```

Use `sudo incus admin init --minimal` to accept the defaults.

## Security

Incus is meant to be used with root privileges only. The script does not add any user to the `incus-admin` or `incus` groups, so normal users have no access to Incus. Use `sudo incus ...` or run commands as root.

## Updating

Run the script again:

```bash
sudo bash incus-installer.sh
```

Only Incus is upgraded; other system packages are left untouched. Running containers and VMs keep running during the update.
