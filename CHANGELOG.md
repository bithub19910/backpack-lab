# Changelog

## 1.0.0 — 2026-10-01

- Preserve native scene structure and combat rules; gate audited presentation entry points only in private simulation workers. Keep the actual game and Mod interface animated normally.
- Disable activation visuals, one-shot particles, labels, sounds, health/stamina HUD refresh and squishy sprite processing. Preserve out-of-stamina counters and electrical charge callback order/timing.
- Stop prewarming and creating combat-log RichTextLabel rows in workers while preserving native events, timestamps and metric histories.
- Compare full per-trial results against the previous local worker, including fatigue and Engineer charge effects. Retain fixed paired samples and object reuse.

- Keep stable item sample identities across moves, rotations and reinsertion; separate random streams by item and purpose while retaining native probabilities and balanced-roll rules.
- Isolate audited dialogue, merchant reactions, shop animation, particles, labels and sound randomness; regression-test extra cosmetic calls during combat.
- Add inert Piggybank and exact +15 Protective Purse regression fixtures; remove the old error-percentage footer.
- Separate comparable best results from shop previews; reuse sample prefixes and in-flight work, with persistent private worker object reuse and manual cache recovery.
- Enlarge both charts to at least square; let the lower controls expand and scroll with settings/statistics. Align shop preview buttons to a consistent grid.
- Start the 25-trial current-match win-rate job when combat starts. Show a compact top-left window, remember eye-button visibility, reveal automatically at combat end by default, and persist the latest opponent locally.

## 0.2.0 — 2026-10-01 (prerelease)

- Add Windows GUI installation, integrity validation, Steam detection and desktop shortcuts.
- Center manual recalculation below enlarged output/recovery charts.
- Compact best-layout and shop-preview modules side by side; show best output and recovery rates.
- Display measured ten-trial sampling variation with documented method.
- Maintain independent dummy/opponent modes and native slots 8/9.
- Preserve manual shop preview, own-side filtered metrics and postbattle 25-trial win rate.
