extends CharacterBody2D

# =============================================================================
# BIGMINION GRAN CAPITÁN — Minijefe de la Oleada 10
# =============================================================================
# Máquina de estados por fases (similar al jefe), con barra de vida propia.
#   Fase base (>75%): embestidas como el Cargador.
#   <75%: además lanza patrones de HomingBullet en triángulo y "X".
#   <50%: invoca hasta 4 Bigminion_capitan (que a su vez invocan 4 Bigminión una
#         vez); puede repetir el grupo cada 30 s.
#   <25%: deja de invocar capitanes; invoca 4 Bullet_minion_sad (guardianes).
#         Mientras esos guardianes vivan, <10% de anular el daño al minijefe.

signal died

@export_group("Estadísticas")
@export var max_health: int = 320
@export var move_speed: float = 230.0
@export var contact_damage: int = 6
@export var contact_cooldown: float = 0.8

@export_group("Embestida")
@export var charge_interval: float = 4.0
@export var windup_time: float = 0.5
@export var charge_time: float = 0.45
@export var charge_speed: float = 760.0
@export var charge_range: float = 520.0

@export_group("Patrones / Invocación")
@export var pattern_interval: float = 3.5
@export var bullet_damage: int = 3
@export var bullet_speed: float = 210.0
@export var capitan_cooldown: float = 30.0
@export var summon_count: int = 4

@export_group("Escenas")
@export var bullet_scene: PackedScene
@export var capitan_scene: PackedScene
@export var sad_scene: PackedScene
@export var coin_scene: PackedScene
@export var coins_dropped: int = 20

@export_group("Visual")
@export var run_sheet: Texture2D
@export var run_frames: int = 6
@export var frame_size: int = 64
@export var sprite_scale: float = 1.8

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hitbox: Area2D = $Hitbox
@onready var bar: ProgressBar = $UI/BossBar

enum Ph { CHASE, WINDUP, CHARGE }

var health: int
var player: Node2D = null
var _phase: int = Ph.CHASE
var _phase_t: float = 0.0
var _charge_cd: float = 0.0
var _charge_dir: Vector2 = Vector2.ZERO
var _pattern_cd: float = 0.0
var _capitan_cd: float = 0.0
var _contact_cd: float = 0.0
var _pattern_toggle: bool = false
var _sads_summoned: bool = false
var _flash_tween: Tween = null
var _dead: bool = false

func _ready() -> void:
	add_to_group("enemy")
	add_to_group("boss")          # para que _clear_enemies no lo borre
	add_to_group("miniboss")
	health = max_health
	sprite.scale = Vector2(sprite_scale, sprite_scale)
	_build_frames()
	sprite.play("run")
	player = _find_player()
	bar.max_value = max_health
	bar.value = health
	_charge_cd = charge_interval
	_pattern_cd = pattern_interval
	_capitan_cd = 2.0   # primera invocación poco después de entrar en fase 2

func _physics_process(delta: float) -> void:
	if _dead:
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()
	_contact_cd = maxf(0.0, _contact_cd - delta)

	match _phase:
		Ph.CHASE:
			_chase(delta)
		Ph.WINDUP:
			_windup(delta)
		Ph.CHARGE:
			_charge(delta)

	move_and_slide()
	_update_facing()
	_contact_check()
	_phase_actions(delta)

func _frac() -> float:
	return float(health) / float(max_health)

# --- Movimiento / embestida ---
func _chase(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return
	var to_player := player.global_position - global_position
	if to_player.length() > 90.0:
		velocity = to_player.normalized() * move_speed
	else:
		velocity = Vector2.ZERO
	_charge_cd -= delta
	if _charge_cd <= 0.0 and to_player.length() <= charge_range:
		_phase = Ph.WINDUP
		_phase_t = windup_time

func _windup(delta: float) -> void:
	velocity = Vector2.ZERO
	sprite.modulate = Color(1.0, 0.7, 0.2)
	_phase_t -= delta
	if _phase_t <= 0.0:
		_charge_dir = (player.global_position - global_position).normalized() if player != null else Vector2.RIGHT
		_phase = Ph.CHARGE
		_phase_t = charge_time
		sprite.modulate = Color.WHITE

func _charge(delta: float) -> void:
	velocity = _charge_dir * charge_speed
	# Aparta a los enemigos que se cruzan
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == self or not is_instance_valid(e) or not e.has_method("push"):
			continue
		var off: Vector2 = e.global_position - global_position
		if off.length() <= 90.0:
			e.push(off.normalized() * 300.0 if off.length() > 0.0 else Vector2.RIGHT * 300.0)
	_phase_t -= delta
	if _phase_t <= 0.0:
		_phase = Ph.CHASE
		_charge_cd = charge_interval

# --- Acciones por fase (patrones / invocación) ---
func _phase_actions(delta: float) -> void:
	if _phase != Ph.CHASE:
		return
	var f := _frac()

	# <75%: patrones de HomingBullet en triángulo y "X"
	if f < 0.75:
		_pattern_cd -= delta
		if _pattern_cd <= 0.0:
			_pattern_cd = pattern_interval
			if _pattern_toggle:
				_fire_pattern(3, deg_to_rad(90.0))    # triángulo
			else:
				_fire_x_pattern()                      # "X"
			_pattern_toggle = not _pattern_toggle

	# <50% y >=25%: invocar grupo de capitanes cada 30 s
	if f < 0.5 and f >= 0.25:
		_capitan_cd -= delta
		if _capitan_cd <= 0.0:
			_capitan_cd = capitan_cooldown
			_summon_capitanes()

	# <25%: invocar 4 sads guardianes (una vez)
	if f < 0.25 and not _sads_summoned:
		_sads_summoned = true
		_summon_guards()

func _fire_pattern(count: int, offset: float) -> void:
	if bullet_scene == null:
		return
	var host := _host()
	for i in count:
		var ang := offset + TAU * float(i) / float(count)
		_spawn_bullet(host, Vector2.RIGHT.rotated(ang))

func _fire_x_pattern() -> void:
	if bullet_scene == null:
		return
	var host := _host()
	# Cuatro brazos diagonales (forma de "X"), cada uno con varias balas.
	for diag in [45.0, 135.0, 225.0, 315.0]:
		var d := Vector2.RIGHT.rotated(deg_to_rad(diag))
		for _k in 3:
			_spawn_bullet(host, d)

func _spawn_bullet(host: Node, dir: Vector2) -> void:
	var b = bullet_scene.instantiate()
	host.add_child(b)
	b.global_position = global_position
	if b.has_method("setup_straight"):
		b.setup_straight(dir, bullet_damage)
		if "speed" in b:
			b.speed = bullet_speed

func _summon_capitanes() -> void:
	if capitan_scene == null:
		return
	var host := _host()
	for i in summon_count:
		var pos: Vector2 = global_position + Vector2.RIGHT.rotated(TAU * i / summon_count) * 120.0
		# Indicador rojo antes de instanciar la invocación.
		Game.telegraph_spawn(host, pos, Game.INDICATOR_ENEMY, 2.4, 0.8, func():
			var c = capitan_scene.instantiate()
			if "can_summon_bigminions" in c:
				c.can_summon_bigminions = true   # estos sí invocan Bigminión una vez
			host.add_child(c)
			c.global_position = pos)

func _summon_guards() -> void:
	if sad_scene == null:
		return
	var host := _host()
	for i in summon_count:
		var pos: Vector2 = global_position + Vector2.RIGHT.rotated(TAU * i / summon_count) * 130.0
		Game.telegraph_spawn(host, pos, Game.INDICATOR_ENEMY, 2.0, 0.8, func():
			var s = sad_scene.instantiate()
			if "is_summon" in s:
				s.is_summon = true
			host.add_child(s)
			s.add_to_group("miniboss_guard")
			s.global_position = pos)

func _guards_alive() -> bool:
	for g in get_tree().get_nodes_in_group("miniboss_guard"):
		if is_instance_valid(g):
			return true
	return false

# --- Daño / vida ---
func take_damage(amount: int) -> void:
	if _dead:
		return
	# Mecánica defensiva: mientras vivan los sads guardianes, <10% de anular daño.
	if _guards_alive() and randf() < 0.08:
		_negate_fx()
		return
	health -= amount
	bar.value = health
	_flash()
	if health <= 0:
		_die()

func _negate_fx() -> void:
	sprite.modulate = Color(0.5, 0.7, 1.0)
	var t := create_tween()
	t.tween_property(sprite, "modulate", Color.WHITE, 0.15)

func _flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	var dark := Color(0.4, 0.4, 0.45)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", dark, 0.05)
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.08)
	_flash_tween.tween_property(sprite, "modulate", dark, 0.05)
	_flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.08)

func _die() -> void:
	_dead = true
	velocity = Vector2.ZERO
	bar.visible = false
	Game.unlock("grancapitan_helmet")   # desbloqueo persistente del casco
	_drop_coins()
	died.emit()
	queue_free()

func _drop_coins() -> void:
	if coin_scene == null:
		return
	var host := _host()
	for i in coins_dropped:
		var c = coin_scene.instantiate()
		# Diferir: la muerte puede originarse en un body_entered (flush de física).
		c.position = global_position + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(30.0, 110.0)
		host.add_child.call_deferred(c)

# --- Utilidades ---
func _contact_check() -> void:
	if _contact_cd > 0.0 or player == null:
		return
	for body in hitbox.get_overlapping_bodies():
		if body.is_in_group("player") and body.has_method("take_damage"):
			body.take_damage(contact_damage)
			_contact_cd = contact_cooldown
			break

func _update_facing() -> void:
	if player != null and is_instance_valid(player):
		sprite.flip_h = player.global_position.x < global_position.x

func _host() -> Node:
	var h := get_tree().current_scene
	return h if h != null else get_parent()

func _find_player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

func _build_frames() -> void:
	if run_sheet == null:
		return
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
	for anim in ["idle", "run"]:
		frames.add_animation(anim)
		frames.set_animation_loop(anim, true)
		frames.set_animation_speed(anim, 10.0)
		for i in run_frames:
			var atlas := AtlasTexture.new()
			atlas.atlas = run_sheet
			atlas.region = Rect2(i * frame_size, 0, frame_size, frame_size)
			frames.add_frame(anim, atlas)
	sprite.sprite_frames = frames
