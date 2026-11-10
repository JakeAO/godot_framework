# GDD — Game Design Document (SOURCE OF TRUTH)

> **Status**: Living document. Per project policy, this GDD and the companion TDD are the
> source of truth for the framework's design: **update them BEFORE implementing any new
> feature**, then implement to match. Implementation details live in the code; design
> intent lives here. Technical contracts (APIs, save schema, signal tables) live in TDD.md.
> Historical rationale: DECISIONS.md. Open work: TODO.md. Gotchas: NOTES.md.

## 1. Vision & scope

A **bulletproof, modular framework for rapidly iterating on mobile game prototypes in Godot 4.x**.
The current content is a vertical slice of a casual "stage ladder" progression game that
exercises every framework system end-to-end: menu → play → results → rewards → progression,
plus monetization (offers/ads), social, experiments, localization and onboarding scaffolding.

Design principles:
1. **Mock content, real seams** — gameplay/social/ad/config content is mock, but flows through
   the same persistence, event and config paths a production build would use. Swapping in real
   services must not require UI or flow changes (see TDD §"Service swap seams").
2. **Data-driven where it matters** — tunables (round length, target lifetime, win score,
   spawn rates, rewards) live in remote config, not code constants.
3. **Decoupled systems** — cross-system communication only via the EventBus; no manager may
   call another manager's methods directly.
4. **Prototype velocity** — code-first UI, centralized theme, minimal .tscn files, everything
   verifiable headless (import → boot → GUT gate).

## 2. Platform & constraints

| Constraint | Value |
|---|---|
| Engine | Godot 4.x (developed on 4.7 stable) |
| Orientation / base resolution | Portrait, 720×1280, stretch `canvas_items` + `expand` |
| Input | Touch-first; mouse unified with touch for desktop iteration. Keyboard is a convenience extra (pause), never required |
| Languages | English, Spanish (complete string tables; every user-facing string goes through `tr()`) |
| Services | Mocks by default (gate-hermetic); real target = self-hosted Nakama on one VPS (analytics = in-Nakama Go plugin; TDD §3.17, BACKEND.md) — a build-config swap (`game/backend_base_url`), no code changes |
| Save format | Versioned JSON, domain-partitioned (TDD §Save schema) |

## 3. Core loop

```
HOME (Adventure Ladder) ──PLAY──▶ GAME (30s tap-target round)
      ▲                                    │ round end
      │                                    ▼
   HOME ◀──Home/Play Again── RESULTS (score, best, coins, XP)
```

- The player climbs the **Adventure Ladder**: 5 stages. Cleared stages show no action,
  the current stage shows a gold PLAY button, later stages are locked.
- Each round is self-contained: enter GAME → 30-second timed round → RESULTS with rewards.
- Secondary loops (all visible on HOME): daily gift claim, piggy bank drain, booster
  cooldowns (right zone), timed events + solo campaign widgets with countdowns/claims (left zone).

## 4. Gameplay — tap-target round

- Fullscreen; HUD shows live score, seconds remaining and a pause button (pause overlay: Resume / Quit).
- **Targets**: gold circles, 96×96px, max 4 on screen simultaneously, random position in the play area.
- **Lifetime**: `target_lifetime_sec` remote value (default 1.5s). A target that expires resets the combo chain.
- **Spawn cadence**: uniform random between `spawn_interval_min`/`spawn_interval_max` of the device's assigned `target_spawn_rate` experiment variant (defaults 1.2/1.6s; min>max is swap-guarded, non-positive yields a 1.4s fallback).
- **Scoring** (`Scoring.tap_score(chain)`): points = `10 + 2 × chain`, where `chain` is the number of consecutive successful taps BEFORE this one (first tap of a chain scores 10).
- **Round duration**: `round_duration_sec` remote value (default 30s). Pausing freezes time accumulation (delta accumulation, not process freeze) so the pause overlay stays interactive.
- **Win condition**: final score ≥ the stage's effective `win_score` (stage data, falling back to the remote value, default 150) → stage advances by one (capped at the last ladder stage — see §5). Losing a round costs nothing; best score is kept.

## 5. Progression — stages & levels

### Stages (normative spec — implemented per this section)
- **The framework is NOT the game.** The tap-target round is a prototype/evaluation vehicle. Everything stage- and gameplay-related must stay generic enough that an alternate mechanic (plinko/ball-drop, crane game, match-3, word solve, scrolling shooter, …) can be dropped in via a branch off the base framework: one `GameplayBase` subclass + one registry line + stage files pointed at it.
- **Stages are data**: one `StageDefinition` resource (.tres) per stage under `res://resources/stages/`, loaded by StageCatalog and sorted by `id`. **Adding a stage = adding a file** — no code edits. The default ladder ships with 5 stages (all tap-target).
- Fields: `id` (1-based ladder position — the value stored in `profile.stage`), `name_key` (tr() key for display; empty → "Stage <id>"), `gameplay_key` (GameplayRegistry key, default `"tap_target"`), `duration_sec` (≤0 → remote `round_duration_sec` default), `win_score` (≤0 → remote `win_score` default).
- **Gameplay selection**: each stage's `gameplay_key` picks the minigame via the GameplayRegistry (key → `GameplayBase` subclass; unknown keys warn and fall back to tap-target so a misconfigured stage never bricks the ladder). The remote value `gameplay_scene`, when non-empty, is a GLOBAL override forcing every stage onto one minigame — a QA/prototyping lever for trying a new mechanic across the whole ladder without editing stage files.
- Advancing requires winning a round on the current stage (score ≥ effective win_score); progression caps at the last ladder stage. `profile.stage` reads are clamped to the ladder size, so a save from a longer ladder degrades gracefully instead of stranding the player past the end.

### XP & levels (normative spec — implemented per this section)
- **XP earned per round = coins earned** in that round (single source of truth for "round value"), before campaign modifiers are applied (§6 Campaigns).
- **Level curve**: XP needed to go from level L to L+1 is `100 + 50 × (L − 1)` → L1→2: 100, L2→3: 150, L3→4: 200, …
- Level-ups apply immediately at round end and cascade while XP suffices. Feedback: `EventBus.level_upped(new_level)` + a toast ("Level N!") that is allowed to show over the fullscreen Results screen. Header level label updates via `profile_updated`; Profile → Stats shows current level and XP progress toward the next level.

## 6. Economy

### Currencies
- **Coins** — earned: round rewards, daily gift, piggy bank redemption, streak claims, tournament rewards, Gift Pile cash-outs. Spent: shop purchases, streak recovery, Gift Pile run saves (§6 Shop).
- **Gems** — rare premium currency; earned via booster offers + tournament/jackpot rewards. Spent: gems-priced shop items (the v1 catalog includes at least one).

### Round reward
`base_coins = score / 10 × multiplier`, where `multiplier` comes from the `results_coin_multiplier` experiment (x1 or x2, 50/50 split). Zero for non-positive score/multiplier. Campaign modifiers then scale the round value (§6 Campaigns): `coins_earned = base_coins × ∏(active coins modifiers)`, `xp_earned = coins_earned × ∏(active xp modifiers)` (XP keeps its §5 "equals coins earned" rule, applied AFTER coin modifiers).

### Piggy bank (normative spec — REVISED Phase F2, supersedes the per-round deposit rule)
- A savings jar that accumulates a share of progression: **each stage cleared deposits `piggy_deposit_per_stage` coins (remote value, default 10) into the bank**, capped at `piggy_bank_capacity` (remote value, default 200).
- **Redemption threshold**: once the balance reaches `piggy_redemption_threshold` (remote value, default 150), the bank becomes redeemable. Redemption is NOT free — the player pays with a rewarded-video watch or (mock) IAP to collect the ENTIRE balance; collecting resets it to 0. Below the threshold the widget/dialog shows progress toward it and redemption is disabled.
- The Piggy Bank zone widget remains the entry point (right zone); tapping opens the Piggy Bank dialog (§8 Zone widget dialogs), which hosts the fullness display + the redemption action.

### Offers (right zone, Home only)
| Offer | Kind | Reward | Availability rule |
|---|---|---|---|
| Daily Gift | `daily_gift` | `daily_gift_coins` coins (default 50) | Once per calendar day (`profile.last_daily_claim_day`) **+ up to `daily_gift_extra_watches` (remote value, default 2) EXTRA redemptions per day via rewarded-video watch** (date-keyed counter in `profile`) |
| Piggy Bank | `piggy_bank` | Full bank balance | Balance ≥ `piggy_redemption_threshold`; redeem via RV or mock IAP (§6 Piggy bank) |
| RV Booster | other | 5 gems | Cooldown elapsed since last claim (`cooldown_hours` from config; never claimed = available) |

- Every offer is additionally gated by a `<offer_id>_enabled` remote flag (default true).
- Claim: grants reward → stamps the save → **the widget's dialog plays the one-shot "opening" clip** (sprite-art offers — §8 Zone widget dialogs) → button state refreshes. No success toast — a claim is the direct effect of the tap (H2 toast policy). Zero-amount configs never write claim stamps (save-state protection).

### Campaigns (left zone by default, Home only) — normative spec, implemented per this section
- **Solo mechanics** from remote config (`campaigns` array). A separate mechanism from events (which surface multiplayer content); both render as widgets in the side zones.
- Entry shape: `id`, `title`, `subtitle`, `icon` + optional fields:
  - `ends_in_hours` — deadline = config fetch time + hours; absent/≤0 → evergreen (no expiry).
  - `action`: `"claim"` (`reward_currency`, `reward_amount`) | `"modifier"` (`modifies` "coins"|"xp", `multiplier`) | absent = display-only.
  - `metadata` (optional dict, freeform extension point; unknown keys ignored):
    - `zone`: `"left"` (default) | `"right"` — which side zone the widget appears in.
    - `progress`: `{current, goal}` — renders "N/M" on the widget strip.
    - `dialog`: `{title, body}` — tapping the widget opens a text dialog.
    - `tooltip`: `String` (localized) — long-press hint on the widget (see §8 Tooltips).
- **Widget strip priority**: claim button > progress "N/M" > countdown ("Ends in H:MM", refreshed every second) > none (icon only).
- **Lifecycle**: a campaign/event widget is REMOVED from its zone when it expires (checked on the 1s tick) or is claimed, and filtered out at any later rebuild. Claiming a `claim` campaign grants the reward once per id (stamp in the `campaign_claims` save domain) and removes the widget — no success toast (H2 toast policy).
- **Modifier campaigns** apply at round end: active = not expired; all active modifiers of a given stat stack multiplicatively on that round's earnings (`coins_earned`/`xp_earned`). Applied modifiers are surfaced on the Results screen as badges ("×2 Double XP Friday").
- Current content: `double_xp_fri` (2× XP, 9h), `practice_bonus` (claim 50 coins, evergreen), `streak_bonus` (**LIVE** daily-streak widget since Phase F2 — §8 Daily streak; progress strip = current streak / reward-table length).

### Events (left zone by default, Home only)
- **Multiplayer surface** (tournaments) from remote config. Since Phase F4 the `kind: "solo_tournament"` / `"team_tournament"` entries are JOINABLE with live standings (§8 Tournaments); kind-less entries keep the legacy display-only dialog behavior. Entry shape and widget/lifecycle rules are shared with campaigns (`ends_in_hours` deadline, strip priority, removal on expiry). Current content: `tournament_weekend` (solo kind, 26h in the stub config — production schedules it weekly server-side).

### Shop (normative spec — Phase F1, the first currency sink; resolves old gap §11.1)
- A dedicated screen (`shop`, full chrome, NOT in the bottom nav) opened by **tapping the Coins widget** in the player header on any chrome screen (fullscreen game/results have no header).
- **Catalog**: remote config `shop_items` array — data-driven, hot-swappable. Item shape: `id`, `title`, `icon` (ProtoIcon key), `contents` (what the buy grants), `price` `{currency: "coins"|"gems", amount}`, optional `max_purchases` (1 = one-shot → row shows Owned after purchase; absent = repeatable), optional `unlock_level` (min player level to buy).
- **Contents kinds** (v1): `{"type": "currency", "currency": "gems", "amount": N}` | `{"type": "cosmetic", "slot": "portrait_icon"|"portrait_flair"|"portrait_crown", "id": "<catalog id>"}`. Cosmetics are OWNED (persist in the `shop` save domain) and become selectable in Profile; currency contents are granted immediately.
- **Purchase flow**: balance check (insufficient → buy button disabled with the cost shown — a purchase never fails mid-transaction) → deduct → grant → stamp the purchase count → row state + header currency refresh. No success toast (H2 toast policy — the row/header update IS the feedback); failure warnings still toast. Mock buys only — no real payments in v1.
- Layout: vertical scrolling list; each row = icon + name + contents line + price chip + buy button (§7).

### Ads
- Banner slot at the bottom of the screen (all non-fullscreen screens): mock creatives rotate on a timer (`banner_refresh_sec`, default 30s), gated by `banner_ads_enabled`. States: idle → loading → loaded | error; non-loaded states render an empty panel (no layout jump).
- **Rewarded video (RV)**: `AdManager.watch_rewarded(on_result)` — consumed by streak recovery, piggy redemption, daily-gift extra redemptions and Gift Pile saves/extra runs. On mobile with remote flag `admob_enabled` + unit IDs set, both banner and RV run on the real **AdMob** SDK (vendored plugin v5.1.0 behind `AdMobBackend`, TDD §3.28); everywhere else — including all automated testing — the built-in mock runs (mock RV always succeeds; a debug seam can force failure).
- Going live is a remote-config flip (no client rebuild): set `admob_enabled` + real unit IDs. On-device verification (consent/UMP, Ad Inspector, real fills) is the remaining follow-up.

## 7. Screen inventory

| Screen | Id | Chrome | Purpose |
|---|---|---|---|
| Home | `home` | full chrome + both side zones | Adventure ladder (5 stages) + PLAY; events/offers zones |
| Profile | `profile` | full chrome, no zones | Live portrait preview + tabs: Portrait / Flair / Crown / Stats. Picks persist to save with inline feedback (no toast — H2) |
| Social | `social` | full chrome, no zones | Tabs: Friends (mock feed, gated by `social_feed_enabled`) / Team (join CTA or team content with Chat/Members sub-tabs) / Search (filter friends or teams) |
| Special | `special` | full chrome, no zones | Swappable slot: `BaseSpecialScreen` base with virtuals; each prototype branches the repo and replaces the content. Default = title + body placeholder |
| Settings | `settings` | full chrome, no zones | Toggles: Music / SFX / Notifications / Reduced VFX; Privacy Policy, Data Policy and Support open in-theme text dialogs. Reset-all with confirmation dialog |
| Game | `game` | **fullscreen** (no chrome) | Tap-target round + HUD + pause overlay |
| Results | `results` | **fullscreen** (no chrome) | Score / best / new-best badge / coins earned / XP earned / applied campaign modifier badges; Play Again and Home |
| Shop | `shop` | full chrome, no zones | Vertical product list — icon / name / contents / price / buy button per row (§6 Shop); opened by tapping the Coins widget in the header, NOT in the bottom nav |
| Gift Pile | `gift_pile` | **fullscreen** (no chrome) | Press-your-luck minigame (§8 Gift Pile): reveal pile slots, bank rewards, cash out or pay to save a failed run; entry from its zone widget |

Chrome (ScreenShell): player header (gems left, avatar+name+level center, coins right — **the coins column is tappable → Shop**), bottom nav
(Profile, Social, Home, Special, Settings — active tab highlighted gold), side zones (Home only), banner slot.
Fullscreen screens hide all chrome and expand content to full rect.

## 8. Feature systems

### Profile customization (mock catalog)
- Portrait icons (6), flairs (7: ring/banner/capsule styles), crowns (4) from a code-drawn mock catalog (`PortraitCatalog`). Picks persist as plain strings in the `profile` domain (`portrait_icon`, `portrait_flair`, `portrait_crown`) and refresh everywhere via `profile_updated`. Real art swaps in at PortraitView/ProtoIcon only.
- **Shard partial unlocks (H8)**: every unlockable cosmetic can also be unlocked gradually with shards — small percentage chunks of a full unlock awarded by sources (wired: Gift Pile cash-outs grant `gift_pile_shard_reward` toward the next locked cosmetic). 100% = normal owned appearance; partial = greyed + progress bar in the Profile grid; 0% = no indicator. Shards are per-cosmetic (`shop.shard_progress`, TDD §3.20), not a spendable balance.

### Social & team — online services (normative spec — backends built to this)
- **Today**: friends list, teams and chat run on `MockSocialBackend` behind `SocialManager` (TDD §3.16 — screens consume the manager, never mock data). **Team state is real locally**: joining writes the `team` save domain (`on_team`, `team_name`, `banner_color`, `power`, `members`) and the Team tab renders from it; player starts NOT on a team (join CTA visible, pointing at the Search tab).
- **The real backend is decided (2026-11-06)**: self-hosted **Nakama** (analytics via an in-Nakama Go plugin) on one VPS — `NakamaSocialBackend` implements the same contracts below WITHOUT touching UI or flow code (TDD §3.17, BACKEND.md). The four contracts define what it must support; mock and real backends are interchangeable behind `SocialManager.set_backend()`.
- **Security posture (user directive)**: prototype-grade. Requirement: unidentified calls must never be able to affect the state of unrelated players/teams. Excessive security is explicitly out of scope for prototypes.

### Identity & authentication (normative spec)
- **Player key**: a stable random 256-bit identity generated on first launch, persisted in its OWN file (`user://player_identity.json`) — deliberately NOT inside save.json, so it survives "Reset Save Data" and corrupt-save quarantine. Mock mode sends it with EVERY request (`X-Player-Key` header); real mode it IS the Nakama custom-ID credential (below). A rejected key (401) fails the health probe — repeated auth failure takes the connection state OFFLINE (TDD §3.17/§3.18) and callers fall back to local state (warn once per session).
- **Player code**: a short human-readable identifier derived DETERMINISTICALLY from the player key (word + 4 digits, e.g. `OWL-4821`), so any device holding the key computes the same code with no round-trip; the server indexes codes on first sight. Shown on the Profile screen; used to add friends.
- **Token seam → Nakama session (concrete since 2026-11-06)**: v1 sends the raw key. The upgrade the seam was designed for IS the real backend: the player key is used verbatim as Nakama's custom-ID credential, and `IdentityService` exchanges it once for a **session JWT** — persisted in the identity file, restored at boot, re-exchanged on expiry (TDD §3.17). `get_auth_headers()` returns the Bearer token for non-client paths; callers, UI and flow code never change.

### Friends (normative spec — v2 surface, implemented 2026-11-06)
- The friends list is **server-owned** (not part of the local save): a fetch returns friend summaries `{player_code, name, level, best_score, portrait_icon, portrait_flair, portrait_crown}` — the same shape the mock rows already render; `social_feed_enabled` keeps gating list vs empty-state.
- **Add by player code**: an add-by-code field in the Friends tab; unknown/invalid code → inline error, no state change. Adding sends a **pending invitation** (two-way model): the recipient sees it and accepts or rejects; the sender can cancel a sent invitation. Error keys: `friend_invalid_code` / `friend_unknown_code` / `friend_already_added` / `friend_pending_exists` / `friend_blocked`.
- **Pending invitations**: both directions are visible in the Friends tab — received rows carry Accept/Reject, sent rows carry Cancel. The mock simulates the full two-way lifecycle locally (TDD §3.16), so every flow is exercisable headless; Nakama maps to friend states 0–3 (TDD §3.17).
- **Block / unblock**: blocking a user removes them from friends and pending invitations and prevents re-adding until unblocked (enforced server-side on the real backend). Blocked users render in a separate dimmed section with an Unblock action.
- **Remove friend** from the row. Presence indicators per "Presence & status" below (Phase E2); no per-friend feed content beyond the profile summary.

### Teams (normative spec — revised 2026-11-06: creation, settings, access, banners)
- **Create**: from the Team tab when not on a team (alongside the join CTA). Creation takes a name, an access mode, and a banner recipe (below); the creator becomes the team's **leader**. Real backend = Nakama group creation (TDD §3.17); the mock simulates locally.
- **Search**: a query returns joinable teams `{team_id, name, access_mode, power, members: Array[String], banner_recipe}` — rows render the team banner, an access badge (open / by-request), and the right action: open → Join; by-request → Request to join.
- **Access modes**: `open` (join instantly) | `by-request` (joining sends a request that the leader approves or denies from team settings). A pending request shows as a "Request sent" state for the requester until answered; answering is one-shot (approve → member, deny → cleared).
- **Join / leave**: join writes the `team` save domain (schema extended below — TDD §3.4); leave clears it (and any pending request). The Team tab keeps rendering from the local domain, so offline behavior is identical to today.
- **Roster & stats**: members render in the Members subtab (leader first). The team header shows stats: power + member count + access badge. Power is server-owned (mock: static per team); no per-player team stats in v1.
- **Settings (leader only)**: a gear button on the team header opens a settings dialog — edit name, switch access mode, re-customize the banner, and view/approve/deny join requests (by-request teams). Non-leaders see the header without the gear. Real backend = group metadata update (TDD §3.17).
- **Chat (realtime — Phase E1)**: still exactly two player operations — receive message history and send one message `{id, sender_code, sender_name, text, ts}` — but delivery is PUSH: while on a team and online the client holds a live subscription to the team's group channel, so new messages arrive as they are sent (the v1 polling cadence is retired). Opening the Chat subtab fetches recent N for the initial paint; a catch-up refetch runs when the chat becomes visible again after being hidden, when the connection comes back online, and when the team changes — dedupe by message id makes overlap harmless. **Send box**: the Chat subtab has an input field + send action (v1 was display-only); send failures surface inline and never block the UI. **Offline**: last received messages stay visible with the shared offline banner; sending is disabled and the subscription is dropped, then re-established on reconnect (TDD §3.18).

### Team banner customization (normative spec)
- A team banner is TWO layered sprites, each LUT-colorized: a `BannerBase` (full-width backdrop) with its own palette LUT, overlaid with a centered `BannerIcon` (emblem) with its own palette LUT. The **recipe** = `{base: String, base_lut: String, icon: String, icon_lut: String, icon_scale: float}` — four independent selections plus the emblem's size (a multiplier over the classic ~40%-width placement, clamped 0.5–1.5 so it never overflows the banner; default 1.0), persisted in the `team` domain and mirrored to server group metadata (TDD §3.4/§3.17).
- **Catalog**: nearly a hundred options each for bases and icons, plus dozens of LUTs (exact counts pinned in TDD §3.19) → ~389,000 unique banners with zero per-combination assets: bases/icons are grayscale-authored and a small shader remaps luminance through the selected 16-color palette at render time.
- **Art status**: REAL sheet-split artwork on disk (2026-11-06 — user-provided spritesheets split by `tools/split_banner_sheets.py`; TDD §3.19). Bases are uniform 256×512 (1:2 portrait, hanging-flag style); icons native-scale over transparent. A future art pass re-runs the splitter at the same paths (same doctrine as ProtoIcon/PortraitCatalog). LUT palettes are data (color arrays), not images.
- Rendered by `TeamBannerView` (TDD §3.19) everywhere a banner appears: search rows, team header, and the banner editor (live preview in create/settings flows).

### Cross-device save sync (normative spec)
- **Synced domains**: `profile`, `piggy_bank`, `campaign_claims`, `team`. **Local-only**: `settings` (per-device preferences), `meta`, `device`; identity lives in its own file (above).
- **Semantics: per-domain last-write-wins.** The client uploads a snapshot of the synced domains after meaningful mutations; the server keeps the latest per player, stamping each domain with `updated_at`. On fetch (app start), each domain merges by newest stamp — newer wins, older is discarded. No field-level merge rules in v1 (accepted gap: two devices playing simultaneously can lose one side's round rewards or double-spend coins; fine for prototypes).
- **Triggers**: fetch on app ready; upload after synced-domain mutations (debounced); manual "sync now" from DevTools. The local save remains the source of truth between syncs — the game is fully playable offline and a sync failure never blocks play (warn once per session). Real backend = Nakama storage objects (collection `save`, one object per domain; TDD §3.17).

### Online & offline feature availability (normative spec)
- **The game is fully playable offline.** Every gameplay/economy/progression system works with zero connectivity; online services degrade to DISABLED — never hidden, never faked.
- **"Online" = a VERIFIED connection to the backend**: an authenticated session AND a recent successful health probe (cadence from remote value `backend_health_sec`, default 30s). A single failed operation does NOT flip the state — connection state is owned exclusively by `OnlineService` (TDD §3.18), emitted as ONE signal, `backend_state_changed(online: bool)`.
- **Gating table** (normative):

| Feature | Offline behavior |
|---|---|
| Gameplay / rounds / rewards / XP / levels | Fully functional |
| Piggy bank, offers, campaigns, daily gift | Fully functional |
| Settings, profile display, FTUE, DevTools | Fully functional |
| Remote config content | Last-good cache; refetch happens independently of backend state |
| Friends list / add / invite / accept / reject / remove / block | DISABLED (rows + add field dimmed with a shared offline hint) |
| Team search / create / join / request / leave / settings / requests | DISABLED (the local team banner + roster still render read-only) |
| Team chat | Send DISABLED; last fetched messages visible + offline banner |
| Cross-device save sync | No traffic; Profile sync line shows "offline" |
| Tournaments (F4) | DISABLED (dialog shows its offline state; entries/submits never faked) |
| Team chat (realtime, E1) | Send + input DISABLED; last received messages visible + offline banner; subscription dropped until reconnect |
| Presence indicators (E2) | Hidden (rows fall back to the plain level line — no layout jump); last-seen stamps not shown |
| Leaderboards (E5) | DISABLED (dialog shows its offline state; scores never faked, submits suppressed) |
| Matchmaking (E4) | DISABLED (dialog shows its offline state; queueing never faked) |

- **UI rule**: online-required controls are disabled + dimmed with a shared localized hint — never removed (layout must not jump; same rule as banner non-loaded states).

### Competitive & live-ops — Phase E (normative spec — decided 2026-11-08)
- The Events surface (§6) is the player-facing home for competitive content. Phase E implements it against Nakama's native primitives, one item at a time, spec-first per project policy: **realtime team chat** (E1), **presence/status** (E2), **leaderboards** (E5), **async matchmaking hook** (E4). **Tournaments moved to Phase F4** (§8 Tournaments — implemented first because the live-ops content pass needs them). Every Phase E feature is online-gated per the table above: offline = disabled, never faked; mock mode renders the same "needs an online connection" states as F4 (never faked data).
- **E1 Realtime team chat** — spec in TDD §3.24. The websocket upgrade of the polling channel: push delivery while on a team + online, history fetch for initial paint, catch-up refetches with id-dedupe, and the new send box (v1's Chat subtab was display-only).
- **E2 Presence & status** — spec in TDD §3.25. Friend rows show an **online** indicator when the friend has a live server session (realtime join/leave events over the socket — no polling), otherwise a **last-seen** relative time stamped by their device on session establishment. Team member rows get the same treatment. Indicators ride the existing level line ("Level 7 · online" / "Level 7 · seen 2h ago") so rows never change shape; hidden entirely when offline-gated.
- **E5 Leaderboards** — spec in TDD §3.26. ONE server board (best score) with two listing scopes: **global** and **friends** (same records, friend-filtered). Scores are server-owned and submitted automatically whenever the local best improves — no manual scoring UI. Surface = a "Ranks" zone widget on Home opening a dialog (Global/Friends toggle, top-N list, own-rank row always visible).
- **E4 Matchmaking hook** — spec in TDD §3.27. A player queues for a 1v1 match; the server matches two queued players and both are told who their opponent is. This is the HOOK: matching + the realtime match room work between real clients (Godot's high-level Multiplayer RPCs run over Nakama matches via the client addon's `NakamaMultiplayerBridge` — the payoff of choosing Nakama), but NO in-match gameplay rides it yet (post-E4 content work). Surface = a "Matchmaking" zone widget opening a state-driven dialog (idle → queued [Cancel] → matched: opponent name + player code).

### Zone widget dialogs (normative spec — Phase F2)
- **Every zone widget opens a dedicated state-driven dialog on tap.** The widget strip stays the compact state indicator (claim > progress > countdown priority, §6); the dialog is the detail + action surface, built with `UIManager.show_dialog(content)` (code-first content controls, in-theme).
- **State-driven rendering**: each dialog renders from live save/config state at open AND refreshes on the relevant EventBus signals while open. Per kind:
  - **Daily Gift** — free claim available → [Claim] (the gift opening clip plays IN the dialog — that IS the feedback, no toast per H2); N RV redemptions left today → [Watch & claim]; none left → "come back tomorrow" + countdown to next day.
  - **Piggy Bank** — fullness gauge (balance / capacity) + threshold progress line; below threshold: collect disabled with "fills X per stage cleared"; at/above: [Collect via RV] / [Collect (mock IAP)] → opening clip in-dialog → balance resets to 0.
  - **Streak** — current streak, today's requirement (rounds played / needed), claim when met; BROKEN state shows the one-shot recovery options (pay coins or watch RV).
  - **Booster / other offers** — claim + opening clip (same shape as offers).
  - **Tournaments** — §8 Tournaments dialog.
- Claim/redeem actions run the SAME save-mutating flows as before (stamps, `currency_changed`/`profile_updated`; no success toast per H2) — only the surface moved from widget button to dialog.

### Daily streak (normative spec — Phase F2; replaces the display-only `streak_bonus`)
- **Goal**: complete at least `streak_min_rounds_per_day` rounds (remote value, default 1) on consecutive days.
- **State** (`profile` domain): `streak_days`, `streak_last_date` (YYYY-MM-DD), `streak_rounds_today`, `streak_date` (the date the current round count belongs to), `streak_recovered` (this break was already recovered — blocks a second recovery).
- **Progression**: each completed round bumps the day counter (rolling over when the date changes). When today's requirement is met and `streak_last_date` is yesterday (or empty), the streak is CLAIMABLE: reward = `streak_rewards[min(streak_days, len−1)]` coins (remote array, default [50, 75, 100, 125, 150] — last entry caps). Claiming sets `streak_last_date = today`, increments `streak_days`, resets the day counter.
- **Break & recovery**: a new day arrives with yesterday's requirement unmet → the streak is BROKEN (next claim restarts at 1) but recoverable ONCE per break: pay `streak_recovery_coins` (remote value, default 200) or watch RV → previous length restored.
- **Surface**: the `streak_bonus` zone widget (progress strip = streak / table length) + Streak dialog. Pure local logic — fully offline, no backend dependency.

### Tournaments — solo & team (normative spec — Phase F4, Nakama-native)
- **Solo tournament**: a scheduled event (stub config: `ends_in_hours`; production: weekly server-side schedule). The player is ENTERED AUTOMATICALLY by WINNING a round while the event is active (TDD §3.23 won-rounds-only rule; a lost round neither enters nor advances) — no opt-in UI. Each qualifying win adds progress points = `tournament_points_per_win` + `floor(score / tournament_score_divisor)` (remote values, default 10 + score/25), accumulated per event in the `tournaments` domain and submitted to Nakama as the running total.
- **Team tournament**: identical flow but the entry is the player's TEAM — each member's qualifying rounds add to the team's progress (Nakama team-mode summation). No team → widget shows "join a team to enter" and no entry happens.
- **Standings dialog**: tap → top-N standings list + own rank + own progress + the reward bands. Standings come from Nakama tournament records; offline = disabled per the §8 gating table (never faked).
- **Rewards at expiry**: configurable rank bands in the event entry (`rewards: [{min_rank, max_rank, currency, amount}]`). When the event expires, entered players see a [Claim] state → band lookup by rank → grant + one-shot stamp. Team rewards are DIVIDED EVENLY among current team members (floor per member, remainder to the team leader). Accepted prototype simplification: band lookup + grant is CLIENT-side from config — Nakama's server-side reward system is not used.
- **Server side**: a `tournament_ops` server function (same JS entrypoint as `team_ops`) idempotently ensures the configured tournaments exist — both solo and team are plain Nakama tournaments (there is no native team mode; the team score is a single group-owned record incremented by member deltas, TDD §3.23) — and maps event ids → tournament ids; created in Phase F4 in the backend repo.

### Gift Pile — press-your-luck minigame (normative spec — Phase F3)
- **Entry**: zone widget (left zone) → intro dialog (rules + top prize + save cost) → Play → fullscreen `gift_pile` screen. Entering with a run in progress RESUMES it (state persists in the `gift_pile` domain).
- **The pile**: a vertical stack of `gift_pile_height` slots (remote value, default 10), pregenerated at run start from config weights (reward kinds vs failure traps); the TOP slot is always the jackpot (a large prize — e.g. a gem amount or cosmetic).
- **Play**: reveal slots bottom-up, one tap at a time. A reward slot BANKS its contents into the running total; a FAILURE trap puts the run in DANGER — the banked total is at risk: pay `gift_pile_save_coins` (remote value, default 100) or watch RV to keep it and continue, or decline and lose everything (run ends).
- **Box-selection illusion** (cosmetic theater, H6): when `gift_pile_boxes_per_level` > 0 (remote value, default 3), each step shows a row of N CLOSED gift boxes instead of tappable pile slots; opening ANY box reveals the predetermined next slot (the choice is pure illusion — pile shape is unchanged). A REWARD opens the remaining boxes with fake "possible rewards" before a fresh row appears; a TRAP keeps the unopened boxes for the next pick after the save decision. Value 0 = legacy direct-slot reveal.
- **Cash out**: available any time NOT in danger → grants the banked total, ends the run. Reaching the top slot banks the jackpot and auto-cashes-out.
- **Entry limit** (OPEN PARAMETER — default chosen for prototype balance, review at device test): `gift_pile_runs_per_day` (default 1) + up to `gift_pile_extra_watches` (default 1) extra runs via RV watch; date-keyed stamps in the `gift_pile` domain.
- Pure logic lives in a testable state-machine class with no UI coupling (seeded generation for deterministic tests); the screen renders it. Fully offline — no backend dependency.

### Experiments (A/B)
- Device-stable variant assignment: FNV-1a hash of `<device_id>:<experiment_name>` over weighted variants. Current experiments: `target_spawn_rate` (control 50 / fast 30 / slow 20; params spawn_interval_min/max) and `results_coin_multiplier` (x1/x2, 50/50). Exposure is logged once per experiment per session and tracked in analytics automatically.

### Localization
- en + es complete string tables; every user-facing string via `tr()`. Locale switch re-localizes all live UI (screens implement `_apply_locale()`; stale-text rule: re-set ALL text, never append).

### Audio
- BGM: menu / game tracks with crossfade; music ducks while gameplay runs and unducks after. SFX: click/success/fail from a 4-slot round-robin pool + dedicated UI-bus click player. All buses respect the settings toggles (disabling music stops BGM and remembers the track for resume).

### Onboarding — FTUE v1 (normative spec — implemented per this section)
- Triggers once, on first launch (no `meta.ftue_done` flag): when Home is first shown.
- Two steps, both targeting Home-owned controls:
  1. **Ladder title** — "Climb the Adventure Ladder: clear a stage to unlock the next." (any tap advances)
  2. **PLAY button** — "Tap PLAY to start your first round!" (press is forwarded → round starts; navigation away auto-cancels the tutorial)
- On finish or cancel, `meta.ftue_done = true` is persisted so it never runs again. Expansion (offers/events steps, in-gameplay tips) is deferred to the collaborative content pass.

### Tooltips — long-press hints (normative spec — implemented per this section)
- Purpose: discoverability of non-obvious controls on touch devices that have no hover state. A tooltip is a small icon+text bubble floating above the control being held.
- **Opt-in per control**: only explicitly attached controls can show tooltips (`UIManager.attach_tooltip(control, text, icon_key)`). Nothing else in the game ever triggers one — no accidental popups on ordinary buttons.
- **Trigger (long-press)**: press and hold an attached control for 0.5s while moving ≤12px. Releasing early = a normal tap (no tooltip); moving beyond the slop = a drag/scroll (no tooltip). A long-press NEVER blocks or swallows input — the control's own behavior still happens (a long-pressed button also fires on release).
- **Content**: optional icon + one autowrapped text line, same visual language as toasts. Text is localized (`tr()` keys).
- **Dismissal**: any subsequent press anywhere, navigating screens, or opening a dialog dismisses the current tooltip — and the dismissing interaction itself still works. While a dialog is open or a tutorial is active, new long-presses do not spawn tooltips.
- **Data-driven attach**: campaign/offer metadata may carry `tooltip: String` (localized text) — the shell attaches it to the widget at build time, so content can add hints without code.

### Debug / development tools (debug builds only)
- A developer/QA overlay panel reachable from anywhere in the game; entirely absent in release builds (`OS.is_debug_build()` gate — no overlay node, no input handling, zero cost).
- Access (both work, editor and device): tilde key (`~`/`` ` ``) or a 3-finger downward swipe (≥120px of travel). The panel has a close button; the swipe is debounce-guarded (1s) against double triggers. Typing `~` in a focused text field can never toggle the panel (GUI consumes the key first).
- Sections: **Save tools** (reset-all with inline confirmation; set coins/gems/level/XP/stage/piggy balance; clear offer + campaign claim stamps), **Config & experiments** (refetch the stub config; live flag toggles; force any experiment's variant; adjust numeric remote values like banner refresh / round duration / win score), **Systems** (locale switch, music/SFX mirrors of Settings), **Telemetry** (device id, save meta, analytics session, config state — live-updating while open), **Ads** (force refresh; force-fail the next load; live banner state/creative).
- **Flexible controls**: numeric fields (int and float) with validation — invalid input is rejected with a warning and never written; string fields (e.g. player name); enum dropdowns (stage, locale, experiment variants); boolean checkboxes (flags, music/SFX); one-shot action buttons; destructive actions behind an inline confirmation bar; read-only live telemetry rows.
- **Extensible by design**: the panel renders from a declarative control registry owned by DevTools (`get_sections()`). Adding a new control is ONE factory line in the section builder — no UI code changes. New remote-config flags/experiments/values are picked up automatically as controls on the next open (the structure key detects config-structure changes and rebuilds only then).
- **Performance budget**: zero `_process` polling; the overlay is fully inert while closed (hidden, no input handling); the panel is built once and kept alive — each open refreshes control values in place (no allocation churn), and a full rebuild happens only when the config structure (flags/experiments) actually changes. Live updates are signal-driven, never polled.
- Deliberately NO screen-navigation jumps: navigation stays player-driven (DECISIONS.md).
- Strings are English-only by design (a dev tool, not user-facing content — no `tr()`).

## 9. Content & data

### Remote config (resources/config/remote_config.json — the stub "server")
- **Flags**: `banner_ads_enabled`, `daily_gift_enabled`, `events_zone_enabled`, `offers_zone_enabled`, `social_feed_enabled` (all default true).
- **Values**: `gameplay_scene` "" (global gameplay override — empty = per-stage keys, see §5 Stages), `banner_refresh_sec` 30, `target_lifetime_sec` 1.5, `round_duration_sec` 30, `win_score` 150, `daily_gift_coins` 50, `daily_gift_extra_watches` 2, `piggy_bank_capacity` 200, `piggy_deposit_per_stage` 10 (Phase F2), `piggy_redemption_threshold` 150 (Phase F2), `streak_min_rounds_per_day` 1, `streak_rewards` [50, 75, 100, 125, 150], `streak_recovery_coins` 200 (Phase F2), `gift_pile_height` 10, `gift_pile_boxes_per_level` 3, `gift_pile_save_coins` 100, `gift_pile_runs_per_day` 1, `gift_pile_extra_watches` 1, `gift_pile_slot_weights` {coins:45,gems:10,cosmetic:5,fail:40}, `gift_pile_coin_reward` 25, `gift_pile_gem_reward` 3, `gift_pile_cosmetic` "portrait_icon:gold", `gift_pile_jackpot` {kind:"gems",amount:25} (Phase F3), `shards_per_unlock` 20, `gift_pile_shard_reward` 2 (H8 shard partial unlocks), `tournament_points_per_win` 10, `tournament_score_divisor` 25 (Phase F4), `backend_health_sec` 30 (D5b — OnlineService probe cadence, TDD §3.18).
- **Experiments**: see §8. **Shop** (`shop_items` array, Phase F1): stub catalog = one cosmetic per portrait slot + a gems-priced item + repeatable coin-priced items; shape per §6 Shop. **Events** (multiplayer surface): `tournament_weekend` (26h, `kind: "solo_tournament"`, `metadata.tournament_id`, `rewards` rank bands — Phase F4). **Campaigns** (solo mechanics): `double_xp_fri` (modifier 2× xp, 9h), `practice_bonus` (claim 50 coins, evergreen), `streak_bonus` (LIVE streak widget — §8) — shape per §6. **Offers**: `piggy_bank`, `daily_gift` (coins 50 + RV extras), `rv_booster` (gems 5, with cooldown) — each with an `icon` key (`bank`, `gift`, `booster`) that routes to the animated sprite widgets vs code-drawn icons.
- Failure behavior: network/file failure falls back to the last good cache; missing keys fall back to code defaults. Nothing in the UI depends on config being present.

### Mock data inventory (in code, to be replaced by real content)
- Mock user directory + friendships/pending invitations/blocks/join requests (MockSocialBackend local simulation — TDD §3.16); 3 teams with banner recipes, chat lines; team banner LUT palettes (data arrays — the banner ART itself is real, §10); 6/7/4 portrait catalog; 3 rotating ad creatives; ProtoIcon code-drawn icon set; placeholder SpriteFrames for the Daily Gift + Piggy Bank offer widgets.

## 10. Art direction & asset status

- Visual language: dark navy panels (#1b2233 on #10141f), gold accent (#f5c542) for primary/positive, blue (#4f8cff) secondary, light text (#eef2fb / #9aa7c7). All colors come from ThemeFactory (no hardcoded values in UI code).
- **Current art is placeholder by design**: ProtoIcon (code-drawn), PortraitCatalog (code-drawn), offer sprite frames (generic gift/piggybank PNGs + SpriteFrames with `idle` 6-frame loop + `opening` 7-frame one-shot @ 5fps). EXCEPTIONS: team banner bases/icons are REAL sheet-split artwork since 2026-11-06 (90/90, TDD §3.19); the `ui_generic` dialog jar art is real and wired for text dialogs — but its button/tab variants stay UNWIRED (blob silhouettes distort at our control sizes; 2026-11-06 art review), so buttons/tabs use the flat theme.
- Real art integration happens in the collaborative pass; swap points are isolated: ProtoIcon, PortraitView/PortraitCatalog, the two SpriteFrames resources, and `assets/sprites/team_banners/{bases,icons}/` (re-run `tools/split_banner_sheets.py` at the same paths) (TDD §"Service swap seams").
- **Full asset manifest = `documentation/ART_MANIFEST.md`** (Phase G1): every required asset by category (backgrounds, panels/frames, buttons/nav/tabs, cards/widgets, dialogs, toggles/sliders, icons, portraits/flairs/crowns, ad creatives, offer sprites, shop product icons, empty states) with canonical path, size, 9-slice notes, usage sites and swap rules. `tools/gen_placeholders.py` generates functional themed placeholders at those exact paths — real art later drops onto the SAME paths (same pixel size) = zero code changes (Phase G2 rewires the code-drawn catalogs to load them).

## 11. Known design gaps (accepted for prototype)

1. ~~No coin/gem spend sinks~~ — **RESOLVED by the Shop (Phase F1)**: cosmetics + currency items; streak recovery and Gift Pile saves are additional coin sinks.
2. **Stages are mechanically identical** — no per-stage difficulty/content; data-driven stage definitions are planned (TDD).
3. ~~Events are display-only~~ — **RESOLVED by Phase F4**: solo + team tournaments are joinable with live standings (§8 Tournaments); remaining competitive surface (matchmaking/presence/realtime chat/leaderboards) = Phase E.
4. **Online services run on mocks until D5b deploys Nakama** — the v2 social surface (two-way invitations, block/unblock, team creation/settings/access/banners, save sync; TDD §3.16/§3.19) is fully implemented against a local mock simulation, so D5b.2 is a pure backend swap. Accepted prototype gaps: polling-only chat (realtime in Phase E), per-domain LWW save sync (simultaneous devices can lose writes), no competitive hooks yet (Phase E).
5. **Special screen ships as a slot, not content** — `BaseSpecialScreen` + placeholder default; per-prototype seasonal/campaign content is designed and implemented by branching the repo.

## 12. Change protocol

1. Any new/changed feature: **edit this GDD first** (design) and TDD.md (technical contract), then implement.
2. New tunables go in remote config, not code constants.
3. New user-facing strings require en + es translations.
4. New save keys are documented in the TDD save-schema table; breaking changes require a SaveSystem migration.
5. The headless gate (TDD §Verification) must stay green after every change.
