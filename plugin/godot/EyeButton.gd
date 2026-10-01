extends Button

var collapsed = false setget set_collapsed

func set_collapsed(value):
	collapsed = value
	hint_tooltip = "展开实验室" if value else "隐藏实验室"
	update()

func _draw():
	var center = rect_size * 0.5
	var color = Color("c7d8ef")
	var outline = PoolVector2Array()
	for i in 33:
		var angle = TAU * i / 32.0
		outline.append(center + Vector2(cos(angle) * 13, sin(angle) * 7))
	draw_polyline(outline, color, 1.8, true)
	draw_circle(center, 3.5, color)
	if collapsed:
		draw_line(center + Vector2(-14, 11), center + Vector2(14, -11), color, 2.0, true)
