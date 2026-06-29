# Flutter/UI Audit: Notees Mobile

**Date:** 2026-06-29  
**Auditor:** Kimi Code CLI  
**Scope:** `lib/` theme, presentation, providers, native helpers, `app.dart`, `main.dart`, `pubspec.yaml`, `AGENTS.md`, Android build config.  
**Reference:** Attire app at `/Proyectos/app-fleet/attire`.

This audit applies the RosellRamos design-system skills (`design-system`, `ui-ux-audit`, `flutter-audit`, `flutter-ui-patterns`, `accessibility-primer`) to the Notees Flutter app.

## Baseline checks

- `docker compose run --rm flutter flutter analyze` → **No issues found**.
- `flutter_lints` is enabled.
- The app broadly follows the fleet theme, uses `FleetCard`, and has haptics in the right places.

The main blockers before release are crash-prone async gaps, hardcoded accent colors, sub-48dp touch targets, and missing icon-button tooltips.

---

## Critical (must fix)

### 1. Missing `mounted` guards after async gaps

Several screens call `setState` after `await` without checking `mounted`. If the widget is disposed while the future is pending, this throws.

Representative spots:

- `lib/presentation/screens/tasks_screen.dart:47-50` — `_loadTasks`
- `lib/presentation/screens/api_keys_screen.dart:35,57,89` — `_loadKeys`, `_createKey`, `_revokeKey`
- `lib/presentation/screens/node_editor_screen.dart:105-124` — `_loadPage`
- `lib/presentation/screens/dashboard_screen.dart:77,129,166` — `_loadDashboard`, `_archiveBlock`, `_deleteBlock`
- `lib/presentation/screens/user_profile_screen.dart:64,108` — `_saveProfile`, `_changePassword`
- `lib/presentation/screens/server_setup_screen.dart:37,75` — `_loadServers`, `_saveServer`
- `lib/presentation/screens/journal_screen.dart:50,69,88` — `_loadJournals`, `_openToday`, `_openDate`
- `lib/presentation/screens/pages_screen.dart:64,158` — `_loadPages`, `_createPage`
- `lib/presentation/screens/search_screen.dart:241-265` — `_search`
- `lib/presentation/screens/templates_screen.dart:42,87` — `_loadTemplates`, `_onTemplateTap`
- `lib/presentation/screens/notifications_screen.dart:36,56,72` — `_loadNotifications`, `_markRead`, `_markAllRead`
- `lib/presentation/screens/server_management_screen.dart:33,45` — `_loadServers`, `_switchServer`
- `lib/presentation/screens/archived_screen.dart:42,62` — `_loadArchived`, `_unarchive`
- `lib/presentation/screens/trash_screen.dart:40,60,101,172` — `_loadTrash`, `_restoreNode`, `_deleteNode`, `_emptyTrash`

**Fix:** Wrap every post-await `setState` with `if (mounted)`. Capture `context.read<...>()` before the first `await`.

### 2. Hardcoded colors outside the theme

- `lib/presentation/screens/settings_screen.dart:969` — `_AccentSwatch` uses `Colors.white` (invisible in light mode).
- `lib/presentation/screens/settings_screen.dart:975` — `_AccentSwatch` uses `const Color(0xFF5B7D5B)` instead of the existing `noteesAccent` constant.
- `lib/presentation/widgets/block_tree_editor.dart:402-406` — callout colors use `Colors.orange`, `Colors.green`, `Colors.blue`, `Colors.teal`.
- `lib/core/utils/color_presets.dart:11-22,25,34,40` — hardcoded note-color presets and `Colors.black87`/`Colors.white` foreground.

**Fix:** Use `Theme.of(context).colorScheme` or the constants in `lib/core/theme/app_colors.dart`. For callouts, derive from semantic scheme roles (`error`, `primary`, `tertiary`, `outline`).

### 3. Touch targets below 48 dp

- `lib/presentation/screens/settings_screen.dart:926-927` — `_ThemeButton` is `36 × 36`.
- `lib/presentation/screens/settings_screen.dart:1012-1013` — `_AccentSwatch` is `28 × 28`.
- `lib/presentation/widgets/quick_capture_sheet.dart:346-348` — `_ColorButton` is `32 × 32`.
- `lib/presentation/widgets/block_tree_editor.dart:618` — bullet/drag handle width is `28`.
- `lib/presentation/widgets/block_tree_editor.dart:589-595` — `_BlockToolbarButton` is `36 × 36`.

**Fix:** Wrap these in a `ConstrainedBox(minWidth: 48, minHeight: 48)` or add sufficient `InkWell`/`IconButton` padding.

### 4. Icon-only buttons missing tooltips / semantic labels

- `lib/presentation/screens/login_screen.dart:101-108` — password visibility toggle.
- `lib/presentation/screens/user_profile_screen.dart:220,232,244` — password visibility toggles.
- `lib/presentation/screens/dashboard_screen.dart:287-290` — date-picker close button.
- `lib/presentation/screens/search_screen.dart:340-347` — clear-search button.
- `lib/presentation/screens/search_screen.dart:368-376` — filter button.
- `lib/presentation/screens/api_keys_screen.dart:180-183` — delete-key button.
- `lib/presentation/screens/settings_screen.dart:695,746,797` — close buttons in picker sheets.
- `lib/presentation/widgets/node_picker.dart:133` — close button.

**Fix:** Add `tooltip: '...'` to every icon-only `IconButton`.

### 5. Dynamic color can tint the monochrome surface layer

`lib/core/theme/theme_builder.dart:28-46` builds the scheme with `ColorScheme.fromSeed(seedColor: accent)`. When the user chooses the functional accent or dynamic color, Material derives `surfaceContainer*` values from that seed, which breaks the RosellRamos rule that Layer 1 surfaces stay grayscale.

Attire solves this by first building an explicit monochrome `ColorScheme`, then overlaying only primary/primaryContainer roles while keeping surfaces gray.

**Fix:** Override every `surfaceContainerLowest/Low/Container/High/Highest` to the fleet grayscale values (see Attire’s `lib/main.dart:144-152`) and set `surfaceTint: Colors.transparent`.

### 6. Tappable inline node links are invisible to screen readers

`lib/presentation/widgets/ast_rich_text.dart:172` wraps node links in a `GestureDetector` with no `tooltip` or `Semantics` label. TalkBack/VoiceOver users won’t know the link is tappable.

**Fix:** Wrap the chip in `Semantics(button: true, label: 'Link to $label', child: ...)`.

### 7. No undo after destructive list dismissals

`lib/presentation/screens/dashboard_screen.dart:436-471` and `lib/presentation/views/inbox_card_view.dart:90-150` swipe-to-delete/archive without showing an `Undo` SnackBar. The fleet component checklist requires undo after deletion.

**Fix:** Show a `SnackBar` with `SnackBarAction(label: 'Undo', ...)` after delete/archive, and only commit the action after the SnackBar closes or undo is not tapped.

---

## Warnings (should fix)

### 8. Bottom-sheet styling inconsistent

- `lib/presentation/widgets/filter_bottom_sheet.dart:53` uses `Radius.circular(24)` instead of the fleet `28`.
- `lib/presentation/widgets/filter_bottom_sheet.dart:21` sets `backgroundColor: Colors.transparent` and rebuilds the surface manually; this bypasses `BottomSheetThemeData`.
- Most other sheets (`node_picker.dart`, `view_mode_sheet.dart`, `command_palette.dart`, `slash_command_palette.dart`, `comments_bottom_sheet.dart`, `shares_bottom_sheet.dart`, `audio_recorder_sheet.dart`, dashboard action sheets) do not render a custom drag handle and do not set `showDragHandle: true`.

**Fix:** Rely on `BottomSheetThemeData` (radius `28`, surface color, transparent tint) and add the fleet custom drag handle (`32 × 4`, radius `2`, `onSurfaceVariant @ 35%`) or set `showDragHandle: true` consistently.

### 9. Elevation used in drag feedback

`lib/presentation/widgets/block_tree_editor.dart:522` uses `Material(elevation: 3, ...)` for drag feedback.

**Fix:** Use `elevation: 0` and rely on a surface color + outline, matching the zero-elevation rule.

### 10. Reduced motion is not respected

- `lib/presentation/widgets/offline_banner.dart:19` — `AnimatedCrossFade` always animates.
- `lib/presentation/widgets/block_tree_editor.dart:279` — `AnimatedContainer` always animates.

**Fix:** Skip or shorten animations when `MediaQuery.of(context).disableAnimations` is true.

### 11. Missing haptics on common interactions

Haptics are good in providers and many screens, but missing in several high-traffic places:

- `lib/presentation/screens/main_shell_screen.dart:124` — bottom-nav selection.
- `lib/presentation/widgets/editor_inline_toolbar.dart:151-157` — toolbar buttons.
- `lib/presentation/views/node_list_view.dart:58` / `node_card_view.dart:53` / `node_table_view.dart:149` / `node_kanban_view.dart:311` — favorite toggles.
- `lib/presentation/views/node_calendar_view.dart:210-224` — month navigation.
- `lib/presentation/widgets/filter_bottom_sheet.dart:121-138,152-163,186-206` — chips, date tile, dropdown.
- `lib/presentation/widgets/view_mode_sheet.dart:60` — view-mode selection.
- `lib/presentation/widgets/comments_bottom_sheet.dart:156-159` — send/delete comment.

**Fix:** Add `HapticFeedback.lightImpact()` on tap, `mediumImpact()` for destructive actions.

### 12. Error text uses hardcoded font size

- `lib/presentation/screens/login_screen.dart:134`
- `lib/presentation/screens/server_setup_screen.dart:191`
- `lib/presentation/screens/dashboard_screen.dart:401`
- `lib/presentation/screens/user_profile_screen.dart:179,255`

**Fix:** Use `Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.error)`.

### 13. Card / surface token choices differ from the fleet reference

- `lib/core/theme/theme_builder.dart:84-93` sets card background to `surfaceContainerHighest`; Attire and the fleet checklist use `surfaceContainer`.
- `lib/core/theme/theme_builder.dart:153-164` bottom-sheet/dialog themes do not set `surfaceTintColor: Colors.transparent`.
- `lib/core/theme/theme_builder.dart:123-147` `InputDecorationTheme` border radius is `16`; fleet tokens specify `12`.

**Fix:** Align card background, surface tint, and input radius with the fleet tokens.

### 14. `ArchivedScreen` card does not use the fleet radius

`lib/presentation/screens/archived_screen.dart:153-161` builds a `Card` with `BorderRadius.circular(16)` instead of `20`.

**Fix:** Use the shared `FleetCard` widget or `BorderRadius.circular(20)`.

### 15. Empty-state widget deviates from fleet pattern

`lib/presentation/widgets/empty_state.dart:27` uses a `64` px icon and `titleMedium` for the heading. The fleet empty-state pattern is a `48` px muted icon with `titleLarge`/`bodyLarge` heading and `bodyMedium` subtitle.

**Fix:** Resize icon to `48` and use `titleLarge` for the heading.

### 16. No tablet / landscape adaptation

`lib/presentation/screens/main_shell_screen.dart` always uses `NavigationBar`. Attire switches to `NavigationRail` at `600 dp` and uses responsive grid breakpoints at `600 dp` / `840 dp`.

**Fix:** Add a width-aware navigation rail and responsive grid columns for tablets/foldables.

### 17. Missing fleet dependency

`pubspec.yaml` does not include `material_design_icons_flutter`, and the app uses built-in `Icons.*` everywhere. The fleet rules list `material_design_icons_flutter: ^7.0.7296` as a required dependency; Attire uses it consistently.

**Fix:** Add the dependency and migrate icons to `MdiIcons.*` for fleet consistency.

---

## Notes (consider)

- `lib/core/utils/color_presets.dart` hardcodes note colors that match the web app. This is acceptable as data-level metadata, but document that these are content colors, not theme colors.
- `lib/core/theme/app_colors.dart:14,17` defines `noteesAccentBeige` and `noteesAccentLegacy` that appear unused. Remove or use them.
- `lib/presentation/screens/about_screen.dart:94` privacy text adds “and your self-hosted Notees server.” The fleet About screen expects exactly “No cloud. All data stays on your device.” Consider aligning the wording with the fleet template.
- `lib/main.dart:23-26` locks the app to portrait. That’s fine for a phone-first v1, but document it as intentional.
- The app is English-only with no `.arb`/AppLocalizations setup. Fine for an initial release, but plan i18n before wider rollout.
- `package_info_plus` is pinned to `^10.2.0`; the fleet rules reference `^9.0.1`. This is not a problem if the newer version works, but keep an eye on drift from the fleet dependency baseline.
- Many settings list tiles use built-in `Icons` rather than `MdiIcons`. If you adopt the fleet icon dependency, migrate these too.

---

## Repository Hygiene

| Check | Status |
|---|---|
| `AGENTS.md` present | ✅ Yes, but less detailed than Attire’s (missing exact privacy URL, surface hex values, and settings widget specs) |
| No `PRIVACY_POLICY.md` / embedded privacy screens | ✅ None found |
| No secrets / `.env` / keystores committed | ✅ None found |
| Android signing config | ✅ Debug keystore committed; release left unsigned for CI (`android/app/build.gradle.kts:28-48`) |
| About / copyright / privacy strings | ✅ `lib/presentation/screens/about_screen.dart:73,93-98` |
| No IAP / paywalls / subscriptions | ✅ None found |
| `flutter analyze` | ✅ No issues |
| `flutter_lints` enabled | ✅ `analysis_options.yaml` |

---

## What Attire does that Notees should adopt

From the reference app in `/Proyectos/app-fleet/attire`:

1. **Explicit monochrome surface palette** — `lib/main.dart:44-152` builds a fully manual grayscale `ColorScheme` and overrides `surfaceContainer*` values, so dynamic color only affects accent roles.
2. **No splash** — Attire sets `splashFactory: NoSplash.splashFactory` in the theme.
3. **Bottom-sheet discipline** — every sheet uses `isScrollControlled: true`, `showDragHandle: false`, a custom `32 × 4` drag handle, `SafeArea`, and `viewInsets.bottom` padding.
4. **MdiIcons everywhere** — `material_design_icons_flutter` is a first-class dependency.
5. **Undo on delete** — Dismissible delete in lists shows a `SnackBar` with an `Undo` action.
6. **Responsive navigation** — `NavigationRail` at `600 dp`, grids at `600/840 dp`.
7. **Settings appearance card** — Theme → Accent → Pure Black, with reusable `_ThemeModeSelector`, `_AccentColorPicker`, `_DeepDarkSwitch`, and `_SectionTitle` widgets.
8. **Haptics on nearly every tap**, with `mediumImpact` reserved for delete/reset.

---

## Positive findings

- `lib/core/theme/theme_builder.dart` is comprehensive: `useMaterial3: true`, sage accent `#5B7D5B`, monochrome intent, elevation `0` on cards, app bars, nav bars, FABs, bottom sheets, dialogs, snack bars, and chips.
- `lib/presentation/widgets/fleet_card.dart` implements the fleet card style correctly: radius `20`, elevation `0`, 10% outline.
- Most sheets already use `BorderRadius.vertical(top: Radius.circular(28))`.
- `HapticFeedback.lightImpact()` / `mediumImpact()` is used in many screens and providers.
- Text/scroll/focus/animation controllers are disposed consistently.
- Many `IconButton`s already have meaningful `tooltip` values.
- Tokens and credentials are stored via `flutter_secure_storage`; biometric lock is wired through `BiometricProvider` and `AppLocker`.
- The CI/build setup leaves release APKs unsigned for GitHub Actions signing.

---

## Recommended next steps

1. Fix the `mounted` guards and hardcoded accent colors first — these are real crash and consistency bugs.
2. Add tooltips to the icon-only buttons listed above and increase the sub-48dp touch targets.
3. Harden the theme so dynamic/accent colors cannot tint surfaces.
4. Add consistent bottom-sheet drag handles and correct the `FilterBottomSheet` radius.
5. Add undo after delete/archive swipe and respect reduced-motion settings.
6. Then consider the Attire-adoptable improvements: `material_design_icons_flutter`, tablet rail, and responsive grids.
