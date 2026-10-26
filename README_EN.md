# Vao Push

[中文](README.md)

Vao Push is a free, open-source, self-hosted message delivery and Home Screen data card system. Deploy the server on your own machine, connect to it from the iOS / iPadOS app, and send messages or structured data through HTTP, scripts, business systems, or the Web console.

## Features

- **Notifications**: Store message history, deliver notifications to registered devices, and open the target message details when a notification is tapped.
- **Home Screen data cards**: Keep data sources, latest state, and card layouts separate so one data source can power multiple cards.
- **Web workbench**: Create data sources, configure fields, design cards visually, import JSON drafts, publish cards, and manage subscriptions.
- **AI-assisted design**: Copy a key-free generation prompt to a model of your choice, then import the returned JSON draft into the workbench.
- **Self-hosted deployment**: The installer supports Chinese and English, separate API/Web ports, direct HTTP by IP, domain HTTPS, reverse proxies, and operator-provided certificates.

## Release status

Server 1.0.0 provides public release packages for Linux amd64 and arm64, with production APNs configured automatically during installation. The iOS / iPadOS client 1.0.0 has been submitted to App Store Review; documentation and support are available at [push.vaovao.app](https://push.vaovao.app). No Apple private key or user deployment credential is included in source control. Widget refresh timing depends on system scheduling and push conditions; Vao Push does not promise a fixed once-per-minute refresh rate.

[Download Server 1.0.0](https://github.com/loewe1631/Vao-Push/releases/tag/v1.0.0) · [Installation guide](deploy/PUBLIC-INSTALL.md) · [Website & Support](https://push.vaovao.app/en/)

## Quick links

- [Simple onboarding](docs/simple-onboarding.md)
- [API protocol](docs/api-v1.md)
- [Card workbench](docs/card-studio-api.md)
- [Web card guide](docs/web-studio-guide.md)
- [Server installation](deploy/PUBLIC-INSTALL.md)
- [Privacy and data flow](docs/privacy-data-flow.md)
- [Third-party dependencies and notices](THIRD_PARTY.md)

## Repository layout

~~~text
ios/        iOS app, notification extension, Widget, and shared core
server/     Go server, PostgreSQL schema, and delivery worker
web/        Vue 3 / TypeScript Web console
deploy/     Installation, upgrade, backup, and restore tools
docs/       API, card, privacy, and deployment documentation
examples/   Request and card examples without real credentials
~~~

## Development checks

Server:

~~~sh
cd server
go test -race ./...
go vet ./...
~~~

Web:

~~~sh
cd web
npm ci
npm test
npm run build
~~~

iOS shared core:

~~~sh
cd ios/VaoPushCore
swift test
~~~

## License

The project source is licensed under the [MIT License](LICENSE). Third-party dependencies and assets retain their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md) and [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
