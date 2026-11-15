# LevelScout

A leveling quest tracker for **WoW Forever**. It replaces the default quest tracker with one window that shows what to do next to level up efficiently:

- **XP bar and pace**: your XP and rested XP, XP needed for the next level, how much of it the quests in your current zone cover, and (once you've played a while) XP per hour and an estimated time to level. It also shows how full your quest log is.
- **Completed quests**: split into "turn in here" and "turn in elsewhere", with the NPC, zone and coordinates for each turn-in.
- **Quests in your current zone**: with objective progress, sorted by XP. Quests you've already made progress on sort to the top.
- **Pick up here**: quests in this zone you can accept but haven't yet, ranked by XP (requires Questie).
- **Dungeon (group) quests**, with the game's real XP rewards.
- **Quests in other zones**, grouped by zone.
- **Low value quests** you could abandon: gray, PvP, or worth very little XP with no worthwhile follow-ups.
- **Next zones**: the best zones near your level by available quest XP.

Quest XP shown in gray after a quest (for example `+3.2k`) is the XP from the quests it leads to, so you can tell whether a low-level quest starts a chain worth doing.

It also **tags quest links in chat**: when someone posts a quest in General or LFG and you're on it, the link gets a green check and your progress, like `[ON QUEST 2/15]`. No tag means you don't have it (or you've already done it).

## Install

1. Download the repository (**Code → Download ZIP**, or `git clone`).
2. Put it in your AddOns folder **as a folder named `LevelScout`**. WoW only loads it if the folder name matches `LevelScout.toc`.
   - Windows: `World of Warcraft\_forever_\Interface\AddOns\LevelScout\`
   - macOS: `/Applications/World of Warcraft/_forever_/Interface/AddOns/LevelScout/`

   If you downloaded a ZIP, rename the extracted `levelscout-main` folder to `LevelScout`.
3. Restart the game client fully. A `/reload` is not enough for a newly added addon.

### Recommended addons

| Addon | Why |
|---|---|
| **Questie** | Turn-in locations, quest chains and estimated XP, "Pick up here" and "Next zones". LevelScout still works without it, but those parts will be empty. |
| **TomTom** | Clicking a quest sets a TomTom waypoint. Without it you get a pin on the world map. |

## First-time setup

- **Hide Questie's own tracker** if you use Questie (Questie options → Tracker). LevelScout hides Blizzard's default quest tracker for you; this can be turned off in the options.
- **Give it ~20 seconds after login.** LevelScout waits for Questie to finish loading, then scans Questie's database for quests near your level. "Pick up here" and "Next zones" fill in after that. It re-scans automatically when you level up, or click **R** in the window's title bar.

## Using it

- `/scout ui`: show or hide the window. You can also left-click **LevelScout** in the addon menu by the minimap; right-clicking it opens the options.
- **Click a quest** to set a waypoint to its turn-in NPC (or, in "Pick up here", to the quest giver).
- **Hover a quest** for its objectives, type, turn-in location and the full list of follow-up quests with XP.
- **Click a section title** to collapse or expand it.
- Drag the title bar to move the window and the bottom-right corner to resize it.

Colors follow WoW's difficulty colors (red, orange, yellow, green, gray). `[D]` marks dungeon quests and `[G]` elite or group quests.

Other commands:

| Command | What it does |
|---|---|
| `/scout` | Take a fresh snapshot and re-scan Questie |
| `/scout zones` | Print the best zones for your level in chat |
| `/scout config` | Open the options |
| `/scout lock` | Lock or unlock the window |
| `/scout compact` | Toggle objective lines for quests in other zones |
| `/scout resetui` | Put the window back in its default position |
| `/scout status` | What's been captured so far |
| `/scout reset` | Clear this character's XP history |

## Options

Esc → Options → AddOns → **LevelScout**:

- **Main**: show the window, hide the default quest tracker, lock, background opacity, reset position.
- **Tracker**: one or two "completed" groups, which sections to show, how many pickups to list, progress-first sorting, compact mode.
- **Chat**: tag quest links, also tag quests you could pick up or have already done, play a sound when a linked quest is one you're on.
- **Data**: automatic Questie scan on login and level-up, re-scan now, clear XP history.

Settings are shared across your characters.

## Data it saves

LevelScout keeps a snapshot of your character, quest log, gear, completed quests, the Questie scan, and a history of your XP gains, quest turn-ins and level-ups. This is what powers the XP-per-hour figure, and it can be read outside the game for planning. It's written to `WTF/Account/<account>/SavedVariables/LevelScout.lua` when you `/reload` or log out. Nothing is sent anywhere.

## How accurate is it?

- **XP for quests in your log** comes from the game itself, so it's exact.
- **XP for quests you haven't picked up** comes from Questie's estimates. For some quests (often dungeon quests and new Forever quests) the real reward is noticeably higher.
- **Chat tags** only apply to new messages, and WoW Forever sometimes hides chat content from addons (for example in some instance situations). Those messages show normally, without a tag.

## Troubleshooting

- **The window doesn't appear:** type `/scout ui`. If it was closed with the X button, it stays hidden until you show it again.
- **"Pick up here" or "Next zones" are empty:** make sure Questie is enabled, wait ~20 seconds after login, or click **R**.
- **Errors:** LevelScout records them instead of popping up error windows. They're saved in `SavedVariables/LevelScout.lua` under `errors` (and unexpected window hides under `hideLog`), which is useful to include in a bug report.

## License

MIT, see `LICENSE`.
