# Dune Self-Hosted Linux

CURRENT STATUS: Everything works, server stable.  Additional functionality added to work with https://github.com/adainrivers/dune-dedicated-server-manager
Linux-native tooling for running the Dune: Awakening self-hosted server
distribution without the packaged Windows Hyper-V VM.

This project recreates the useful pieces of Funcom's shipped Linux guest on a
regular systemd Linux host: k3s, the Funcom operator resources, downloaded
server assets, world creation, backup/restore checks, firewall hardening, and
teardown.

See [linux/README.md](linux/README.md) for setup, operations, backup, restore,
firewall, and teardown documentation.

## Important

This repository is intended to contain only the Linux conversion tooling. It
does not include Funcom or Steam-downloaded server files; those are downloaded
at setup time and ignored by git.
