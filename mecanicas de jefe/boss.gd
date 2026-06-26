extends CharacterBody2D

# =============================================================================
# BOSS — Jefe final (máquina de estados)
# =============================================================================
# Diseño ORIGINAL inspirado en los scripts de referencia de "mecanicas de jefe"
# (Follow / Attack / Teleport / SpawnMinion / Death). En lugar de copiarlos,
# combina esos conceptos en un solo jefe con FASES según su vida:
#
#   Fase 1 (>66% vida): perseguir + golpe cuerpo a cuerpo; teletransportes ocasionales.
#   Fase 2 (33–66%):    añade invocación de minions y voleas de proyectiles.
#   Fase 3 (<33%):      enfurecido: más rápido, teletransportes y voleas dobles.
#
# Reutiliza assets existentes (Black Warrior como sprite). Las "animaciones" de
# ataque/teleport se simulan con tintes/escala porque el pack no trae esos
# fotogramas (ver docs/jefe.md para los assets que faltarían).

signal died

enum S { FOLLOW, ATTACK, TELEPORT, SPAWN, RANGED, DEAD }

# Límites del área jugable (mismos que enemy.gd) para acotar el teletransporte.
const ARENA_MIN := Vector2(70, 70)
const ARENA_MAX := Vector2(1850, 1082)

@export_group("Estadísticas")
@export var max_health: int = 270
@export var move_speed: float = 300.0
@export var contact_damage: int = 4
@export var contact_cooldown: float = 0.8

@export_group("Ataques")
@export var attack_range: float = 170.0
@export var slam_damage: int = 10
@export var slam_radius: float = 150.0
@export var decide_interval: float = 1.3   # más bajo = ataca con más frecuencia
@export var teleport_distance: float = 220.0
@export var spawn_count: int = 6           # invocación masiva
@export var ranged_count: int = 14
@export var bullet_damage: int = 3
@export var absorb_cap: int = 48           # máx. de proyectiles que devuelve tras absorber

@export_group("Recompensa")
@export var coin_scene: PackedScene
@export var coins_dropped: int = 12

@export_group("Invocaciones / Proyectiles")
@export var minion_scene: PackedScene
@export var bullet_scene: PackedScene
@export var summon_scenes: Array[PackedScene] = []   # tipos variados que puede invocar
@export var support_scene: PackedScene               # fase crítica: curan al jefe
@export var critical_support_count: int = 2

@export_group("Visual")
@export var frames_idle: Array[Texture2D] = []
@export var frames_run: Array[Texture2D] = []
@export var frames_attack: Array[Texture2D] = []
@export var anim_fps_idle: float = 6.0
@export var anim_fps_run: float = 9.0
@export var anim_fps_attack: float = 12.0
@export var sprite_scale: float = 1.6

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hitbox: Area2D = $Hitbox
@onready var bar: ProgressBar = $UI/BossBar

var health: int
var player: Node2D = null
var state: int = S.FOLLOW
var _t: float = 0.0
var _acted: bool = false
var _decide_cd: float = 0.0
var _contact_cd: float = 0.0
var _idle_time: float = 0.0
var _base_sprite_scale: Vector2 = Vector2.ONE
var _absorbed: int = 0                 # proyectiles absorbidos en el teletransporte
var _crit_supports_summoned: bool = false   # supports curanderos de la fase crítica

func _ready() -> void:
	add_to_group("enemy")
	add_to_group("boss")
	health = max_health
	sprite.scale = Vector2(sprite_scale, sprite_scale)
	_base_sprite_scale = sprite.scale
	_build_frames()
	sprite.play("idle")
	player = _find_player()
	bar.max_value = max_health
	bar.value = health
	_decide_cd = decide_interval
	state = S.FOLLOW

# =============================================================================
# CICLO PRINCIPAL
# =============================================================================
func _physics_process(delta: float) -> void:
	if state == S.DEAD:
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()

	_contact_cd = maxf(0.0, _contact_cd - delta)

	match state:
		S.FOLLOW:
			_state_follow(delta)
		S.ATTACK:
			_state_attack(delta)
		S.TELEPORT:
			_state_teleport(delta)
		S.SPAWN:
			_state_spawn(delta)
		S.RANGED:
			_state_ranged(delta)

	move_and_slide()
	_update_facing()
	_contact_check()
	_animate_alive(delta)
	_check_critical()

func _check_critical() -> void:
	# Fase crítica (<25% vida): invoca SupportMinion que CURAN al jefe (una vez).
	if _crit_supports_summoned or support_scene == null:
		return
	if float(health) / float(max_health) < 0.25:
		_crit_supports_summoned = true
		_summon_crit_supports()

func _phase() -> int:
	var f := float(health) / float(max_health)
	if f > 0.66:
		return 1
	elif f > 0.33:
		return 2
	return 3

func _speed_mult() -> float:
	return 0.85 + 0.15 * (_phase() - 1)   # fase 1 lento / fase 2 igual al jugador / fase 3 rápido

# =============================================================================
# ESTADOS
# =============================================================================
func _state_follow(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return
	var to_player := player.global_position - global_position
	velocity = to_player.normalized() * move_speed * _speed_mult()

	if to_player.length() <= attack_range:
		_enter(S.ATTACK)
		return

	_decide_cd -= delta
	if _decide_cd <= 0.0:
		_decide_cd = decide_interval / _phase()
		_choose_special()

func _choose_special() -> void:
	var options := ["teleport"]
	var phase := _phase()
	if phase >= 1 and (not summon_scenes.is_empty() or minion_scene != null):
		options.append("spawn")
	if bullet_scene != null:
		# Voleas más frecuentes desde el principio (ataques de proyectil seguidos).
		options.append("ranged")
		options.append("ranged")
		options.append("teleport")
	if phase >= 3:
		options.append("ranged")
		options.append("ranged")
	match options[randi() % options.size()]:
		"spawn":
			_enter(S.SPAWN)
		"ranged":
			_enter(S.RANGED)
		_:
			_enter(S.TELEPORT)

func _state_attack(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 1200.0 * delta)
	_t -= delta
	if not _acted:
		# Telegrafía del golpe
		sprite.modulate = Color(1.0, 0.55, 0.2)
		if _t <= 0.0:
			_do_slam()
			_acted = true
			_t = 0.35   # recuperación
	else:
		if _t <= 0.0:
			sprite.modulate = Color.WHITE
			_enter(S.FOLLOW)

func _do_slam() -> void:
	sprite.modulate = Color(1.0, 0.3, 0.3)
	if player != null and is_instance_valid(player):
		if global_position.distance_to(player.global_position) <= slam_radius:
			if player.has_method("take_damage"):
				player.take_damage(slam_damage)
	# En fases avanzadas el golpe suelta una pequeña onda de balas
	if _phase() >= 2 and bullet_scene != null:
		_fire_ring(8)

func _state_teleport(delta: float) -> void:
	velocity = Vector2.ZERO
	_t -= delta
	if not _acted:
		# Al desvanecerse, ABSORBE todos los proyectiles activos (del jugador y de
		# los enemigos). Los devolverá en una volea masiva al reaparecer.
		sprite.modulate.a = clampf(_t / 0.3, 0.0, 1.0)
		if _t <= 0.0:
			_absorbed += _absorb_projectiles()
			# Reaparece a 'teleport_distance' del jugador, SIEMPRE dentro del mapa.
			if player != null and is_instance_valid(player):
				var off := Vector2.RIGHT.rotated(randf() * TAU) * teleport_distance
				global_position = _clamp_to_arena(player.global_position + off)
			Audio.play_at("teleport_boss", global_position, 0.04, 60, 5.0)   # +5 dB: destaca sobre el golpe
			_acted = true
			_t = 0.25
	else:
		sprite.modulate.a = clampf(1.0 - _t / 0.25, 0.0, 1.0)
		if _t <= 0.0:
			sprite.modulate = Color.WHITE
			# Al reaparecer: si absorbió proyectiles, los devuelve TODOS de golpe.
			if _absorbed > 0:
				_unleash_absorbed()
				_enter(S.FOLLOW)
			elif _phase() >= 2 and randf() < 0.5:
				_enter(S.RANGED)
			else:
				_enter(S.ATTACK)

func _clamp_to_arena(p: Vector2) -> Vector2:
	return Vector2(clampf(p.x, ARENA_MIN.x, ARENA_MAX.x), clampf(p.y, ARENA_MIN.y, ARENA_MAX.y))

func _absorb_projectiles() -> int:
	"""Elimina todos los proyectiles activos (jugador + enemigos) y devuelve cuántos."""
	var n := 0
	for grp in ["spin_bullet", "enemy_projectile"]:
		for b in get_tree().get_nodes_in_group(grp):
			if is_instance_valid(b):
				b.queue_free()
				n += 1
	return n

func _unleash_absorbed() -> void:
	"""Devuelve en abanico/anillo todos los proyectiles absorbidos (con tope)."""
	var total: int = mini(_absorbed, absorb_cap)
	_absorbed = 0
	if total <= 0:
		return
	Audio.play_at("teleport_boss", global_position, 0.03, 0, 4.0)
	# Dos anillos desfasados para una "tormenta" densa.
	_fire_ring(int(ceil(total / 2.0)))
	_fire_ring(total / 2, deg_to_rad(180.0 / maxf(1.0, total / 2.0)))

func _state_spawn(delta: float) -> void:
	velocity = Vector2.ZERO
	_t -= delta
	if not _acted:
		sprite.modulate = Color(0.7, 0.5, 1.0)
		if _t <= 0.0:
			_spawn_minions()
			_acted = true
			_t = 0.3
	else:
		if _t <= 0.0:
			sprite.modulate = Color.WHITE
			_enter(S.FOLLOW)

func _spawn_minions() -> void:
	# Invocación MASIVA y VARIADA: elige al azar entre 'summon_scenes' (si están
	# asignadas) o cae al minion básico.
	var pool: Array = []
	for s in summon_scenes:
		if s != null:
			pool.append(s)
	if pool.is_empty() and minion_scene != null:
		pool.append(minion_scene)
	if pool.is_empty():
		return
	var host := _host()
	for i in spawn_count:
		var scene: PackedScene = pool[randi() % pool.size()]
		var pos: Vector2 = _clamp_to_arena(global_position + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(70.0, 150.0))
		# Indicador rojo antes de instanciar a los invocados.
		Game.telegraph_spawn(host, pos, Game.INDICATOR_ENEMY, 1.9, 0.6, func():
			var m = scene.instantiate()
			host.add_child(m)
			m.global_position = pos)

func _summon_crit_supports() -> void:
	"""Fase crítica: invoca SupportMinion que CURAN al jefe mientras vivan."""
	if support_scene == null:
		return
	var host := _host()
	for i in critical_support_count:
		var pos: Vector2 = _clamp_to_arena(global_position + Vector2.RIGHT.rotated(TAU * i / critical_support_count) * 130.0)
		Game.telegraph_spawn(host, pos, Game.INDICATOR_ENEMY, 1.9, 0.7, func():
			if not is_instance_valid(self):
				return
			var s = support_scene.instantiate()
			s.heal_target = self   # modo "curar al jefe" (ver support_minion.gd)
			host.add_child(s)
			s.global_position = pos)

func _host() -> Node:
	var h := get_tree().current_scene
	return h if h != null else get_parent()

func _state_ranged(delta: float) -> void:
	velocity = Vector2.ZERO
	_t -= delta
	if not _acted:
		sprite.modulate = Color(0.4, 0.8, 1.0)
		if _t <= 0.0:
			_fire_ring(ranged_count)
			if _phase() >= 3:
				_fire_ring(ranged_count, deg_to_rad(180.0 / ranged_count))  # segundo anillo desfasado
			_acted = true
			_t = 0.3
	else:
		if _t <= 0.0:
			sprite.modulate = Color.WHITE
			_enter(S.FOLLOW)

func _fire_ring(count: int, offset: float = 0.0) -> void:
	if bullet_scene == null:
		return
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	for i in count:
		var ang := offset + TAU * float(i) / float(count)
		var b = bullet_scene.instantiate()
		host.add_child(b)
		b.global_position = global_position
		if b.has_method("setup"):
			b.setup(Vector2.RIGHT.rotated(ang), bullet_damage)

# =============================================================================
# UTILIDADES DE ESTADO
# =============================================================================
func _enter(new_state: int) -> void:
	state = new_state
	_acted = false
	match new_state:
		S.ATTACK:
			_t = 0.45
		S.TELEPORT:
			_t = 0.3
		S.SPAWN:
			_t = 0.4
		S.RANGED:
			_t = 0.35
		_:
			_t = 0.0

func _contact_check() -> void:
	if _contact_cd > 0.0 or player == null:
		return
	for body in hitbox.get_overlapping_bodies():
		if body.is_in_group("player") and body.has_method("take_damage"):
			body.take_damage(contact_damage)
			_contact_cd = contact_cooldown
			break

func _animate_alive(delta: float) -> void:
	match state:
		S.FOLLOW:
			var spd := velocity.length()
			if spd > 10.0:
				_idle_time = 0.0
				sprite.play("run")
				sprite.speed_scale = clampf(spd / move_speed, 0.8, 1.4)
				sprite.position.y = move_toward(sprite.position.y, 0.0, 220.0 * delta)
			else:
				sprite.play("idle")
				sprite.speed_scale = 0.65
				_idle_time += delta * 1.6
				sprite.position.y = sin(_idle_time) * 3.5
		S.ATTACK:
			sprite.play("attack")
			_idle_time += delta * 1.6
			sprite.position.y = sin(_idle_time) * 3.5
		S.TELEPORT:
			_idle_time = 0.0
		_:  # SPAWN, RANGED
			sprite.play("idle")
			sprite.speed_scale = 0.65
			_idle_time += delta * 1.6
			sprite.position.y = sin(_idle_time) * 3.5

func _update_facing() -> void:
	if player != null and is_instance_valid(player):
		sprite.flip_h = player.global_position.x < global_position.x

func _find_player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

# =============================================================================
# VIDA Y MUERTE
# =============================================================================
func take_damage(amount: int) -> void:
	if state == S.DEAD:
		return
	health -= amount
	bar.value = health
	_hit_flash()
	if health <= 0:
		_die()

func heal(amount: int) -> void:
	"""Curación recibida (la usan los SupportMinion de la fase crítica)."""
	if state == S.DEAD:
		return
	health = mini(max_health, health + amount)
	bar.value = health

func _hit_flash() -> void:
	# Solo si no está en medio de un telegrafiado coloreado
	if state == S.FOLLOW:
		sprite.modulate = Color(1, 0.5, 0.5)
		var t := get_tree().create_timer(0.08)
		t.timeout.connect(func():
			if is_instance_valid(self) and state == S.FOLLOW:
				sprite.modulate = Color.WHITE)

func _die() -> void:
	state = S.DEAD
	velocity = Vector2.ZERO
	sprite.position.y = 0.0
	sprite.speed_scale = 1.0
	bar.visible = false
	_drop_coins()
	died.emit()
	queue_free()

func _drop_coins() -> void:
	if coin_scene == null:
		return
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	for i in coins_dropped:
		var c = coin_scene.instantiate()
		# Diferir: la muerte puede originarse en un body_entered (flush de física).
		c.position = global_position + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(20.0, 90.0)
		host.add_child.call_deferred(c)

# =============================================================================
# ANIMACIONES (construidas en runtime desde las hojas)
# =============================================================================
func _build_frames() -> void:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	var idle_src   := frames_idle   if not frames_idle.is_empty()   else frames_run
	var run_src    := frames_run    if not frames_run.is_empty()    else frames_idle
	var attack_src := frames_attack if not frames_attack.is_empty() else frames_idle
	_add_anim(sf, "idle",   idle_src,   anim_fps_idle)
	_add_anim(sf, "run",    run_src,    anim_fps_run)
	_add_anim(sf, "attack", attack_src, anim_fps_attack)
	sprite.sprite_frames = sf

func _add_anim(sf: SpriteFrames, anim_name: String, textures: Array[Texture2D], fps: float) -> void:
	if textures.is_empty():
		return
	sf.add_animation(anim_name)
	sf.set_animation_loop(anim_name, true)
	sf.set_animation_speed(anim_name, fps)
	for tex in textures:
		sf.add_frame(anim_name, tex)
