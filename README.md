# BetterQuestPins

World map pins for every quest your character can pick up right now, on the
World of Warcraft Forever client.

- A pin marks each quest giver: NPCs and objects such as wanted posters.
- Only quests you can take now: not done, not in your log, your race and
  class, prerequisites done, not gray, and at most 4 levels above you (a
  setting, from +0 to +10).
- Holiday quests are off by default. Turn them on and only the holidays
  running today, read from the in-game calendar, get pins. World event
  quests are left out.
- Hover a pin to list its quests, coloured by difficulty. Click it to set a
  map waypoint.
- Pins update when you accept, turn in or abandon a quest, or level up.

Turn the pins off or make them smaller under Options > AddOns >
BetterQuestPins.

## Requirements

[QuestieDB](https://www.curseforge.com/wow/addons/questiedb) provides the
quest and quest giver data. BetterQuestPins reads it at runtime and ships
none of it.

## Credits

The quest data comes from
[QuestieDB](https://www.curseforge.com/wow/addons/questiedb) by Lawgon and
TheCrux_BB. Its data started out in
[Questie](https://github.com/Questie/Questie) and was gathered over the years by
Muehe, Drejjmit, Dyaxler, Cheeq, TechnoHunter, Yttrium and more than a hundred
other contributors. Every pin on your map is their work. If BetterQuestPins
helps you, please thank them and support QuestieDB and Questie.

## License

BetterQuestPins is licensed under the GNU GPL v3 or later (see LICENSE). Its
quest blacklist, `Blacklist.lua`, is generated from Questie's own blacklist by
`tools/gen-blacklist.lua` and is used under the GPLv3, as Questie's license
allows.
