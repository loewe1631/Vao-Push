# Vao Push

[中文](README.md)

Vao Push is a free, open-source, self-hosted notification and Home Screen data card system. Connect the iOS / iPadOS app to your own server, then send messages or structured data through HTTP, scripts, business systems, or the Web console.

Version 1.2 adds conditional card content, light/dark colors, state badges, system/HTTPS icons, sparklines, mini bars, borders and numeric affixes. Administrators can opt into bounded history accumulation per data source. New card capabilities require App 1.2; App Store availability is separate from this server/Web release. App 1.0/1.1 retains stable fallback layouts. See [the capability and compatibility guide](docs/card-design-v3.md).

## Server 1.2.0

- Named push lists with independent URLs, editable recipients, renaming and deletion. Existing default sending URLs keep working.
- Multiple widget-size layouts for one card and data source, with explicit editing, fixed previews and overflow warnings. Older apps keep using the default layout.
- Optional HTTPS message icons in API requests and the Web sender. Supporting clients display the avatar; older clients retain readable text notifications.
- Signed Web updates through an instance-bound local executor. Standard installation and in-place upgrades configure it automatically.
- Compatibility with the existing features of app 1.0.0. Upgrades retain account settings, devices, credentials, sending URLs, history and card subscriptions.

This release updates the server and Web UI. It does not announce a simultaneous iOS app release. Native size-specific layouts and notification avatars require a supporting client; iOS app updates continue through the App Store.

[Download Server 1.2.0](https://github.com/loewe1631/Vao-Push/releases/tag/v1.2.0) · [Installation and upgrades](deploy/PUBLIC-INSTALL.md) · [Website](https://push.vaovao.app/en/)

## New installation

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.2.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh
```

## Existing installation

**Do not reinstall or reset your data.** Run one in-place upgrade to retain configuration, passwords, devices and data while enabling Web updates:

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.2.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh --upgrade --prefix /opt/vao-push
```

Adjust `--prefix` for a custom installation directory. The upgrader backs up first, switches the program and verifies health and the running version. See the [installation guide](deploy/PUBLIC-INSTALL.md) for database recovery limitations. Later updates can be checked and confirmed under Server Settings. Unattended scheduled installation is not enabled by default.

## More features

Message history and notification detail navigation, multiple isolated servers, manual device selection, JSON/API data sources, visual card editing, JSON import, publication and subscription codes. AI-assisted design uses key-free prompts that users pass to their chosen model. Installation supports Chinese/English, separate API/Web ports, HTTP by IP, domain HTTPS, reverse proxies and custom certificates.

Source control does not contain Apple private keys or customer deployment credentials. Official prebuilt packages include this product's dedicated production APNs identity. Update manifests use a separate signing key; only its public key is distributed. Widget refreshes depend on system scheduling and push conditions, not a fixed once-per-minute guarantee.

## Documentation

- [Server 1.1.0 and compatibility](docs/server-1.1.md)
- [Simple onboarding](docs/simple-onboarding.md), [API](docs/api-v1.md), [OpenAPI](docs/openapi.json)
- [Card workbench](docs/card-studio-api.md), [Web card guide](docs/web-studio-guide.md)
- [Privacy](docs/privacy-data-flow.md), [third-party notices](THIRD_PARTY.md)

## Development

```sh
cd server && go test -race ./... && go vet ./...
cd ../web && npm ci && npm test && npm run build
cd ../ios/VaoPushCore && swift test
```

Use an isolated PostgreSQL database with `VAO_TEST_CONFIG`. Integration tests create per-test schemas; never point them at production. Optional network tests need explicitly configured isolated fixtures.

## License

The project source is licensed under [MIT](LICENSE). Third-party dependencies and assets retain their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md) and [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
