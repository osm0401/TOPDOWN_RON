class_name LightModel
extends RefCounted
## How well a viewer can make out a target that is already in line of sight (pure).
## Lit rooms: identified. Dark rooms: only inside a flashlight beam, otherwise a close
## silhouette (outline, no identification) or nothing.

enum Seen { NONE, SILHOUETTE, IDENTIFIED }


static func visibility(room_dark: bool, dist: float, in_flash_cone: bool, silhouette_radius: float) -> int:
	if not room_dark or in_flash_cone:
		return Seen.IDENTIFIED
	if dist <= silhouette_radius:
		return Seen.SILHOUETTE
	return Seen.NONE
