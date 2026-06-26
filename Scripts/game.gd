extends Node

# =============================================================================
# GAME — Singleton (autoload) con el estado global del juego
# =============================================================================
# Gestiona la economía (monedas), los DESBLOQUEOS persistentes entre partidas
# (cascos que se ganan al derrotar ciertos enemigos) y un ayudante para mostrar
# el indicador de aparición antes de invocar enemigos/aliados.

signal coins_changed(total: int)

const SAVE_PATH := "user://spinshot_save.cfg"
const SPAWN_INDICATOR := preload("res://Scenes/SpawnIndicator.tscn")

# Colores del indicador: rojo = enemigos, azul = aliados.
const INDICATOR_ENEMY := Color(1.0, 0.22, 0.2, 0.95)
const INDICATOR_ALLY := Color(0.3, 0.55, 1.0, 0.95)

var coins: int = 0

# Inflación de la tienda: cada compra encarece los precios de los FUTUROS ítems.
# Se reinicia en cada partida (no es persistente).
const INFLATION_FACTOR := 1.08   # +8% al precio base por cada compra
var price_scale: float = 1.0

# Desbloqueos persistentes (id -> true). Se guardan en disco.
var unlocks: Dictionary = {}

func _ready() -> void:
	_load()

# =============================================================================
# ECONOMÍA
# =============================================================================
func add_coins(amount: int) -> void:
	coins += amount
	coins_changed.emit(coins)

func spend(amount: int) -> bool:
	if coins >= amount:
		coins -= amount
		coins_changed.emit(coins)
		return true
	return false

func reset() -> void:
	# Reinicia SOLO el estado de partida (monedas e inflación). Los desbloqueos persisten.
	coins = 0
	price_scale = 1.0
	coins_changed.emit(coins)

# =============================================================================
# INFLACIÓN DE LA TIENDA
# =============================================================================
func scaled_cost(base_cost: int) -> int:
	"""Precio actual de un ítem dado su coste base, según la inflación acumulada."""
	return int(ceil(base_cost * price_scale))

func register_purchase() -> void:
	"""Cada compra encarece los precios de los futuros ítems de la tienda."""
	price_scale *= INFLATION_FACTOR

# =============================================================================
# DESBLOQUEOS PERSISTENTES
# =============================================================================
func is_unlocked(id: String) -> bool:
	return unlocks.get(id, false)

func unlock(id: String) -> void:
	if unlocks.get(id, false):
		return
	unlocks[id] = true
	_save()

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for key in cfg.get_section_keys("unlocks"):
		unlocks[key] = bool(cfg.get_value("unlocks", key, false))

func _save() -> void:
	var cfg := ConfigFile.new()
	for key in unlocks.keys():
		cfg.set_value("unlocks", key, unlocks[key])
	cfg.save(SAVE_PATH)

# =============================================================================
# INDICADOR DE INVOCACIÓN (reutiliza el sprite del Gamemode)
# =============================================================================
func telegraph_spawn(host: Node, pos: Vector2, color: Color, ind_scale: float, delay: float, cb: Callable) -> void:
	"""Muestra el indicador en 'pos' durante 'delay' s y luego ejecuta 'cb'
	(que instancia el enemigo/aliado). Lo usan jefes, capitanes y el casco de
	gran capitán. El color distingue enemigos (rojo) de aliados (azul)."""
	if host == null or not is_instance_valid(host):
		_safe_call(cb)
		return
	var ind = SPAWN_INDICATOR.instantiate()
	host.add_child(ind)
	ind.setup(pos, color, ind_scale)
	await get_tree().create_timer(delay).timeout
	if is_instance_valid(ind):
		ind.queue_free()
	# El host puede haber muerto durante el retardo (p. ej. el minijefe al invocar):
	# si su escena ya no existe, no instanciamos nada.
	if not is_instance_valid(host):
		return
	_safe_call(cb)

func _safe_call(cb: Callable) -> void:
	# Una lambda cuyo objeto dueño fue liberado durante el await sigue dando
	# is_valid()==true pero revienta al llamarla ("invalid instance"). Comprobamos
	# que el objeto al que pertenece siga vivo antes de ejecutarla.
	if not cb.is_valid():
		return
	var owner = cb.get_object()
	if owner != null and not is_instance_valid(owner):
		return
	cb.call()
