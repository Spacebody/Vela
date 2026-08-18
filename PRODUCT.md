# Product
<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

Vela is for individual power users and developers who use Mihomo on Apple Silicon Macs.

They need a native desktop interface for managing configurations, proxy nodes, routing rules, active connections, and operating modes without losing track of the engine, permissions, or system network state.

Typical use includes:

- Importing, validating, switching, and troubleshooting Mihomo configurations.
- Selecting proxy groups and nodes while seeing the active route clearly.
- Running System Proxy, TUN, or Engine Only mode.
- Inspecting and closing connections, checking providers, and diagnosing failures.
- Automating trusted network behavior with Scenes.

## Product

Vela is a native macOS client for operating Mihomo safely and transparently.

It combines a polished macOS experience with reliable state transitions, explicit permission and failure handling, configuration tooling, Scenes automation, diagnostics, and privacy-conscious behavior. It is more than a node switcher: users should be able to understand what Vela and Mihomo are doing, recover cleanly from failures, and manage the full local proxy workflow from one application.

The product should preserve all of these differentiators together:

- A genuinely native macOS interface.
- Reliable switching, rollback, cleanup, and visible runtime state.
- A capable configuration workbench and Scenes automation.
- Clear privacy and security boundaries.

## Design Principles

1. **Make current state unmistakable.** Engine status, operating mode, selected group and node, permissions, transitions, and failures should be visible and understandable.
2. **Prefer safe, reversible operations.** Validate before applying, preserve a working setup when an import or transition fails, and clean up system state predictably.
3. **Use native macOS patterns.** The interface should feel at home on macOS and remain efficient for information-dense network management.
4. **Keep advanced control approachable.** Progressive disclosure should support both routine node switching and deeper configuration, routing, connection, provider, and diagnostic work.
5. **Treat privacy and security as product behavior.** Collect only what a feature requires, explain elevated privileges and network changes, and avoid hidden or surprising system effects.
6. **Preserve operational context.** Users should not have to infer whether a displayed node, route, connection, or mode is stale, pending, active, or unavailable.

## Durable Facts and Constraints

- The supported platform is native macOS 15 or later on Apple Silicon (`arm64`).
- The product name is Vela and its established sail logo is a durable brand asset.
- Vela integrates with and maintains compatibility with Mihomo.
- System Proxy, TUN, and Engine Only are first-class operating modes.
- English and Simplified Chinese are supported product languages.
- The main product areas include Overview, Proxies, Connections, Rules, Providers, configuration profiles and workbench tools, Scenes, Diagnostics, Logs, Updates, Help, Settings, onboarding, and menu bar controls.
- Scene automation may read the current Wi-Fi network name when authorized, but Vela does not scan nearby networks or read BSSID information.
- Application updates must retain signed-update verification and the established privacy-conscious update settings.
- Privileged operations, system network changes, support bundles, and diagnostic exports must remain explicit and user initiated.

## Open Decisions

None currently.
