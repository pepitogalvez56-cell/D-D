extends Enemy

# =============================================================================
# BULLET MINION GÓTICA (variante) — Teletransporte + patrones
# =============================================================================
# Se teletransporta con frecuencia manteniendo una distancia prudente del
# jugador. Justo tras teletransportarse suelta 2 patrones de HomingBullet
# (un círculo y un triángulo) que NO siguen al jugador. Luego evade hasta que
# se recarga el teletransporte.

@export_group("A distancia")
@export var projectile_scene: PackedScene
@export var projectile_damage: int = 2
@export var safe_distance: float = 380.0
@export var ring_count: int = 10
@export var ring_speed: float = 190.0

@export_group("Teletransporte")
@export var teleport_cooldown: float = 3.0

# Límites del área jugable (ARENA_MIN/ARENA_MAX se heredan de enemy.gd).
const EFFECT_SCENE := preload("res://Scenes/Effect.tscn")

var _tp_timer: float = 0.0

func _ready() -> void:
	super._ready()
	melee_enabled = false
	add_to_group("bullet_minion_gotica")
	_tp_timer = teleport_cooldown * 0.5

func _update_ai(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return

	_tp_timer -= delta
	if not passive and _tp_timer <= 0.0:
		_tp_timer = teleport_cooldown
		_teleport_and_attack()
		return

	# Evadir: mantenerse a distancia segura del jugador (navegación segura).
	var to_player := player.global_position - global_position
	var dist := to_player.length()
	var dir := to_player.normalized()
	if dist < safe_distance:
		velocity = _evasive_velocity(get_speed())
	else:
		velocity = _avoid_bounds(dir.rotated(PI / 2.0) * get_speed() * 0.4)

func _teleport_and_attack() -> void:
	# Humo en el punto de partida (cubre el cuerpo del enemigo).
	_spawn_smoke(global_position)
	Audio.play_at("teleport_enemy", global_position, 0.05, 80, 5.0)   # +5 dB: destaca sobre el golpe

	# Reaparecer a distancia segura del jugador, en un punto dentro del mapa.
	var ang := randf() * TAU
	var pos: Vector2 = player.global_position + Vector2.RIGHT.rotated(ang) * safe_distance
	pos.x = clampf(pos.x, ARENA_MIN.x, ARENA_MAX.x)
	pos.y = clampf(pos.y, ARENA_MIN.y, ARENA_MAX.y)
	global_position = pos
	velocity = Vector2.ZERO

	# Humo en el punto de llegada.
	_spawn_smoke(global_position)

	# Destello de teletransporte.
	sprite.modulate = Color(0.7, 0.4, 1.0)
	var t := create_tween()
	t.tween_property(sprite, "modulate", _base_modulate(), 0.25)

	# 2 patrones: un círculo y un triángulo (ninguno sigue al jugador).
	_fire_pattern(ring_count, 0.0)
	_fire_pattern(3, deg_to_rad(30.0))

func demo_ability() -> void:
	"""Tutorial: solo muestra el teletransporte (humo + reaparición), sin disparar."""
	for i in 3:
		_spawn_smoke(global_position)
		Audio.play_at("teleport_enemy", global_position, 0.05, 80, 5.0)
		var origin: Vector2 = player.global_position if player != null else global_position
		var pos: Vector2 = origin + Vector2.RIGHT.rotated(randf() * TAU) * safe_distance
		pos.x = clampf(pos.x, ARENA_MIN.x, ARENA_MAX.x)
		pos.y = clampf(pos.y, ARENA_MIN.y, ARENA_MAX.y)
		global_position = pos
		_spawn_smoke(global_position)
		sprite.modulate = Color(0.7, 0.4, 1.0)
		var tw := create_tween()
		tw.tween_property(sprite, "modulate", _base_modulate(), 0.25)
		await get_tree().create_timer(1.0).timeout

func _spawn_smoke(pos: Vector2) -> void:
	"""Nube de humo (25.png) escalada para cubrir el cuerpo del enemigo."""
	var host := get_parent()
	if host == null:
		return
	var fx = EFFECT_SCENE.instantiate()
	host.add_child(fx)
	fx.global_position = pos
	# El cuerpo ocupa ~64*sprite_scale px; el fotograma de humo es de 64 px.
	var cover := (64.0 * sprite_scale) / 64.0 * 2.2
	fx.scale = Vector2(cover, cover)
	fx.z_index = 30
	fx.play_effect("dust")

func _fire_pattern(count: int, offset: float) -> void:
	if projectile_scene == null or count <= 0:
		return
	var host := get_parent()
	if host == null:
		return
	for i in count:
		var ang := offset + TAU * float(i) / float(count)
		var p = projectile_scene.instantiate()
		host.add_child(p)
		p.global_position = global_position
		if p.has_method("setup_straight"):
			p.setup_straight(Vector2.RIGHT.rotated(ang), projectile_damage)
			if "speed" in p:
				p.speed = ring_speed
