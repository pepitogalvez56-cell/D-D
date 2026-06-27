extends Enemy

# =============================================================================
# BULLET MINION — Enemigo a distancia
# =============================================================================
# Mantiene la distancia con el jugador y le dispara un proyectil TELEDIRIGIDO
# cada cierto tiempo (avisando con un parpadeo rojo antes de disparar). Además,
# cada cierto tiempo lanza un patrón en CÍRCULO de proyectiles que NO siguen al
# jugador (vuelan en línea recta).

@export_group("Ataque a distancia")
@export var projectile_scene: PackedScene
@export var projectile_damage: int = 2
@export var fire_interval: float = 2.2
@export var telegraph_time: float = 0.5      # Aviso (parpadeo rojo) antes de disparar
@export var preferred_distance: float = 300.0
@export var distance_margin: float = 60.0

@export_group("Patrón circular")
@export var ring_interval: float = 6.0       # Cada cuánto lanza el patrón en círculo
@export var ring_count: int = 12
@export var ring_speed: float = 200.0

var _fire_timer: float = 0.0
var _ring_timer: float = 0.0
var _telegraphing: bool = false
var _tele_tween: Tween = null

func _ready() -> void:
	super._ready()
	melee_enabled = false          # ataca solo con proyectiles
	_fire_timer = fire_interval
	_ring_timer = ring_interval

func _update_ai(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return

	var to_player := player.global_position - global_position
	var dist := to_player.length()
	var dir := to_player.normalized()

	# Mantener la distancia preferida con navegación segura (igual que el Support).
	if dist < preferred_distance - distance_margin:
		velocity = _evasive_velocity(get_speed())          # huye sin salirse del mapa
	elif dist > preferred_distance + distance_margin:
		velocity = dir * get_speed()
	else:
		velocity = _avoid_bounds(dir.rotated(PI / 2.0) * get_speed() * 0.5)

	if passive:
		return   # maniquí de pruebas: no dispara

	# Disparo teledirigido con aviso previo
	_fire_timer -= delta
	if _fire_timer <= telegraph_time and not _telegraphing and _fire_timer > 0.0:
		_start_telegraph()
	if _fire_timer <= 0.0:
		_fire_timer = fire_interval
		_stop_telegraph()
		_shoot_aimed()

	# Patrón circular (no teledirigido)
	_ring_timer -= delta
	if _ring_timer <= 0.0:
		_ring_timer = ring_interval
		fire_ring(ring_count)

func _start_telegraph() -> void:
	_telegraphing = true
	if _tele_tween != null and _tele_tween.is_valid():
		_tele_tween.kill()
	# Parpadeo rojo no muy intenso para advertir al jugador.
	_tele_tween = create_tween()
	_tele_tween.set_loops()
	_tele_tween.tween_property(sprite, "modulate", Color(1.0, 0.55, 0.55), 0.12)
	_tele_tween.tween_property(sprite, "modulate", _base_modulate(), 0.12)

func _stop_telegraph() -> void:
	_telegraphing = false
	if _tele_tween != null and _tele_tween.is_valid():
		_tele_tween.kill()
	sprite.modulate = _base_modulate()

func _shoot_aimed() -> void:
	if projectile_scene == null or player == null:
		return
	var p = projectile_scene.instantiate()
	get_parent().add_child(p)
	p.global_position = global_position
	if p.has_method("setup"):
		p.setup(player, projectile_damage)

func demo_ability() -> void:
	"""Tutorial: dispara teledirigido (con aviso) varias veces y suelta un anillo,
	sin moverse, para mostrar su patrón."""
	if projectile_scene == null:
		return
	for i in 3:
		_start_telegraph()
		await get_tree().create_timer(telegraph_time).timeout
		_stop_telegraph()
		_shoot_aimed()
		await get_tree().create_timer(0.6).timeout
	fire_ring(ring_count)
	await get_tree().create_timer(0.6).timeout

func fire_ring(count: int) -> void:
	"""Lanza 'count' proyectiles en círculo que NO siguen al jugador."""
	if projectile_scene == null or count <= 0:
		return
	var host := get_parent()
	if host == null:
		return
	for i in count:
		var ang := TAU * float(i) / float(count)
		var b = projectile_scene.instantiate()
		host.add_child(b)
		b.global_position = global_position
		if b.has_method("setup_straight"):
			b.setup_straight(Vector2.RIGHT.rotated(ang), projectile_damage)
			if "speed" in b:
				b.speed = ring_speed
