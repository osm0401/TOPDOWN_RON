class_name ScoreRules
extends RefCounted
## Score and grade from event counts (pure). All numbers live in data/score.json and are
## prototype values: start score, per-event penalties and the A..F boundaries.


## extra: counts the mission state does not keep (unreported, evidence_missed: from the NPCs).
static func counts(m: MissionState, players_dead: int, extra: Dictionary = {}) -> Dictionary:
	var c := {
		"suspect_killed": m.suspect_killed,
		"civilian_killed": m.civ_killed,
		"enemy_killed": m.enemy_killed,
		"player_dead": players_dead,
	}
	c.merge(extra)
	return c


static func compute(c: Dictionary, rules: Dictionary) -> int:
	var total := int(rules["start"])
	var penalties: Dictionary = rules["penalties"]
	for key in penalties:
		total -= int(c.get(key, 0)) * int(penalties[key])
	return maxi(total, 0)


static func grade(score: int, rules: Dictionary) -> String:
	for g in rules["grades"]:
		if score >= int(g[1]):
			return str(g[0])
	return "F"


## One text line per event that happened: "민간인 사살 x1: -30" or "... 감점 없음".
static func breakdown(c: Dictionary, rules: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var penalties: Dictionary = rules["penalties"]
	var labels: Dictionary = rules["labels"]
	for key in penalties:
		var n := int(c.get(key, 0))
		if n <= 0:
			continue
		var cost := n * int(penalties[key])
		lines.append("%s x%d: %s" % [labels.get(key, key), n, ("-%d" % cost) if cost > 0 else "감점 없음"])
	return lines
