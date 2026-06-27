extends Enemy

# =============================================================================
# CHARGER MINION — Enemigo Cargador
# =============================================================================
# Persigue al jugador y, periódicamente, hace una breve carga (telegrafiada)
# en línea recta a gran velocidad. Su amenaza viene de la velocidad + daño.

@export_group("Carga")
@export var charge_interval: float = 2.2   # Tiempo entre cargas
@export var windup_time: float = 0.85      # Aviso antes de cargar (telegrafía); más alto = más margen para reaccionar
@export var charge_time: float = 0.45      # Duración de la carga
@export var charge_speed: float = 820.0    # Velocidad durante la carga
@export var charge_range: float = 600.0    # Distancia a la que decide cargar

enum ChargePhase { CHASE, WINDUP, CHARGE }
var _phase: int = ChargePhase.CHASE
var _phase_timer: float = 0.0
var _cooldown: float = 0.0
var _charge_dir: Vector2 = Vector2.ZERO

func _ready() -> void:
	super._ready()
	_cooldown = 1.0   # primera embestida poco después de aparecer

func _update_ai(delta: float) -> void:
	if player == null:
		velocity = Vector2.ZERO
		return

	var to_player := player.global_position - global_position

	match _phase:
		ChargePhase.CHASE:
			# Persecución normal
			if to_player.length() > stop_distance:
				velocity = to_player.normalized() * get_speed()
			else:
				velocity = Vector2.ZERO
			_cooldown -= delta
			# Cuando el jugador está en rango y acaba el enfriamiento, embiste.
			# (los maniquíes de prueba también embisten, pero sin causar daño)
			if _cooldown <= 0.0 and to_player.length() <= charge_range:
				_phase = ChargePhase.WINDUP
				_phase_timer = windup_time

		ChargePhase.WINDUP:
			# Telegrafía: se queda quieto y parpadea antes de embestir
			velocity = Vector2.ZERO
			sprite.modulate = Color(1.0, 0.7, 0.2)
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_charge_dir = to_player.normalized()
				if _charge_dir == Vector2.ZERO:
					_charge_dir = Vector2.RIGHT
				_phase = ChargePhase.CHARGE
				_phase_timer = charge_time
				sprite.modulate = Color.WHITE

		ChargePhase.CHARGE:
			# Embestida recta a gran velocidad
			velocity = _charge_dir * charge_speed
			_shove_others()   # aparta a los enemigos que se cruzan
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_phase = ChargePhase.CHASE
				_cooldown = charge_interval

var demo_charge_dir: Vector2 = Vector2.RIGHT   # dirección de la embestida en el tutorial

func demo_ability() -> void:
	"""Tutorial: telegrafía y embiste en 'demo_charge_dir', empujando a los pinos.
	Usa _demo_velocity para moverse aun con la IA congelada (ai_frozen)."""
	sprite.modulate = Color(1.0, 0.7, 0.2)   # telegrafía
	await get_tree().create_timer(windup_time).timeout
	sprite.modulate = Color.WHITE
	var dir := demo_charge_dir.normalized() if demo_charge_dir.length() > 0.0 else Vector2.RIGHT
	var t := 0.0
	while t < charge_time + 0.35:
		_demo_velocity = dir * charge_speed
		_shove_others()
		await get_tree().process_frame
		t += get_process_delta_time()
	_demo_velocity = Vector2.ZERO

func _shove_others() -> void:
	"""Durante la embestida, empuja ligeramente a otros enemigos en su trayectoria."""
	var pushed := false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == self or not is_instance_valid(e) or not e.has_method("push"):
			continue
		var off: Vector2 = e.global_position - global_position
		if off.length() <= 70.0:
			var dir := off.normalized() if off.length() > 0.0 else _charge_dir.rotated(PI / 2.0)
			e.push(dir * 260.0)
			pushed = true
	# Un solo golpe de empuje por contacto (debounce global anti-saturación).
	# Espacial: se oye según la posición del cargador respecto al jugador.
	if pushed:
		Audio.play_at("charge_push", global_position, 0.08, 180)
