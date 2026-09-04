# noctalia-plugins

Plugins for the [Noctalia](https://github.com/noctalia-dev/noctalia) shell.

| Plugin | What it does |
| --- | --- |
| [`vpn-manager`](vpn-manager/) | NetworkManager VPN front end: connect, disconnect, import, and auto-connect when you leave a trusted network. |
| [`printer`](printer/) | CUPS printers and print queue in the bar, with a panel to set the default printer, cancel jobs and print the clipboard. |

## Install

Add this checkout as a plugin source, then enable what you want:

```sh
noctalia msg plugins source add andrewdems git https://github.com/AndrewDemsDS/noctalia-plugins
noctalia msg plugins enable andrewdems/vpn-manager
noctalia msg plugins enable andrewdems/printer
```

For local development, add the working copy as a `path` source instead. `.luau`
edits then hot-reload, and manifest changes are picked up on the next config
reload:

```sh
noctalia msg plugins source add dev path ~/dev/noctalia-plugins
```

## Development

`noctalia.d.luau` declares the whole plugin API for luau-lsp. It lives in
[official-plugins](https://github.com/noctalia-dev/official-plugins) and is
gitignored here rather than vendored:

```sh
curl -O https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau
```

Check a plugin against its manifest before committing:

```sh
noctalia plugins lint printer
```

## AI assistance

These plugins, and this README, were written with AI assistance. I run them on
my own desktop and tested what shipped.

## License

MIT, per plugin. See each plugin's `plugin.toml`.
