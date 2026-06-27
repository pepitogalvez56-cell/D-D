class_name Personaje
extends CharacterBody2D

# Se emite cuando el jugador muere (lo usa el GameMode para la pantalla de muerte)
signal died

# =============================================================================
# MÁQUINA DE ESTADOS DEL PERSONAJE
# =============================================================================
# Estados esenciales: movimiento, esquive y recibir daño.
enum State {
	MOVE,            # Movimiento normal
	DODGE,           # Esquive (gira sobre sí mismo e invulnerable)
	TAKING_DAMAGE,   # Recibiendo daño (invulnerabilidad temporal)
	DEAD             # Muerto
}
var current_state: State = State.MOVE

# Cuántos píxeles de mundo se ven verticalmente independientemente del tamaño de ventana
const _CAMERA_TARGET_HEIGHT := 768.0

# =============================================================================
# NODOS DE LA ESCENA
# =============================================================================
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var camera: Camera2D = $Camera2D

# UI (HUD): barra de vida y barra/etiqueta del esquive
@onready var health_bar: TextureProgressBar = $HUD/Root/HealthBar
@onready var health_label: Label = $HUD/Root/HealthBar/HealthLabel
@onready var dodge_bar: TextureProgressBar = $HUD/Root/DodgeBar
@onready var coins_label: Label = $HUD/Root/Coins/CoinsLabel

# =============================================================================
# PROPIEDADES CONFIGURABLES
# =============================================================================
@export var speed: float = 300.0
@export var acceleration: float = 1500.0
@export var friction: float = 1800.0
@export var vida: int = 20
@export var vida_max: int = 20

@export_group("Esquive")
@export var dodge_speed: float = 600.0       # Velocidad durante el esquive
@export var dodge_duration: float = 0.4      # Cuánto dura el esquive
@export var dodge_cooldown_time: float = 1.0 # Tiempo hasta poder esquivar de nuevo
@export var dodge_spin_turns: float = 1.0    # Vueltas completas que gira el sprite
@export var dodge_stretch_amount: float = 0.3

@export_group("Animación")
@export var idle_speed_scale: float = 0.55
@export var idle_bob_amplitude: float = 2.5
@export var idle_bob_speed: float = 2.2
@export var run_speed_scale_min: float = 0.85
@export var run_speed_scale_max: float = 1.5

@export_group("Daño")
@export var invulnerability_duration: float = 0.9

@export_group("Spin-Bullet")
@export var spin_bullet_scene: PackedScene   # Escena de la bala que orbita
@export var bullet_damage: int = 3           # Daño de cada Spin-Bullet (mejorable)
@export var shoot_cooldown_time: float = 0.5  # Cadencia de disparo (mejorable)

@export_group("Cascos")
@export var ally_capitan_scene: PackedScene  # Capitán aliado (casco de gran capitán)

# =============================================================================
# VARIABLES INTERNAS
# =============================================================================
var input_direction: Vector2
var last_direction: Vector2 = Vector2.DOWN
var is_invulnerable: bool = false
var is_frozen: bool = false   # Congelado mientras la tienda está abierta
var movement_locked: bool = false   # Tutorial: no se mueve pero SÍ puede disparar

var _hurt_blink: Tween = null   # parpadeo de invulnerabilidad tras recibir daño

# Dirección y giro acumulado del esquive (para la animación de girar)
var dodge_direction: Vector2 = Vector2.ZERO
var dodge_elapsed: float = 0.0
var _base_sprite_scale: Vector2 = Vector2.ONE
var _idle_time: float = 0.0

# Timers
var dodge_timer: Timer        # Duración del esquive
var dodge_cooldown: Timer     # Enfriamiento del esquive
var damage_timer: Timer       # Invulnerabilidad tras recibir daño
var shoot_cooldown: Timer     # Cadencia entre Spin-Bullets

# =============================================================================
# NIVELES DE ÍTEMS (habilidades especiales, ver tienda y docs/items.md)
# =============================================================================
var coin_heal_level: int = 0   # Robo de vida al recoger monedas (máx 3 -> 75%)
var bounce_level: int = 0      # Rebote ofensivo: SpinShots extra al impactar (máx 3)
var has_split: bool = false    # División de proyectil (única)
var lethal_level: int = 0      # Giro letal: +1% por nivel (ilimitado)
var autododge_level: int = 0   # Esquiva automática al recibir daño (máx 3 -> 75%)

# --- Cascos (efectos que se ACUMULAN sin sobrescribirse, ver QA) ---
var viking_push_chance: float = 0.0   # Casco vikingo: prob. de empujar enemigos (máx 0.5)
var has_capitan_frenzy: bool = false  # Casco de capitán: frenesí <50% vida
var _frenzy_active: bool = false
var _frenzy_speed_mult: float = 1.0   # multiplicador de velocidad por frenesí
var _frenzy_damage_bonus: int = 0     # +daño por frenesí
const FRENZY_SPEED_MULT := 1.5
const FRENZY_DAMAGE_BONUS := 3
const VIKING_PUSH_CAP := 0.5
const VIKING_PUSH_FORCE := 520.0

# Inventario de ítems comprados: id -> {name, desc, icon, count}
var inventory: Dictionary = {}

# Depuración (solo DEV-ROOM)
var debug_invincible: bool = false

# Código secreto (estilo Konami): arriba arriba abajo abajo izquierda derecha izquierda derecha
# alterna el modo dios. Disponible en cualquier partida, no solo en DEV-ROOM.
const _CHEAT_SEQUENCE := ["Arriba", "Arriba", "Abajo", "Abajo", "Izquierda", "Derecha", "Izquierda", "Derecha"]
const _CHEAT_RESET_MS := 1500
var _cheat_step: int = 0
var _cheat_last_ms: int = 0
var _god_mode_tween: Tween = null

# Efecto de partículas (nube de polvo de la esquiva automática)
const EFFECT_SCENE := preload("res://Scenes/Effect.tscn")

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready():
	add_to_group("player")
	_setup_timers()
	vida = clamp(vida, 0, vida_max)
	health_bar.max_value = vida_max
	_update_health_ui()
	_update_dodge_ui()
	_base_sprite_scale = sprite.scale
	sprite.play("idle")
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	_update_camera_zoom()
	get_viewport().size_changed.connect(_update_camera_zoom)
	_style_hud()
	# Contador de monedas (sprite + cantidad) bajo la barra de esquive
	Game.coins_changed.connect(_update_coins_ui)
	_update_coins_ui(Game.coins)
	# Área de empuje del casco vikingo (repele enemigos que la tocan)
	if has_node("PushArea"):
		$PushArea.body_entered.connect(_on_push_area_body_entered)

func _style_hud() -> void:
	# Las barras usan los sprites (04.png) definidos en la escena.
	# Aquí solo damos color/legibilidad al texto que va encima.
	UiTheme.apply_label(health_label)
	UiTheme.apply_label(coins_label)
	# Contador de monedas más grande y dorado para que se lea bien (antes era pequeño).
	coins_label.add_theme_font_size_override("font_size", 30)
	coins_label.add_theme_color_override("font_color", UiTheme.GOLD)

func _update_coins_ui(total: int) -> void:
	coins_label.text = str(total)

func _update_camera_zoom() -> void:
	var vp_h := get_viewport().get_visible_rect().size.y
	var z := vp_h / _CAMERA_TARGET_HEIGHT
	camera.zoom = Vector2(z, z)

func _setup_timers():
	# Timer que controla la duración del esquive
	dodge_timer = Timer.new()
	dodge_timer.wait_time = dodge_duration
	dodge_timer.one_shot = true
	dodge_timer.timeout.connect(_on_dodge_timer_timeout)
	add_child(dodge_timer)

	# Timer del enfriamiento (cooldown) del esquive
	dodge_cooldown = Timer.new()
	dodge_cooldown.wait_time = dodge_cooldown_time
	dodge_cooldown.one_shot = true
	add_child(dodge_cooldown)

	# Timer de invulnerabilidad tras recibir daño
	damage_timer = Timer.new()
	damage_timer.wait_time = invulnerability_duration
	damage_timer.one_shot = true
	damage_timer.timeout.connect(_on_damage_timer_timeout)
	add_child(damage_timer)

	# Timer de la cadencia de disparo
	shoot_cooldown = Timer.new()
	shoot_cooldown.wait_time = shoot_cooldown_time
	shoot_cooldown.one_shot = true
	add_child(shoot_cooldown)

# =============================================================================
# ENTRADA NO PROCESADA (disparo de la Spin-Bullet)
# =============================================================================
func _unhandled_input(event):
	if current_state == State.DEAD:
		return
	_check_cheat_code(event)
	if is_frozen:
		return
	# Clic derecho: Spin-Bullet con patrón normal (espiral)
	if event.is_action_pressed("shoot"):
		_shoot_spin_bullet(0)
	# Clic izquierdo: Spin-Bullet con patrón alterno (espiral ondulada)
	elif event.is_action_pressed("shoot_alt"):
		_shoot_spin_bullet(1)

# =============================================================================
# CÓDIGO SECRETO (GOD MODE)
# =============================================================================
func _check_cheat_code(event: InputEvent) -> void:
	var pressed_action := ""
	for action in ["Arriba", "Abajo", "Izquierda", "Derecha"]:
		if event.is_action_pressed(action):
			pressed_action = action
			break
	if pressed_action == "":
		return

	var now := Time.get_ticks_msec()
	if _cheat_step > 0 and now - _cheat_last_ms > _CHEAT_RESET_MS:
		_cheat_step = 0

	if pressed_action == _CHEAT_SEQUENCE[_cheat_step]:
		_cheat_step += 1
		_cheat_last_ms = now
		if _cheat_step >= _CHEAT_SEQUENCE.size():
			_cheat_step = 0
			_toggle_secret_god_mode()
	elif pressed_action == _CHEAT_SEQUENCE[0]:
		_cheat_step = 1
		_cheat_last_ms = now
	else:
		_cheat_step = 0

func _toggle_secret_god_mode() -> void:
	debug_invincible = not debug_invincible
	print("Código secreto: God mode %s" % ("ACTIVADO" if debug_invincible else "DESACTIVADO"))
	if debug_invincible:
		_start_god_mode_blink()
	else:
		_stop_god_mode_blink()

func _start_god_mode_blink() -> void:
	_stop_god_mode_blink()
	_god_mode_tween = create_tween()
	_god_mode_tween.set_loops()
	_god_mode_tween.tween_property(sprite, "modulate:a", 0.3, 0.25)
	_god_mode_tween.tween_property(sprite, "modulate:a", 1.0, 0.25)

func _stop_god_mode_blink() -> void:
	if _god_mode_tween != null and _god_mode_tween.is_valid():
		_god_mode_tween.kill()
	_god_mode_tween = null
	sprite.modulate.a = 1.0

# =============================================================================
# MÁQUINA DE ESTADOS PRINCIPAL
# =============================================================================
func _physics_process(delta):
	# El jugador choca con los enemigos (capa 2) normalmente, pero los ATRAVIESA
	# mientras es invulnerable (tras recibir daño o durante el esquive).
	set_collision_mask_value(2, not is_invulnerable)

	# Frenesí del casco de capitán (se recalcula; no sobrescribe otros efectos).
	_update_frenzy()

	if is_frozen:
		velocity = velocity.move_toward(Vector2.ZERO, friction * delta)
		move_and_slide()
		_update_walk_animation(delta)
		_update_dodge_ui()
		return

	match current_state:
		State.MOVE:
			move_state(delta)
		State.DODGE:
			dodge_state(delta)
		State.TAKING_DAMAGE:
			taking_damage_state(delta)
		State.DEAD:
			dead_state(delta)

	# El HUD del esquive se refresca siempre (para ver bajar el cooldown)
	_update_dodge_ui()

# =============================================================================
# ESTADO: MOVIMIENTO
# =============================================================================
func move_state(delta):
	_read_movement_input(delta)
	_update_walk_animation(delta)

	# Iniciar esquive: requiere dirección y que el cooldown haya terminado
	if Input.is_action_just_pressed("dodge") and dodge_cooldown.is_stopped():
		start_dodge()

func _read_movement_input(delta: float) -> void:
	# 'movement_locked' (tutorial): inmoviliza al jugador pero le deja DISPARAR.
	input_direction = Vector2.ZERO if movement_locked else Input.get_vector("Izquierda", "Derecha", "Arriba", "Abajo")
	var target := input_direction.normalized() * (speed * _frenzy_speed_mult)
	if input_direction != Vector2.ZERO:
		velocity = velocity.move_toward(target, acceleration * delta)
		last_direction = input_direction.normalized()
	else:
		velocity = velocity.move_toward(Vector2.ZERO, friction * delta)
	move_and_slide()

# =============================================================================
# ESTADO: ESQUIVE (GIRAR)
# =============================================================================
func start_dodge():
	current_state = State.DODGE
	dodge_elapsed = 0.0
	_stop_hurt_blink()   # el esquive tiene su propia animación (giro)

	# La dirección del esquive es la del input o, si está quieto, la última
	dodge_direction = input_direction.normalized()
	if dodge_direction == Vector2.ZERO:
		dodge_direction = last_direction

	velocity = dodge_direction * dodge_speed
	is_invulnerable = true

	Audio.play("dodge", 0.05)   # esquive manual y automático pasan por aquí

	dodge_timer.start()
	dodge_cooldown.start()
	sprite.play("run")
	sprite.speed_scale = 2.2
	_spawn_dust(1.3)

func dodge_state(delta):
	velocity = dodge_direction * dodge_speed
	move_and_slide()

	dodge_elapsed += delta
	var t = clampf(dodge_elapsed / dodge_duration, 0.0, 1.0)
	var eased_t = t * t * (3.0 - 2.0 * t)
	sprite.rotation = eased_t * TAU * dodge_spin_turns
	var stretch = sin(t * PI) * dodge_stretch_amount
	sprite.scale = _base_sprite_scale * Vector2(1.0 + stretch, 1.0 - stretch)

func _on_dodge_timer_timeout():
	is_invulnerable = false
	sprite.rotation = 0.0
	sprite.scale = _base_sprite_scale
	sprite.speed_scale = 1.0
	velocity = Vector2.ZERO
	if current_state == State.DODGE:
		current_state = State.MOVE

# =============================================================================
# ESTADO: RECIBIR DAÑO
# =============================================================================
func take_damage(amount: int):
	# Modo invencible de depuración (solo se activa desde DEV-ROOM)
	if debug_invincible:
		return
	# No recibir daño si está muerto, invulnerable o esquivando
	if current_state == State.DEAD or is_invulnerable or current_state == State.DODGE:
		return

	# Esquiva automática (ítem): probabilidad de esquivar el golpe por completo.
	# Suelta una nube de polvo para indicarlo visualmente.
	if autododge_level > 0 and randf() < 0.25 * autododge_level:
		_spawn_dust(1.6)
		start_dodge()
		return

	current_state = State.TAKING_DAMAGE
	vida = clamp(vida - amount, 0, vida_max)
	_update_health_ui()

	# Tinte rojo para indicar el golpe
	sprite.modulate = Color(1, 0.4, 0.4)

	if vida <= 0:
		_die()
		return

	is_invulnerable = true
	damage_timer.start()
	_start_hurt_blink()   # parpadeo mientras dura la invulnerabilidad

func _start_hurt_blink() -> void:
	# Parpadeo rojo/transparente durante el periodo de invulnerabilidad, para
	# avisar de que el jugador NO recibe daño en ese lapso.
	if _hurt_blink != null and _hurt_blink.is_valid():
		_hurt_blink.kill()
	_hurt_blink = create_tween()
	_hurt_blink.set_loops()
	_hurt_blink.tween_property(sprite, "modulate", Color(1.0, 0.45, 0.45, 1.0), 0.11)
	_hurt_blink.tween_property(sprite, "modulate", Color(1.0, 1.0, 1.0, 0.4), 0.11)

func _stop_hurt_blink() -> void:
	if _hurt_blink != null and _hurt_blink.is_valid():
		_hurt_blink.kill()
	_hurt_blink = null
	sprite.modulate = Color.WHITE

func _spawn_dust(dust_scale: float = 1.6) -> void:
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	if host == null:
		return
	var fx = EFFECT_SCENE.instantiate()
	host.add_child(fx)
	fx.global_position = global_position
	fx.scale = Vector2(dust_scale, dust_scale)
	fx.play_effect("dust")

func taking_damage_state(delta):
	_read_movement_input(delta)
	_update_walk_animation(delta)

	# También se puede esquivar para escapar
	if Input.is_action_just_pressed("dodge") and dodge_cooldown.is_stopped():
		start_dodge()

func _on_damage_timer_timeout():
	# Si estamos esquivando, NO tocar la invulnerabilidad: el esquive la controla
	# (así el dodge mantiene invulnerabilidad durante todo su recorrido).
	if current_state == State.DODGE:
		return
	is_invulnerable = false
	_stop_hurt_blink()
	if current_state == State.TAKING_DAMAGE:
		current_state = State.MOVE

# =============================================================================
# ESTADO: MUERTE
# =============================================================================
func _die():
	current_state = State.DEAD
	velocity = Vector2.ZERO
	_stop_hurt_blink()
	sprite.modulate = Color(0.5, 0.5, 0.5)
	sprite.rotation = 0.0
	sprite.scale = _base_sprite_scale
	sprite.speed_scale = 1.0
	sprite.position.y = 0.0
	sprite.play("idle")
	died.emit()

func dead_state(_delta):
	velocity = Vector2.ZERO
	move_and_slide()

# =============================================================================
# SPIN-BULLET
# =============================================================================
func _shoot_spin_bullet(pattern: int = 0):
	"""Instancia la Spin-Bullet y la pone a orbitar alrededor del jugador en la
	dirección del mouse. 'pattern' elige la trayectoria de giro (0/1)."""
	if spin_bullet_scene == null or not shoot_cooldown.is_stopped():
		return

	Audio.play("shoot", 0.06)   # leve variación de tono para que no suene mecánico

	var dir = get_global_mouse_position() - global_position
	if dir.length() < 1.0:
		dir = last_direction

	var bullet = spin_bullet_scene.instantiate()
	bullet.damage = bullet_damage + _frenzy_damage_bonus
	# Habilidades de ítems que lleva cada SpinShot
	bullet.bounce_count = bounce_level
	bullet.has_split = has_split
	bullet.lethal_chance = lethal_level * 0.01
	bullet.bullet_scene = spin_bullet_scene
	# Añadir a la raíz de la escena para que orbite en espacio de mundo
	var host = get_tree().current_scene
	if host == null:
		host = get_parent()
	host.add_child(bullet)

	# setup() coloca la bala, fija el centro de giro y el patrón de trayectoria
	if bullet.has_method("setup"):
		bullet.setup(self, dir, pattern)

	shoot_cooldown.start()

# =============================================================================
# ANIMACIONES DEL PERSONAJE
# =============================================================================
func _update_walk_animation(delta: float) -> void:
	if input_direction.x != 0.0:
		sprite.flip_h = input_direction.x < 0.0

	var speed_ratio := velocity.length() / speed

	if speed_ratio > 0.03:
		sprite.play("run")
		sprite.speed_scale = lerpf(run_speed_scale_min, run_speed_scale_max, clampf(speed_ratio, 0.0, 1.0))
		_idle_time = 0.0
		sprite.position.y = move_toward(sprite.position.y, 0.0, 300.0 * delta)
	else:
		sprite.play("idle")
		sprite.speed_scale = idle_speed_scale
		_idle_time += delta * idle_bob_speed
		sprite.position.y = sin(_idle_time) * idle_bob_amplitude

# =============================================================================
# ACTUALIZACIÓN DEL HUD
# =============================================================================
func _update_health_ui():
	health_bar.value = vida
	# Solo la cantidad de vida actual.
	health_label.text = str(vida)

func _update_dodge_ui():
	if dodge_cooldown == null:
		return

	# La barra de esquive no muestra texto; solo se llena/atenúa.
	if dodge_cooldown.is_stopped():
		dodge_bar.value = dodge_bar.max_value
		dodge_bar.modulate = Color.WHITE
	else:
		var ratio = 1.0 - (dodge_cooldown.time_left / dodge_cooldown.wait_time)
		dodge_bar.value = ratio * dodge_bar.max_value
		dodge_bar.modulate = Color(0.75, 0.75, 0.8)

# =============================================================================
# CONGELAR (usado por la tienda)
# =============================================================================
func set_frozen(value: bool) -> void:
	is_frozen = value
	if is_frozen:
		velocity = Vector2.ZERO
		sprite.play("idle")

func set_hud_visible(value: bool) -> void:
	"""Muestra/oculta el HUD del jugador (vida, esquive, ayuda) para que no
	estorbe al abrir el inventario u otras pantallas."""
	if has_node("HUD/Root"):
		$HUD/Root.visible = value

# =============================================================================
# MEJORAS (usadas por la tienda)
# =============================================================================
func full_heal() -> void:
	"""Cura al jugador al máximo (curación automática entre rondas)."""
	vida = vida_max
	_update_health_ui()

func upgrade_max_health(amount: int) -> void:
	vida_max += amount
	vida = clamp(vida + amount, 0, vida_max)  # también cura
	health_bar.max_value = vida_max
	_update_health_ui()

func upgrade_bullet_damage(amount: int) -> void:
	bullet_damage += amount

func upgrade_speed(amount: float) -> void:
	speed += amount

func upgrade_fire_rate(factor: float) -> void:
	"""Mejora la cadencia reduciendo el cooldown entre disparos."""
	shoot_cooldown_time = maxf(0.05, shoot_cooldown_time * factor)
	if shoot_cooldown != null:
		shoot_cooldown.wait_time = shoot_cooldown_time

# =============================================================================
# ÍTEMS CON HABILIDAD ESPECIAL
# =============================================================================
func add_coin_heal() -> void:
	coin_heal_level = min(coin_heal_level + 1, 3)

func add_bounce() -> void:
	bounce_level = min(bounce_level + 1, 3)

func enable_split() -> void:
	has_split = true

func add_lethal() -> void:
	lethal_level += 1   # ilimitado, +1% por compra

func add_autododge() -> void:
	autododge_level = min(autododge_level + 1, 3)

func on_coin_collected() -> void:
	"""Robo de vida: cada moneda tiene 25% por nivel de curar 1-3 (máx 75%)."""
	if coin_heal_level <= 0:
		return
	if randf() < 0.25 * coin_heal_level:
		vida = clamp(vida + randi_range(1, 3), 0, vida_max)
		_update_health_ui()

# =============================================================================
# INVENTARIO (registro de ítems comprados, para la UI de inventario)
# =============================================================================
func register_item(item: Dictionary) -> void:
	var id := String(item.get("id", ""))
	if id == "":
		return
	if inventory.has(id):
		inventory[id]["count"] += 1
	else:
		inventory[id] = {
			"name": item.get("name", id),
			"desc": item.get("desc", ""),
			"icon": item.get("icon", null),
			"count": 1,
		}

func get_item_count(id: String) -> int:
	return inventory[id]["count"] if inventory.has(id) else 0

# =============================================================================
# AJUSTES DE ESQUIVE Y VIDA (helpers reutilizables; todo se ACUMULA)
# =============================================================================
func modify_max_health(amount: int) -> void:
	vida_max = maxi(1, vida_max + amount)
	if amount > 0:
		vida = clamp(vida + amount, 0, vida_max)   # subir vida también cura
	else:
		vida = clamp(vida, 0, vida_max)            # bajar vida no cura
	health_bar.max_value = vida_max
	_update_health_ui()

func reduce_dodge_cooldown(sec: float) -> void:
	dodge_cooldown_time = maxf(0.2, dodge_cooldown_time - sec)
	if dodge_cooldown != null:
		dodge_cooldown.wait_time = dodge_cooldown_time

func increase_dodge_cooldown(sec: float) -> void:
	dodge_cooldown_time += sec
	if dodge_cooldown != null:
		dodge_cooldown.wait_time = dodge_cooldown_time

func increase_dodge_distance(amount: float) -> void:
	# Más "distancia" de esquive = más velocidad durante el dash.
	dodge_speed += amount

func _update_frenzy() -> void:
	if not has_capitan_frenzy:
		return
	var should := vida > 0 and float(vida) < float(vida_max) * 0.5
	if should and not _frenzy_active:
		_frenzy_active = true
		_frenzy_speed_mult = FRENZY_SPEED_MULT
		_frenzy_damage_bonus = FRENZY_DAMAGE_BONUS
	elif not should and _frenzy_active:
		_frenzy_active = false
		_frenzy_speed_mult = 1.0
		_frenzy_damage_bonus = 0

# =============================================================================
# CASCOS (ítems de la tienda)
# =============================================================================
func add_basic_helmet() -> void:
	# Casco de minion: -1 vida, +2 daño; +distancia y -cooldown de esquive.
	modify_max_health(-1)
	bullet_damage += 2
	increase_dodge_distance(140.0)
	reduce_dodge_cooldown(0.2)

func add_soldier_helmet() -> void:
	# Casco de caballero: +5 vida, +3 daño; -20 velocidad, +cooldown de esquive.
	modify_max_health(5)
	bullet_damage += 3
	speed = maxf(60.0, speed - 20.0)
	increase_dodge_cooldown(0.25)

func add_viking_helmet() -> void:
	# Casco vikingo: acumula prob. de empuje hasta el 50%; pasado el tope, da
	# +1 vida y +3 daño por compra en su lugar.
	if viking_push_chance < VIKING_PUSH_CAP:
		modify_max_health(-3)
		bullet_damage += 5
		viking_push_chance = minf(VIKING_PUSH_CAP, viking_push_chance + 0.10)
	else:
		modify_max_health(1)
		bullet_damage += 3

func add_capitan_helmet() -> void:
	# Casco de capitán (desbloqueable): +10 vida, +5 daño; frenesí <50% vida.
	modify_max_health(10)
	bullet_damage += 5
	has_capitan_frenzy = true

func add_grancapitan_helmet() -> void:
	# Casco de gran capitán (desbloqueable): +15 vida, +10 daño; invoca 4
	# Bigminion_capitan ALIADOS (con indicador azul, sin invocar otros minions).
	modify_max_health(15)
	bullet_damage += 10
	_summon_ally_capitanes()

func _summon_ally_capitanes() -> void:
	if ally_capitan_scene == null:
		return
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	for i in 4:
		var pos: Vector2 = global_position + Vector2.RIGHT.rotated(TAU * i / 4.0) * 150.0
		Game.telegraph_spawn(host, pos, Game.INDICATOR_ALLY, 2.2, 0.7, func():
			var c = ally_capitan_scene.instantiate()
			c.is_ally = true
			host.add_child(c)
			c.global_position = pos)

# =============================================================================
# EMPUJE DEL CASCO VIKINGO
# =============================================================================
func _on_push_area_body_entered(body: Node2D) -> void:
	if viking_push_chance <= 0.0:
		return
	if body == self or not body.is_in_group("enemy") or not body.has_method("push"):
		return
	if randf() < viking_push_chance:
		var dir := (body.global_position - global_position)
		dir = dir.normalized() if dir.length() > 0.0 else Vector2.RIGHT
		body.push(dir * VIKING_PUSH_FORCE)
