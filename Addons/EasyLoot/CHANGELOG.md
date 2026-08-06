# EasyLoot Changelog

## 0.5.3
- Added a minimap button (custom implementation, no external library): left-click toggles the panel, drag repositions it around the minimap. Position is saved (`EasyLootDB.minimapAngle`) and survives `/reload`.
- New command: `/easyloot minimap on|off` to show/hide the button.

## 0.5.2
- Roll lines and the winner line now show a loot badge: `+1` (green, never looted), `+2` (orange, already got one piece), `+3+` (red, two or more). The badge is computed from the full distribution history, so it holds across multiple bosses in the same raid night.
- History never clears on its own — added `/easyloot historique reset` and a "Vider" (Clear) button in the History window, with a confirmation popup, to reset between two raid nights.
- Fixed a nil-index error (`recipientEditBox`) thrown when clicking a roll line, caused by a local variable used before its declaration.

## 0.5.1
- Roll lines in the session panel are now clickable: clicking a player's roll fills the Recipient field with that name instead of typing it manually (avoids typos and realm-suffix mismatches). The matching line is highlighted.

## 0.5.0
- New persistent distribution history: tracks who *actually* received each item (not just who won the roll), with two ways to confirm a distribution:
  - **Automatic**: "Preparer l'echange" arms a pending trade — once a trade window opens with the expected recipient, EasyLoot places the item in a free trade slot by itself; the trade itself is still confirmed manually by both sides. Once the game reports "Trade complete.", the entry is logged automatically.
  - **Manual**: "Confirmer distribution" logs the item to whatever name is in the Recipient field immediately, for hand-delivered items or ML decisions made without a roll.
- New "Historique" window listing every confirmed distribution (item, recipient, method, time), most recent first — the reliable source for "who already got loot", separate from just winning a roll.
- Recipient field auto-fills with the roll winner, but stays editable.
- New command: `/easyloot autotrade on|off` to toggle automatic item placement in the trade window.
- New command: `/easyloot historique` to print the last 10 distributions to chat.

## 0.4.1 and earlier
- Bag scan (epic items only), persistent per-item locks, raid warning / raid chat / slash announce modes, roll capture from `CHAT_MSG_SYSTEM` and raid/party chat, winner detection with tie handling.
