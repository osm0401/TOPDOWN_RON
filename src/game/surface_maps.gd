extends RefCounted
## Photo textures for surface.gdshader materials: a picture of the surface and, when present, its
## normal, roughness and occlusion maps, all from one model set folder:
##   <folder><set>/<key>.png (or .jpg)          colour (required for the others to be used)
##   <folder><set>/<key>_normal.png             normal map, OpenGL style (green up)
##   <folder><set>/<key>_rough.png              roughness (grey: black shiny, white matte)
##   <folder><set>/<key>_ao.png                 ambient occlusion (grey: black in the cracks)
## Files are read without the editor's import when they have none. No class_name: preloaded.

const MAPS := {"normal": ["use_normal", "tex_normal"], "rough": ["use_rough", "tex_rough"], "ao": ["use_ao", "tex_ao"]}


## A picture `name` from the set (png or jpg), null when there is none. srgb false: data maps
## (normal, roughness, occlusion) are read as stored.
static func load_tex(folder: String, set_name: String, name: String) -> Texture2D:
	if set_name == "":
		return null
	for ext in ["png", "jpg"]:
		var path := "%s%s/%s.%s" % [folder, set_name, name, ext]
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(path))
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				return ImageTexture.create_from_image(img)
	return null


## Gives material `m` the picture of `key` and whatever maps go with it. Returns the map names
## used ("albedo", "normal", "rough", "ao"); empty when the set has no picture of `key`.
static func apply(m: ShaderMaterial, folder: String, set_name: String, key: String) -> Array[String]:
	var used: Array[String] = []
	var tex := load_tex(folder, set_name, key)
	if tex == null:
		return used
	m.set_shader_parameter("use_tex", true)
	m.set_shader_parameter("tex_albedo", tex)
	used.append("albedo")
	for map: String in MAPS:
		var t := load_tex(folder, set_name, key + "_" + map)
		if t != null:
			m.set_shader_parameter(MAPS[map][0], true)
			m.set_shader_parameter(MAPS[map][1], t)
			used.append(map)
	return used
