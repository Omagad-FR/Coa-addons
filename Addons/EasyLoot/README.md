# EasyLoot

A lightweight World of Warcraft addon that simplifies loot management.

Built for WoW 3.3.5a (Interface 30300, WoW Classic-era private servers). Server-agnostic — no dependency on any particular project or realm.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/YOUR_KOFI_HANDLE)

## What it does

- **Bag scan** — lists equipable epic items in your bags, with a report of what got filtered out and why (nothing disappears silently).
- **Locks** — right-click any item to lock it, protecting your own gear from being announced by accident. Locks persist across sessions.
- **Raid announce** — one click sends the item as a full-screen raid warning (`/rw`), a raid-chat message, or a custom slash command, then opens a roll window.
- **Roll capture** — reads `/roll` results straight from the game's system messages (locale-independent), with a chat-based fallback for players who type their number instead. Sorts rolls, flags the winner, and calls out ties.
- **Click-to-select winner** — click any roll line to fill the recipient field with that player instead of typing a name by hand.
- **Real distribution tracking** — a persistent history of who *actually* received each item, separate from who merely won the roll. Confirm automatically (arm a pending trade, and EasyLoot places the item as soon as you open a trade window with the right player) or manually.
- **Double-loot badges** — every roll shows a badge (green `+1` / orange `+2` / red `+3+`) based on that player's full loot history, so you can spot a double-dip across multiple bosses in the same raid night. Reset it by hand between raid nights (`/easyloot historique reset`).
- **Minimap button** — drag it anywhere around the minimap; left-click toggles the panel.

## Install

Copy the `EasyLoot` folder into `Interface\AddOns\`, then `/reload`.
Open the panel with `/easyloot` (or `/elraid`).

## Support

If EasyLoot saves you time in raid, you can buy me a coffee on [Ko-fi](https://ko-fi.com/YOUR_KOFI_HANDLE) — totally optional, the addon stays free either way.

## License

See repository for license details.
