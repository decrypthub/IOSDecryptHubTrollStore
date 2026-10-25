# IOSDecryptHub

<div align="right">
  <a href="./README.md">中文</a> | <b>English</b>
</div>

IOSDecryptHub is a runtime-analysis dylib injected into iOS app processes. It captures cryptography, file, network, Keychain and dynamic-loading behavior, and ships a web panel, decryption (dumping) and MCP analysis capabilities.

For the full feature set and a live demo, visit: [ios.decrypthub.com](https://ios.decrypthub.com/)

## Separate Projects

This repository maintains the largely settled **TrollStore edition**, focusing on compatibility, stability and its existing injection / web / MCP workflows.

The Jailbreak edition is now the independent [IOSDecryptHubJB](https://github.com/taisuii/IOSDecryptHubJB) project: a complete deb with a persistent phone daemon, Manager UI, loader and Agent, with per-app injection controls, APT updates, Inline Hook and Trace planned.

Each project maintains its own main branch, versions and releases. The historical jailbreak branch is retained for reference, not active product development. Port applicable fixes explicitly.

The new Jailbreak package and advanced features are not implemented yet. See its [product architecture](https://github.com/taisuii/IOSDecryptHubJB/blob/main/docs/PRODUCT_ARCHITECTURE.md).

## Getting the dylib

Download `decrypt_helper.dylib` from [GitHub Releases](https://github.com/taisuii/IOSDecryptHub/releases), or build it yourself:

```bash
make
```

The build artifact is placed at the project root: `decrypt_helper.dylib`.

## Usage

### Option 1: TrollStore Injector (Recommended)

For devices that already have a TrollStore-based injector installed:

1. Select the target app in the injector.
2. Add `decrypt_helper.dylib` and run the injection.
3. Launch the target app.
4. Open `http://<device IP>:8088` in a browser on the same LAN.

Injector UIs vary slightly, but the core operation is always: inject the dylib into the target app, then relaunch the app.

### Option 2: IPA Repackaging

On macOS, first install `insert_dylib`:

```bash
brew install insert_dylib
```

Run the script bundled with the repo:

```bash
./scripts/inject.sh <input.ipa> decrypt_helper.dylib
```

The script produces `hooked_<input>.ipa`. Install / re-sign it with TrollStore, Sideloadly or AltStore, launch the app, then visit:

```text
http://<device IP>:8088
```

### Option 3: TrollStore Manager App

Build and install the dedicated manager IPA:

```bash
make ipa
```

The artifact is placed under `build/trollstore/`. Once installed via TrollStore, you can select the target app and inject directly from within the app.

### PC Connection & MCP Gateway

Install `idh` on your computer and connect to the device manually (the device IP is shown in the app panel or obtained from your LAN):

```bash
pip install ios-decrypt-hub
idh connect <device IP>:8088
idh mcp
```

`idh mcp` converts the device's HTTP MCP into a local stdio MCP, usable as a fixed MCP configuration for clients such as Codex and Claude. `connect` saves the device as a persistent connection; afterwards `devices` / `watch` / `open` / `mcp` use it directly. You can also pass `--endpoint http://<device IP>:8088` for a one-off connection.

## Build Variants

| Variant | Command | Purpose |
|---------|---------|---------|
| dev (default) | `make` | Manual injection / local debugging for developers |
| trollstore | `make VARIANT=trollstore` | TrollStore injector / manager IPA |

### Jailbreak Edition

Complete deb builds, installation and APT updates belong to [IOSDecryptHubJB](https://github.com/taisuii/IOSDecryptHubJB). Historical rootless / deb entries here remain for legacy reference.

## Notes

- The web and MCP services listen on `0.0.0.0:8088` by default with no authentication — use them on trusted networks only.
- Injection, re-signing and decryption capabilities depend on the device environment and the target app's protections.
- Do not post captured keys, passwords, plaintext or other sensitive data to public issues.

Report problems via [GitHub Issues](https://github.com/taisuii/IOSDecryptHub/issues/new/choose).

## License

[MIT](./LICENSE)

Vendored [fishhook](https://github.com/facebook/fishhook) and [Capstone](https://www.capstone-engine.org/) (both BSD-3-Clause); see [NOTICE](./NOTICE).
