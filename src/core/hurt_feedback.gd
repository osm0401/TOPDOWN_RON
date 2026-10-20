class_name HurtFeedback
extends RefCounted
## How strongly being hurt shows and sounds (pure, tested headless): the red screen rim
## (ScreenFx) and the hard breathing (GameAudio).


## 0..1 for the red rim: nothing at `below` of full health or more, nothing once dead.
static func rim(hp: int, max_hp: int, below: float) -> float:
	if hp <= 0 or max_hp <= 0:
		return 0.0
	return clampf(1.0 - float(hp) / (float(max_hp) * below), 0.0, 1.0)


## 0..1 for the breathing: 0 at `below` of full health or more, a light 0.2 just under it,
## 1 near death.
static func breath(hp: int, max_hp: int, below: float) -> float:
	if max_hp <= 0 or hp <= 0:
		return 0.0
	var f := float(hp) / float(max_hp)
	if f > below:
		return 0.0
	return clampf(1.0 - f / below, 0.0, 1.0) * 0.8 + 0.2
