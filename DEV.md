# Developing claude-remote-dev

Notes for working on this repository itself. The user-facing runbook is
`README.md`; agent and contributor conventions are in `AGENTS.md`.

## If you are on Windows

The stub-driven tests (`tests/test-rd-*.sh`) run in Git Bash, but the real gate
is the smoke test on a throwaway Ubuntu VM (design doc §8). On Windows 11 Pro,
use **Hyper-V** for that VM rather than VirtualBox: when the Windows hypervisor
is already active (VBS / Memory Integrity, WSL2, Docker Desktop), VirtualBox
runs on top of it through the Windows Hypervisor Platform, which is slower and
less reliable. Hyper-V checkpoints also make "throwaway" cheap — revert to a
clean install before every `bootstrap-remote.sh` run.

Setup:

1. Enable Hyper-V from an elevated PowerShell, then reboot:
   `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`
2. Create the VM: Generation 2, 4 vCPU, 8 GB RAM, 60 GB disk, Ubuntu Server
   24.04 ISO. Under Security, set the Secure Boot template to **"Microsoft UEFI
   Certificate Authority"** — with the default Windows template Ubuntu will not
   boot.
3. In the Ubuntu installer, select **OpenSSH server**. Afterwards run
   `ssh-copy-id` and set `<VM_IP>` in `rd.env` to `<vmname>.mshome.net`.
4. Take a checkpoint of the clean VM.

Networking: the Hyper-V **Default Switch** is NAT, so it does not suffer from
the Wi-Fi bridging throughput problem described in `AGENTS.md`. Its IP address
changes when the host reboots, which is why `rd.env` should use the
`<vmname>.mshome.net` name rather than an address.
