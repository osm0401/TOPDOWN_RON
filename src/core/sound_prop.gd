class_name SoundProp
extends RefCounted
## Sound travel rules (pure). A sound is heard when
##   distance + penalties(walls, closed doors, ajar doors) <= radius * hearing multiplier.
## A closed door costs more than a wall (decided rule), an ajar door much less.

enum Kind { FOOTSTEP, GUNSHOT, DOOR, KICK, VOICE, SCREAM, TASER, DOOR_AJAR }

const NAMES: Array[String] = ["footstep", "gunshot", "door", "kick", "voice", "scream", "taser", "door_ajar"]


static func effective_distance(dist: float, blockers: Dictionary, penalty: Dictionary) -> float:
	return dist \
		+ int(blockers.get("walls", 0)) * float(penalty["wall"]) \
		+ int(blockers.get("closed", 0)) * float(penalty["door_closed"]) \
		+ int(blockers.get("ajar", 0)) * float(penalty["door_ajar"])


static func is_heard(dist: float, blockers: Dictionary, penalty: Dictionary, radius: float, hearing_mult: float) -> bool:
	return effective_distance(dist, blockers, penalty) <= radius * hearing_mult


## 0..1, how clearly the sound arrives (1 = right at the source).
static func loudness(dist: float, blockers: Dictionary, penalty: Dictionary, radius: float, hearing_mult: float) -> float:
	var reach := radius * hearing_mult
	if reach <= 0.0:
		return 0.0
	return clampf(1.0 - effective_distance(dist, blockers, penalty) / reach, 0.0, 1.0)
