class_name Enemy
extends CharacterBody2D

# =============================================================================
# ENEMY — Enemigo base (cuerpo a cuerpo)
# =============================================================================
# Persigue al jugador y le hace daño por contacto. Las subclases (p. ej.
# BulletMinion) pueden redefinir _update_ai() para otros comportamientos.
#
# Las animaciones se construyen en tiempo de ejecución a partir de las hojas
# de sprites asignadas, para no depender de un SpriteFrames por enemigo.

@export_group("Estadísticas")
@export var max_health: int = 4
@export var contact_damage: int = 2
@export var move_speed: float = 120.0
@export var attack_cooldown: float = 0.8
@export var melee_enabled: bool = true
@export var stop_distance: float = 50.0
@export var lethal_spin_time: float = 1.0   # "Giro letal": gira y muere tras este tiempo

@export_group("Recompensa")
@export var coin_scene: PackedScene
@export var coin_value: int = 1

@export_group("Visual")
@export var idle_sheet: Texture2D
@export var run_sheet: Texture2D
@export var idle_frames: int = 8
@export var run_frames: int = 6
@export var frame_size: int = 192
@export var anim_fps: float = 10.0
@export var sprite_scale: float = 0.6

@export_group("Separación / límites")
@export var separation_radius: float = 44.0   # distancia para no encimarse con otros
@export var separation_force: float = 90.0    # fuerza de repulsión suave entre enemigos

# Límites del área jugable (césped 1920x1152) con margen interior.
const ARENA_MIN := Vector2(70, 70)
const ARENA_MAX := Vector2(1850, 1082)

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var hitbox: Area2D = $Hitbox

var health: int
var player: Node2D = null
var _attack_timer: float = 0.0
var _dead: bool = false
var _lethal: bool = false      # bajo efecto de "giro letal"
var passive: bool = false      # enemigo de prueba (DEV-ROOM): no ataca
# Tutoriales: 'ai_frozen' detiene la IA normal (el enemigo se queda quieto para
# mostrar una demo); '_demo_velocity' permite que una demo lo mueva (Cargador).
var ai_frozen: bool = false
var _demo_velocity: Vector2 = Vector2.ZERO

# Aura de daño del enemigo de Apoyo: bonificación temporal que se refresca
# mientras el enemigo está dentro del radio y caduca al salir.
var _buff_amount: int = 0
var _buff_speed_mult: float = 1.0
var _buff_timer: float = 0.0

# Empuje externo (p. ej. el Cargador aparta a otros enemigos en su embestida).
var _push_vel: Vector2 = Vector2.ZERO

var _flash_tween: Tween = null
var _idle_time: float = 0.0

const LETHAL_SPIN_SPEED := 18.0   # rad/s mientras gira hasta morir

func _ready() -> void:
	add_to_group("enemy")
	health = max_health
	sprite.scale = Vector2(sprite_scale, sprite_scale)
	if run_sheet != null or sprite.sprite_frames == null:
		_build_frames()
	sprite.play("idle")
	player = _find_player()

func _find_player() -> Node2D:
	var players = get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

func _build_frames() -> void:
	"""Crea un SpriteFrames con idle/run. Si no hay idle_sheet propio, idle usa la
	misma hoja de correr (los sprites nuevos solo traen 'correr')."""
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
	var idle_src: Texture2D = idle_sheet if idle_sheet != null else run_sheet
	var idle_n: int = idle_frames if idle_sheet != null else run_frames
	_add_animation(frames, "idle", idle_src, idle_n)
	_add_animation(frames, "run", run_sheet, run_frames)
	sprite.sprite_frames = frames

func _add_animation(frames: SpriteFrames, anim_name: String, sheet: Texture2D, count: int) -> void:
	if sheet == null or count <= 0:
		return
	frames.add_animation(anim_name)
	frames.set_animation_loop(anim_name, true)
	frames.set_animation_speed(anim_name, anim_fps)
	for i in count:
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = Rect2(i * frame_size, 0, frame_size, frame_size)
		frames.add_frame(anim_name, atlas)

func get_speed() -> float:
	"""Velocidad efectiva (incluye buffs de velocidad del capitán/frenesí)."""
	return move_speed * _buff_speed_mult

# =============================================================================
# CICLO PRINCIPAL
# =============================================================================
func _physics_process(delta: float) -> void:
	if _dead:
		return

	# Caducidad de los buffs (si nadie los refresca, desaparecen).
	if _buff_timer > 0.0:
		_buff_timer -= delta
		if _buff_timer <= 0.0:
			_buff_amount = 0
			_buff_speed_mult = 1.0
			sprite.modulate = _base_modulate()

	# Giro letal: el enemigo gira en el sitio hasta morir; no hace nada más.
	if _lethal:
		sprite.rotation += LETHAL_SPIN_SPEED * delta
		velocity = Vector2.ZERO
		return

	# Modo tutorial: la IA normal está congelada (no persigue/ataca). Solo se mueve
	# si una demo lo pide vía _demo_velocity (Cargador) o por un empuje externo
	# (los "pinos de boliche" que aparta el Cargador siguen saliendo despedidos).
	if ai_frozen:
		velocity = _demo_velocity
		if _push_vel.length() > 1.0:
			velocity += _push_vel
			_push_vel = _push_vel.move_toward(Vector2.ZERO, 1600.0 * delta)
		move_and_slide()
		_update_animation(delta)
		return

	_attack_timer = maxf(0.0, _attack_timer - delta)

	if player == null or not is_instance_valid(player):
		player = _find_player()

	_update_ai(delta)
	velocity += _separation()
	if _push_vel.length() > 1.0:
		velocity += _push_vel
		_push_vel = _push_vel.move_toward(Vector2.ZERO, 1600.0 * delta)
	move_and_slide()
	_update_animation(delta)

	if melee_enabled:
		_try_melee()

func _separation() -> Vector2:
	"""Suma de repulsiones de los enemigos cercanos (antisuperposición suave)."""
	var push := Vector2.ZERO
	var r := separation_radius
	if r <= 0.0:
		return push
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == self or not is_instance_valid(e):
			continue
		var off: Vector2 = global_position - e.global_position
		var d := off.length()
		if d > 0.01 and d < r:
			push += (off / d) * (1.0 - d / r)
	return push * separation_force

func _evasive_velocity(spd: float) -> Vector2:
	"""Dirección de huida ROBUSTA para enemigos a distancia: se aleja del jugador
	pero elige una dirección que NO se salga del mapa, probando varios ángulos.
	En esquinas, escoge una tangente válida (bordea el mapa aunque cruce cerca
	del jugador), evitando quedarse atascado contra las paredes."""
	if player == null:
		return Vector2.ZERO
	var away := global_position - player.global_position
	away = away.normalized() if away.length() > 1.0 else Vector2.RIGHT
	var best_dir := away
	var best_score := -INF
	for a in [0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180]:
		var dir := away.rotated(deg_to_rad(a))
		var probe := global_position + dir * 90.0
		if probe.x < ARENA_MIN.x or probe.x > ARENA_MAX.x or probe.y < ARENA_MIN.y or probe.y > ARENA_MAX.y:
			continue   # esa dirección se saldría del mapa
		# Preferir alejarse del jugador y girar poco respecto a "away".
		var score := probe.distance_to(player.global_position) - absf(a) * 0.8
		if score > best_score:
			best_score = score
			best_dir = dir
	return best_dir * spd

func _avoid_bounds(vel: Vector2) -> Vector2:
	"""Evita que los enemigos evasivos se peguen a las paredes o salgan del mapa:
	si se dirigen a un borde estando cerca, redirigen ese eje hacia adentro
	(corren bordeando el mapa, aunque tengan que cruzar cerca del jugador)."""
	var p := global_position
	var m := 140.0
	if p.x < ARENA_MIN.x + m and vel.x < 0.0:
		vel.x = absf(vel.x)
	elif p.x > ARENA_MAX.x - m and vel.x > 0.0:
		vel.x = -absf(vel.x)
	if p.y < ARENA_MIN.y + m and vel.y < 0.0:
		vel.y = absf(vel.y)
	elif p.y > ARENA_MAX.y - m and vel.y > 0.0:
		vel.y = -absf(vel.y)
	return vel

func _update_ai(_delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return
	var to_player := player.global_position - global_position
	if to_player.length() < stop_distance:
		velocity = Vector2.ZERO
	else:
		velocity = to_player.normalized() * get_speed()

func push(v: Vector2) -> void:
	"""Empuje externo puntual (el Cargador aparta a otros enemigos)."""
	_push_vel += v

func make_passive() -> void:
	"""Convierte al enemigo en maniquí de pruebas: no hace daño."""
	passive = true
	melee_enabled = false

func demo_ability() -> void:
	"""Ejecuta UNA vez la mecánica característica del enemigo para los tutoriales.
	Por defecto no hace nada; las subclases especiales la implementan."""
	pass

func _try_melee() -> void:
	if passive or player == null or _attack_timer > 0.0:
		return
	for body in hitbox.get_overlapping_bodies():
		if body.is_in_group("player") and body.has_method("take_damage"):
			body.take_damage(contact_damage + _buff_amount)
			_attack_timer = attack_cooldown
			break

func _update_animation(delta: float) -> void:
	var spd := velocity.length()
	if velocity.x != 0.0:
		sprite.flip_h = velocity.x < 0.0
	if spd > 5.0:
		sprite.play("run")
		sprite.speed_scale = clampf(spd / move_speed, 0.7, 1.6)
		_idle_time = 0.0
		sprite.position.y = move_toward(sprite.position.y, 0.0, 180.0 * delta)
	else:
		sprite.play("idle")
		sprite.speed_scale = 0.65
		_idle_time += delta * 1.9
		sprite.position.y = sin(_idle_time) * 2.2

# =============================================================================
# VIDA Y MUERTE
# =============================================================================
func take_damage(amount: int) -> void:
	if _dead:
		return
	health -= amount
	_flash()
	if health <= 0:
		_die()

func apply_lethal_spin() -> void:
	"""Giro letal (ítem): el enemigo empieza a girar y muere tras un instante.
	Reemplaza el daño normal del impacto que lo activó."""
	if _dead or _lethal:
		return
	_lethal = true
	velocity = Vector2.ZERO
	melee_enabled = false
	sprite.modulate = Color(1.0, 0.9, 0.3)
	var t := get_tree().create_timer(lethal_spin_time)
	t.timeout.connect(func():
		if is_instance_valid(self) and not _dead:
			_die())

func heal(amount: int) -> void:
	"""Regeneración aplicada por el enemigo de Apoyo a los aliados cercanos."""
	if _dead:
		return
	health = min(health + amount, max_health)
	sprite.modulate = Color(0.5, 1.0, 0.5)
	var timer := get_tree().create_timer(0.12)
	timer.timeout.connect(func():
		if is_instance_valid(self) and not _dead:
			sprite.modulate = _base_modulate())

# =============================================================================
# AURA DE DAÑO (la aplica el enemigo de Apoyo)
# =============================================================================
func apply_buff(dmg: int, speed_mult: float, duration: float) -> void:
	"""Otorga +daño y/o +velocidad mientras se refresque. Al dejar de refrescarse
	(salir del radio) caduca (ver _physics_process)."""
	if _dead:
		return
	var was_active := _buff_amount > 0 or _buff_speed_mult > 1.0
	_buff_amount = max(_buff_amount, dmg)
	_buff_speed_mult = max(_buff_speed_mult, speed_mult)
	_buff_timer = max(_buff_timer, duration)
	if not was_active:
		sprite.modulate = _base_modulate()

func apply_damage_buff(amount: int, duration: float) -> void:
	# Compatibilidad: el Apoyo otorga solo +daño.
	apply_buff(amount, 1.0, duration)

func _base_modulate() -> Color:
	# Tinte cálido mientras el enemigo está potenciado por un buff.
	return Color(1.0, 0.72, 0.55) if (_buff_amount > 0 or _buff_speed_mult > 1.0) else Color.WHITE

func _flash() -> void:
	# Efecto general de impacto: oscurecer el sprite de forma intermitente.
	if not is_instance_valid(sprite):
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	var dark := Color(0.4, 0.4, 0.45)
	_flash_tween = create_tween()
	_flash_tween.tween_property(sprite, "modulate", dark, 0.05)
	_flash_tween.tween_property(sprite, "modulate", _base_modulate(), 0.08)
	_flash_tween.tween_property(sprite, "modulate", dark, 0.05)
	_flash_tween.tween_property(sprite, "modulate", _base_modulate(), 0.08)

func _die() -> void:
	_dead = true
	_drop_coin()
	queue_free()

func _drop_coin() -> void:
	if coin_scene == null:
		return
	var coin = coin_scene.instantiate()
	# La moneda es un Area2D; añadirla DURANTE el flush de colisiones (la muerte
	# se origina en body_entered) provoca el error "Can't change this state while
	# flushing queries". Posicionamos antes (raíz en el origen → local == global)
	# y diferimos el add_child para hacerlo fuera del flush.
	coin.position = global_position
	if coin.has_method("set_value"):
		coin.set_value(coin_value)
	get_parent().add_child.call_deferred(coin)
