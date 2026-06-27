extends Enemy

# =============================================================================
# BULLET MINION SAD (variante) — Contrarresta las SpinShots del jugador
# =============================================================================
# Mantiene la distancia con el jugador. Tiene un "escudo" (radio) que tiene un
# 25% de probabilidad de eliminar cada SpinShot del jugador que entre en él.
# Lleva la cuenta de cuántas ha eliminado; al llegar a un umbral, transforma
# esas balas en un patrón circular de HomingBullet (que NO siguen al jugador).

@export_group("A distancia")
@export var projectile_scene: PackedScene
@export var projectile_damage: int = 2
@export var preferred_distance: float = 320.0
@export var distance_margin: float = 60.0
@export var ring_speed: float = 200.0

@export_group("Escudo anti-SpinShot")
@export var shield_radius: float = 80.0
@export var eat_chance: float = 0.25     # 1/4 de eliminar cada SpinShot que toca
@export var rage_threshold: int = 6      # balas a comer antes de soltar el patrón

const EFFECT_SCENE := preload("res://Scenes/Effect.tscn")

# Marca de "invocado por el minijefe" (efecto visual distinto).
var is_summon: bool = false

var _eaten: int = 0
var _seen: Dictionary = {}

func _ready() -> void:
	super._ready()
	melee_enabled = false
	add_to_group("bullet_minion_sad")

func _update_ai(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return
	var to_player := player.global_position - global_position
	var dist := to_player.length()
	var dir := to_player.normalized()
	# Mantener la distancia con el jugador (evasivo).
	if dist < preferred_distance - distance_margin:
		velocity = _evasive_velocity(get_speed())
	elif dist > preferred_distance + distance_margin:
		velocity = dir * get_speed()
	else:
		velocity = _avoid_bounds(dir.rotated(PI / 2.0) * get_speed() * 0.5)

	if not passive:
		_update_shield()

func _update_shield() -> void:
	for b in get_tree().get_nodes_in_group("spin_bullet"):
		if not is_instance_valid(b):
			continue
		if global_position.distance_to(b.global_position) > shield_radius:
			continue
		var id := b.get_instance_id()
		if _seen.has(id):
			continue
		_seen[id] = true   # cada SpinShot solo se evalúa una vez
		if randf() < eat_chance:
			b.queue_free()
			_spawn_smoke()   # feedback visual al eliminar la SpinShot
			Audio.play("sad_eat", 0.06, 60)   # sonido al desaparecer la spinbullet
			_eaten += 1
			if _eaten >= rage_threshold:
				_release_ring(_eaten)
				_eaten = 0

func _spawn_smoke() -> void:
	"""Humo (mismo efecto que la gótica) pero con un TINTE distinto, al eliminar
	una SpinShot del jugador."""
	var host := get_parent()
	if host == null:
		return
	var fx = EFFECT_SCENE.instantiate()
	host.add_child(fx)
	fx.global_position = global_position
	var cover := (64.0 * sprite_scale) / 64.0 * 2.0
	fx.scale = Vector2(cover, cover)
	fx.modulate = Color(0.5, 0.9, 1.0)   # tinte cian (distinto al humo de la gótica)
	fx.z_index = 30
	fx.play_effect("dust")

func demo_ability() -> void:
	"""Tutorial: durante unos segundos se come las SpinShots del jugador que
	entren en su escudo y luego suelta su anillo especial, sin moverse."""
	var frames := 0
	while frames < 240:   # ~4 s comiendo SpinShots
		_update_shield()
		await get_tree().process_frame
		frames += 1
	_release_ring(maxi(rage_threshold, 8))
	await get_tree().create_timer(0.6).timeout

func _release_ring(count: int) -> void:
	if projectile_scene == null or count <= 0:
		return
	var host := get_parent()
	if host == null:
		return
	for i in count:
		var ang := TAU * float(i) / float(count)
		var p = projectile_scene.instantiate()
		host.add_child(p)
		p.global_position = global_position
		if p.has_method("setup_straight"):
			p.setup_straight(Vector2.RIGHT.rotated(ang), projectile_damage)
			if "speed" in p:
				p.speed = ring_speed

func _base_modulate() -> Color:
	# Los invocados por el minijefe llevan un tinte morado para distinguirlos.
	if is_summon and _buff_amount <= 0 and _buff_speed_mult <= 1.0:
		return Color(0.7, 0.5, 1.0)
	return super._base_modulate()
