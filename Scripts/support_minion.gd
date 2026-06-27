extends Enemy

# =============================================================================
# SUPPORT MINION — Enemigo de Apoyo
# =============================================================================
# No ataca al jugador. Mantiene distancia y cura (regenera vida) a los enemigos
# cercanos. Intenta colocarse DETRÁS de otros enemigos para protegerse.

@export_group("Apoyo")
@export var heal_amount: int = 2
@export var heal_interval: float = 1.5
@export var heal_radius: float = 240.0
@export var preferred_distance: float = 360.0  # Distancia mínima al jugador
@export var damage_buff: int = 1               # +daño que otorga a aliados en rango
@export var boss_heal_amount: int = 3          # cura por tick cuando sigue a un jefe

const EFFECT_SCENE := preload("res://Scenes/Effect.tscn")

var _heal_timer: float = 0.0
var _pink_tween: Tween = null
# Si se asigna (lo hace el jefe en su fase crítica), este Apoyo CURA a ese
# objetivo (el jefe) en vez de potenciar/curar al resto de enemigos.
var heal_target: Node = null

func _ready() -> void:
	super._ready()
	melee_enabled = false   # no ataca cuerpo a cuerpo
	_heal_timer = heal_interval

func _update_ai(delta: float) -> void:
	# Modo "curar al jefe" (fase crítica del Boss): sigue al jefe y le cura la
	# barra de vida; no potencia ni cura a otros enemigos.
	if heal_target != null:
		_heal_boss_mode(delta)
		return

	# El Apoyo ya NO depende del jugador: busca el GRUPO de enemigos (grande o
	# pequeño) y se queda dentro de él para curar/potenciar. Navega evitando los
	# bordes para no quedarse pegado a las paredes.
	var cluster := _best_cluster()
	if cluster == _NO_CLUSTER:
		# Sin otros enemigos: frenar suavemente (no vagar contra las paredes).
		velocity = _avoid_bounds(velocity.move_toward(Vector2.ZERO, get_speed()))
	else:
		var to: Vector2 = cluster - global_position
		var d := to.length()
		# Mantenerse DENTRO del grupo (a media distancia de curación) sin pegarse.
		var keep := heal_radius * 0.45
		if d > keep:
			velocity = _avoid_bounds(to.normalized() * get_speed())
		else:
			velocity = _avoid_bounds(velocity.move_toward(Vector2.ZERO, get_speed()))

	# Aura de daño: refresca el +daño en todos los aliados dentro del radio cada
	# frame. Al salir del rango deja de refrescarse y la bonificación caduca.
	_apply_damage_aura()

	# Curación periódica de aliados cercanos
	_heal_timer -= delta
	if _heal_timer <= 0.0:
		_heal_timer = heal_interval
		_heal_allies()

func _heal_boss_mode(delta: float) -> void:
	# Sigue al jefe y se queda cerca; si el jefe muere, este Apoyo desaparece.
	if not is_instance_valid(heal_target):
		queue_free()
		return
	var to: Vector2 = heal_target.global_position - global_position
	if to.length() > heal_radius * 0.5:
		velocity = _avoid_bounds(to.normalized() * get_speed())
	else:
		velocity = _avoid_bounds(velocity.move_toward(Vector2.ZERO, get_speed()))
	_heal_timer -= delta
	if _heal_timer <= 0.0:
		_heal_timer = heal_interval
		_heal_boss()

func _heal_boss() -> void:
	if not is_instance_valid(heal_target) or not heal_target.has_method("heal"):
		return
	heal_target.heal(boss_heal_amount)   # cura LENTA de la barra del jefe
	_spawn_hearts(heal_target)
	_spawn_hearts(self)
	_pink_flash()
	Audio.play_at("support", global_position, 0.06, 600, -5.0)

const _NO_CLUSTER := Vector2(INF, INF)

func _best_cluster() -> Vector2:
	"""Centroide del grupo de enemigos MÁS DENSO (el que tiene más vecinos en
	'heal_radius'). Así el Apoyo gravita hacia los grupos grandes y, si solo hay
	uno pequeño o suelto, va igualmente hacia él. Devuelve _NO_CLUSTER si no hay
	otros enemigos a los que apoyar."""
	var enemies := get_tree().get_nodes_in_group("enemy")
	var best_center := _NO_CLUSTER
	var best_count := 0
	for e in enemies:
		if e == self or not is_instance_valid(e):
			continue
		var sum: Vector2 = e.global_position
		var n := 1
		for o in enemies:
			if o == self or o == e or not is_instance_valid(o):
				continue
			if e.global_position.distance_to(o.global_position) <= heal_radius:
				sum += o.global_position
				n += 1
		if n > best_count:
			best_count = n
			best_center = sum / float(n)
	return best_center

func demo_ability() -> void:
	"""Tutorial: potencia/cura a los maniquíes cercanos varias veces para mostrar
	su aura, sin moverse."""
	for i in 4:
		_apply_damage_aura()
		_heal_allies()
		await get_tree().create_timer(0.6).timeout

func _apply_damage_aura() -> void:
	if damage_buff <= 0:
		return
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == self or not is_instance_valid(e):
			continue
		if global_position.distance_to(e.global_position) <= heal_radius and e.has_method("apply_damage_buff"):
			# Duración corta: se renueva cada frame mientras siga en rango.
			e.apply_damage_buff(damage_buff, 0.3)

func _heal_allies() -> void:
	var healed := false
	for e in get_tree().get_nodes_in_group("enemy"):
		if e == self or not is_instance_valid(e):
			continue
		if global_position.distance_to(e.global_position) <= heal_radius and e.has_method("heal"):
			e.heal(heal_amount)
			_spawn_hearts(e)   # efecto de corazones sobre el aliado beneficiado
			healed = true
	if healed:
		_spawn_hearts(self)   # también sobre el propio Apoyo
		_pink_flash()
		# Espacial + debounce largo + algo más bajo: con varios Apoyos curando a la
		# vez no se satura (antes sonaba demasiadas veces).
		Audio.play_at("support", global_position, 0.06, 600, -5.0)

func _spawn_hearts(node: Node2D) -> void:
	"""Efecto de corazones (sheet del Apoyo). Se añade como hijo del beneficiado
	para que se renderice sobrepuesto y le siga; se autodestruye al terminar."""
	if not is_instance_valid(node):
		return
	var fx = EFFECT_SCENE.instantiate()
	node.add_child(fx)
	fx.position = Vector2(0, -20)
	fx.scale = Vector2(2.6, 2.6)   # mucho más grande para que destaque
	fx.z_index = 60
	fx.play_effect("hearts")

func _pink_flash() -> void:
	# Pintar el sprite de rosa de manera intermitente mientras usa su habilidad.
	if _pink_tween != null and _pink_tween.is_valid():
		_pink_tween.kill()
	_pink_tween = create_tween()
	_pink_tween.set_loops(3)
	_pink_tween.tween_property(sprite, "modulate", Color(1.0, 0.5, 0.85), 0.13)
	_pink_tween.tween_property(sprite, "modulate", _base_modulate(), 0.13)
