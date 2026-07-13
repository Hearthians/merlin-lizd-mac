# Tmux Dual-Lane Scheduling Design

## Goal

Opening a Worker's tmux browser must not wait behind background session prewarming. Background discovery should still populate caches proactively and may run against up to 16 different Workers concurrently.

## Scheduling Model

Tmux discovery will expose two execution lanes:

- **Background** is used by `TargetWarmupCoordinator` for launch, inventory-change, and periodic prewarming. It is bounded to 16 concurrent remote Worker operations.
- **Foreground** is used by `TmuxSessionBrowserModel` for user-requested loads and refreshes. It bypasses the background concurrency budget and starts without consuming one of its 16 slots.

The lanes share `TmuxSessionDiscovery`'s snapshot cache and per-target in-flight task map. A foreground request for a target already being refreshed joins that exact task instead of starting a duplicate login. Different targets may run concurrently across lanes. Local and Devbox tmux discovery retain their current behavior; the new limit specifically governs remote Worker background work.

No running background query is cancelled or preempted. The existing cancellation-aware process and SSH master lifecycle remain responsible for timeouts and shutdown cleanup.

## API and Data Flow

Introduce an execution-lane value at the discovery refresh boundary. The warmup coordinator passes `.background`; browser loads and explicit refreshes pass `.foreground`. Fresh-cache reads still return immediately, and stale snapshots remain visible while either lane verifies them.

The background limit belongs at the discovery execution boundary so every background Worker login is counted consistently. Foreground work uses the same SSH master pool but not the background operation runner.

## Testing

Add regression coverage proving that:

1. Sixteen background Worker refreshes can execute concurrently.
2. A foreground refresh for a seventeenth Worker starts while all background slots remain occupied.
3. Foreground and background requests for the same Worker share one in-flight remote command.
4. Background concurrency never exceeds 16, and existing cache, timeout, cancellation, mutation, and shutdown tests continue to pass.

## Non-Goals

This change does not persist tmux snapshots, alter the five-minute refresh interval, increase SSH master preparation concurrency, or change terminal connection behavior.
