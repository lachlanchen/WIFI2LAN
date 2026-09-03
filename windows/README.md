# Windows support tools

These utilities support isolated router provisioning and recovery. Run them
from an elevated PowerShell only when changing an adapter or firewall rule.

## Temporary TL-WR802N management route

`wr802n-management.ps1` assigns a host-only address and `/32` route to one
wired adapter without changing another adapter's default route:

```powershell
.\wr802n-management.ps1 Enable `
  -InterfaceAlias 'Ethernet 2' `
  -ExpectedMacAddress '<adapter-mac>'

.\wr802n-management.ps1 RestoreDhcp `
  -InterfaceAlias 'Ethernet 2' `
  -ExpectedMacAddress '<adapter-mac>'
```

Supplying `-ExpectedMacAddress` is recommended when several USB adapters are
present. The script refuses to touch a different adapter when that guard is
set. The default management and TFTP addresses match the TL-WR802N v1 stock
and U-Boot recovery networks.

## Locked-down WR802N recovery TFTP

`wr802n_tftp_server.py` serves one checksum-verified factory image to one
expected recovery client. It rejects other clients and filenames, binds to a
specific local address, uses conservative 512-byte blocks, and exits after a
successful transfer:

```powershell
python .\wr802n_tftp_server.py `
  --image '<factory-image.bin>' `
  --sha256 '<expected-sha256>'
```

The server also verifies the TL-WR802N v1 image size and hardware header.
Firmware images are deliberately excluded from this repository.

## Optional SRun captive-portal login

`srun-portal-login.py` authenticates the IPv4 address assigned to a router's
Wi-Fi WAN. It implements the portal's challenge, XXTEA/SRBX1 encoding, and
checksum locally. The password is prompted without echo by default and is
never written to disk:

```powershell
python .\srun-portal-login.py `
  --portal 'http://<portal-address>' `
  --username '<account>' `
  --client-ip '<router-wan-ip>' `
  --ac-id '<controller-id>' `
  --interface '<windows-address-on-router-lan>'
```

`--password-env NAME` is available for unattended local automation, but the
environment variable must be created outside version control and cleared
after use. No portal address, account, password, SSID, or client identity is
stored in this repository.
