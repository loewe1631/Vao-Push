# Server 1.1.0

Server 1.1.0 adds named push lists, per-message notification icons, card layouts for different widget sizes, and an optional local Web update executor. The existing `/v1` protocol remains supported. Server release availability does not imply that a new iOS app version is already available. The shared `VaoPush` Xcode scheme supports building the app together with both extensions; development signing does not imply App Store distribution approval.

## Named push lists

The existing `GET/PUT /v1/message-route` and its sending URL retain their behavior. Named lists use `GET/POST /v1/message-routes` and `PUT/DELETE /v1/message-routes/{id}`. Administrators send `{ "name": "Operations", "device_ids": [] }` to create or edit a list. Edits and deletion require `If-Match: "route-{revision}"`. Editing retains the URL; deletion revokes only that list's sending key. Empty lists send to nobody. Each accepted send freezes its recipients, and retries are isolated between named lists. The Web Messages page can temporarily load a named list without changing saved membership.

## Notification icons

Messages accept an optional HTTPS `icon` URL. It is preserved in history and the existing version-1 push envelope. Old clients continue displaying the original title and body. A supporting client uses communication-notification APIs to display the image as an avatar. Images are bounded by byte size, decoded dimensions, timeout and cache count, and never receive server credentials. A missing or invalid image falls back to the original notification. The capability and signed physical-device behavior require separate verification.

## Layout variants

Design schema 1 remains valid. Schema 2 adds optional `layouts.small`, `layouts.medium`, `layouts.large` and `layouts.extraLarge` node trees, with required `layout` as the fallback. Each tree retains the v1 limits of 24 KiB, 64 nodes and depth 6; the complete document is limited to 64 KiB. Node IDs are unique within each tree. Default and variant bindings are validated at publication. Empty item collections do not invent sample values.

Supporting readers request `X-Vao-Card-Schema: 2`. Readers without this header receive a v1 projection of the published default layout, using the same publication revision and source snapshot. All layouts publish together. New clients handle a v1-to-v2 cache transition at the same revision and retain local adjustments. New adjustments can be scoped to widget size. A conflict preserves the existing local design instead of silently discarding user settings.

The Web designer explicitly copies a layout into a size override and can restore use of the default. Its preview uses a fixed canvas and warns about overflow. Importing a v1 layout into an existing multi-layout card confirms the editing scope and retains other layouts. Browser previews are advisory; native widget sizes still require physical-device acceptance.

## Web updates

`GET /v1/system/update`, `POST /v1/system/update/check`, and `POST /v1/system/update/install` require an administrator session; writes retain Origin/CSRF validation. Install requests contain the pinned `release_id` returned by checking, plus `confirm: true`.

The business server talks to a separate local executor through a protected Unix socket. Official installations and standard in-place upgrades configure the local executor automatically. The executor verifies an Ed25519-signed release manifest, package digest, architecture, version and migration/client compatibility. Downloads and redirects are restricted to operator-approved hosts. The normal Web service does not receive root or arbitrary-command privileges. CLI and Web upgrades share a per-instance lock. Tasks survive browser disconnects and record interruption instead of silently restarting a version switch.

An existing installation can bootstrap Web updates with the official installer’s `--upgrade` option. It upgrades in place without recreating accounts, bindings, push URLs, or data. Fresh official installations enable the executor during installation. Later updates can be checked and confirmed from Server Settings. Advanced operators can configure a custom trusted feed using `deploy/install-update-agent.py`; custom feed settings and pinned keys are preserved during subsequent upgrades.

Release maintainers use `deploy/sign-update-feed.py` with an offline signing key. A feed envelope has base64 `manifest` and `signature`; the signed manifest has `schema_version: 1` and a `releases` array. Each release declares `version`, `arch`, `url`, `sha256`, `size`, `min_server_version`, `min_app_version`, `backward_compatible`, `database_compatible`, and `notes`. Client compatibility with 1.0.0 must be declared and tested before offering an upgrade. Test-only feeds and keys are not official production trust material.

An upgrade verifies and stages the package, backs up the database and installation configuration, switches the program, and verifies health and the running target version. A failed compatible upgrade restores the old program; it does not automatically reverse database migrations. Destructive migrations are not offered by this initial workflow. Future persistent media must be added to the consistent backup contract before a media feature can use it. iOS applications continue updating through the App Store.

## Acceptance boundary

Backend PostgreSQL integration, Web build/tests, signed-feed verification, service upgrades and program rollback, old-client protocol checks, shared Swift tests, iOS builds, and physical-device notification delivery are separate checks. Unattended scheduled installation and the voice/audio library are outside this release.
