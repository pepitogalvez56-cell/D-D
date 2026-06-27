extends Node

# =============================================================================
# GAME MODE — Bucle de juego reutilizable (oleadas, tienda y pantallas)
# =============================================================================
# Componente que se instancia en cualquier escena con un jugador (Main, DEV-ROOM).
# Gestiona:
#   - Oleadas por etapas (Minions / BigMinions / BulletMinions), 60s cada una.
#   - Tienda entre oleadas (con tirada de dados).
#   - Pantallas de inicio, victoria y muerte.
# No construye el suelo ni coloca al jugador: de eso se encargan las escenas.

@export_group("Escenas de enemigos")
@export var minion_scene: PackedScene
@export var bigminion_scene: PackedScene
@export var bulletminion_scene: PackedScene
@export var charger_scene: PackedScene
@export var support_scene: PackedScene

@export_group("Variantes y minijefe")
@export var capitan_scene: PackedScene     # Bigminion_capitan
@export var sad_scene: PackedScene         # Bullet_minion_sad
@export var gotica_scene: PackedScene      # Bullet_minion_gotica
@export var miniboss_scene: PackedScene    # Bigminion_gran_capitan (oleada 10)

@export_group("Jefe")
@export var boss_scene: PackedScene        # Aparece al terminar la última oleada

@export_group("Oleadas")
@export var spawn_radius: float = 480.0   # Distancia a la que aparecen del jugador
@export var wave_duration: float = 40.0   # Segundos que dura cada oleada
@export var total_waves: int = 10         # Tras la última oleada aparece el jefe

@export_group("Aparición por grupos")
@export var spawn_warning_time: float = 1.2   # Aviso visual antes de cada grupo
@export var large_group_chance: float = 0.4   # Probabilidad de grupo grande
@export var small_group_min: int = 3
@export var small_group_max: int = 5
@export var large_group_min: int = 7
@export var large_group_max: int = 11

@export_group("Modo")
# Main: debug_mode = false (auto), DEV-ROOM: debug_mode = true (manual + atajos).
@export var debug_mode: bool = false       # Activa los atajos de depuración (solo DEV-ROOM)
@export var auto_start_waves: bool = true  # Encadena las oleadas automáticamente (Main)

@onready var ui: CanvasLayer = $UI
@onready var wave_title: Label = $UI/WaveTitle
@onready var wave_label: Label = $UI/WaveLabel
@onready var timer_label: Label = $UI/TimerLabel
@onready var info_label: Label = $UI/InfoLabel
@onready var announce_label: Label = $UI/AnnounceLabel
@onready var shop = $UI/Shop
@onready var _music_base: AudioStreamPlayer = $MusicBase
@onready var _music_boss1: AudioStreamPlayer = $MusicBoss1
@onready var _music_boss2: AudioStreamPlayer = $MusicBoss2

var player: Node2D = null
var wave_number: int = 0
var wave_active: bool = false
var time_left: float = 0.0
var _spawn_accum: float = 0.0
var _waves: Array = []          # Tabla de oleadas (ver _build_waves)
var _boss: Node = null          # Instancia del jefe (si está vivo)
var _boss_pending: bool = false # Tras la oleada final: tienda y luego jefe
var _ground: TileMapLayer = null  # Suelo de césped para validar puntos de spawn
var _miniboss: Node = null        # Minijefe de la oleada 10
var _miniboss_active: bool = false  # Oleada 10 en curso (sin temporizador)

# Pantallas
var _start_screen: Control = null
var _victory_screen: Control = null
var _death_screen: Control = null
var _screen_active: bool = false

# Inventario (tecla E)
var _inventory_panel: Control = null
var _inventory_grid: GridContainer = null
var _inventory_open: bool = false
var _inv_stats_holder: Control = null

# Menú de opciones (tecla ESC)
var _options_panel: Control = null
var _options_open: bool = false
var _controls_box: Control = null
var _resolution_box: Control = null
var _language_box: Control = null
var _sound_box: Control = null
var _credits_box: Control = null
var _credits_label: RichTextLabel = null

# Tutoriales interactivos (ventana de cartas + secuencias scripteadas)
var tutorial_active: bool = false
var _tutorial: Node = null         # TutorialController (Scripts/tutorial.gd)
var _tutorial_box: Control = null  # ventana de selección de cartas
var _congrats_box: Control = null  # ventana de "Felicidades"

# Estado del texto contextual (info_label), para re-traducir al cambiar idioma
var _info_key: String = ""
var _info_args: Array = []

const UI_INVENTORY_TEX := preload("res://UI assets/UI_Inventario_E.png")
const UI_ESC_TEX := preload("res://UI assets/UI_ESC.png")
const UI_STAT_TEX := preload("res://UI assets/UI_stat.png")
const RECT_TEX := preload("res://UI assets/Rectangulo_UI_Para_texto.png")
# Recorte del marco de madera dentro del sprite Rectangulo (sin el relleno transparente)
const RECT_REGION := Rect2(18, 23, 108, 39)

# Indicador de aparición de enemigos (rojo, animado)
const SPAWN_INDICATOR := preload("res://Scenes/SpawnIndicator.tscn")
const INDICATOR_COLOR := Color(1.0, 0.22, 0.2, 0.95)

func _ready() -> void:
	randomize()
	# El GameMode (y su UI) sigue activo aunque el árbol esté en pausa,
	# para que las pantallas y sus botones funcionen.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_waves()
	Game.reset()

	shop.continue_pressed.connect(_on_shop_continue)
	shop.visible = false

	_build_screens()
	_build_inventory()
	_build_options()
	_build_tutorial_box()
	_build_congrats_box()
	# Controlador de tutoriales (secuencias scripteadas), aislado en su propio nodo.
	_tutorial = preload("res://Scripts/tutorial.gd").new()
	_tutorial.gm = self
	add_child(_tutorial)
	_style_labels()
	_update_wave_label()
	timer_label.text = ""
	info_label.text = ""

	I18n.language_changed.connect(_on_language_changed)

	call_deferred("_connect_player")
	_show_start()

func _style_labels() -> void:
	UiTheme.apply_label(wave_title)
	UiTheme.apply_label(wave_label)
	UiTheme.apply_label(info_label)
	UiTheme.apply_title(timer_label, 32)
	UiTheme.apply_title(announce_label, 48)

func _connect_player() -> void:
	player = _find_player()
	if player != null and player.has_signal("died"):
		if not player.died.is_connected(_on_player_died):
			player.died.connect(_on_player_died)

func _find_player() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

func _process(delta: float) -> void:
	# En modo tutorial el TutorialController controla las apariciones; el bucle de
	# oleadas normal no corre.
	if tutorial_active:
		return
	if _screen_active or get_tree().paused or not wave_active:
		return

	# Oleada del minijefe (10): sin temporizador, pero ahora SÍ aparecen algunos
	# refuerzos (grupos pequeños y más espaciados) además del propio minijefe.
	# Se gana al derrotar al minijefe (ver _on_miniboss_defeated).
	if _miniboss_active:
		_spawn_accum -= delta
		if _spawn_accum <= 0.0:
			_spawn_accum = _group_interval() * 1.5
			_spawn_group(true)   # solo grupos pequeños para no saturar
		return

	# Cuenta atrás de la oleada
	time_left -= delta
	_update_timer_label()
	if time_left <= 0.0:
		_end_wave()
		return

	_spawn_accum -= delta
	if _spawn_accum <= 0.0:
		_spawn_accum = _group_interval()
		_spawn_group()

func _unhandled_input(event: InputEvent) -> void:
	# F11 alterna pantalla completa (en cualquier momento, también en menús)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		_toggle_fullscreen()
		return
	if _screen_active:
		return
	# ESC: menú de opciones (o cierra lo que esté abierto)
	if event.is_action_pressed("ui_cancel"):
		if _inventory_open:
			_set_inventory(false)
		else:
			_set_options(not _options_open)
		return
	# E: inventario
	if event.is_action_pressed("inventory"):
		if not _options_open:
			_set_inventory(not _inventory_open)
		return
	if _options_open or _inventory_open:
		return
	# Atajos de depuración: SOLO en DEV-ROOM (debug_mode)
	if debug_mode:
		_handle_debug_input(event)

func _handle_debug_input(event: InputEvent) -> void:
	# Control de oleadas/jefe (DEV-ROOM): M = iniciar, N = terminar, B = jefe
	if event.is_action_pressed("start_wave") and not wave_active and not shop.visible:
		_start_wave()
	elif event.is_action_pressed("end_wave") and wave_active:
		_end_wave()
	elif event.is_action_pressed("spawn_boss"):
		_spawn_boss()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_debug_spawn(minion_scene)
			KEY_2:
				_debug_spawn(bigminion_scene)
			KEY_3:
				_debug_spawn(bulletminion_scene)
			KEY_4:
				_debug_spawn(charger_scene)
			KEY_5:
				_debug_spawn(support_scene)
			KEY_6:
				_debug_spawn_active(capitan_scene)
			KEY_7:
				_debug_spawn_active(sad_scene)
			KEY_8:
				_debug_spawn_active(gotica_scene)
			KEY_9:
				_debug_spawn_active(miniboss_scene)
			KEY_O:
				_enter_shop()
			KEY_C:
				Game.add_coins(100)
			KEY_G:
				_toggle_god_mode()

func _debug_spawn(scene: PackedScene) -> void:
	"""Genera un enemigo de prueba (no ataca) cerca del jugador."""
	if scene == null:
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()
	if player == null:
		return
	var e = scene.instantiate()
	if e.has_method("make_passive"):
		e.make_passive()
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	host.add_child(e)
	e.global_position = player.global_position + Vector2.RIGHT.rotated(randf() * TAU) * 320.0

func _debug_spawn_active(scene: PackedScene) -> void:
	"""Invoca un enemigo FUNCIONAL (no maniquí) cerca del jugador, para probar
	sus mecánicas. Usado por las variantes nuevas y el minijefe (teclas 6-9)."""
	if scene == null:
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()
	var e = scene.instantiate()
	_spawn_host().add_child(e)
	var origin: Vector2 = player.global_position if player != null else Vector2(960, 576)
	e.global_position = origin + Vector2.RIGHT.rotated(randf() * TAU) * 360.0

func _toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func _toggle_god_mode() -> void:
	if player == null or not is_instance_valid(player):
		player = _find_player()
	if player == null:
		return
	player.debug_invincible = not player.debug_invincible
	_set_info("God mode: %s", ["ON" if player.debug_invincible else "OFF"])

# =============================================================================
# OLEADAS
# =============================================================================
func _start_wave() -> void:
	wave_number += 1
	wave_active = true
	_spawn_accum = 0.0
	_update_wave_label()

	# Oleada final (10): minijefe sin temporizador.
	if wave_number >= total_waves and miniboss_scene != null:
		_start_miniboss_wave()
		return

	time_left = wave_duration
	_update_timer_label()
	if debug_mode:
		_set_info("Wave %d in progress  —  N: end", [wave_number])
	else:
		_set_info("Wave %d in progress", [wave_number])

func _start_miniboss_wave() -> void:
	_miniboss_active = true
	time_left = 0.0
	timer_label.text = ""          # sin temporizador en la oleada 10
	_spawn_accum = 6.0             # primeros refuerzos unos segundos tras el minijefe
	_set_info("Defeat the Gran Capitán!")
	_play_music(_music_boss1)
	_spawn_miniboss()

func _spawn_miniboss() -> void:
	if miniboss_scene == null:
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()
	if _ground == null or not is_instance_valid(_ground):
		_ground = _find_ground()
	var mb = miniboss_scene.instantiate()
	_spawn_host().add_child(mb)
	mb.global_position = _pick_grass_point_near_player() if player != null else Vector2(960, 400)
	if mb.has_signal("died"):
		mb.died.connect(_on_miniboss_defeated)
	_miniboss = mb

func _on_miniboss_defeated() -> void:
	_miniboss = null
	_miniboss_active = false
	_play_music(_music_base)
	# Tratar como fin de la oleada final: limpia, tienda y luego el jefe final.
	_end_wave()

func _end_wave() -> void:
	wave_active = false
	time_left = 0.0
	timer_label.text = ""
	_clear_info()
	_clear_enemies()
	# Recoger automáticamente las monedas que queden en el suelo al acabar la ronda
	_collect_all_coins()

	# En DEV-ROOM no se encadena nada automáticamente: el jugador usa los atajos.
	if debug_mode:
		_set_info("DEV-ROOM:  M = next wave  ·  O = shop  ·  B = boss")
		return

	# Aviso de oleada superada (~2s, centrado y grande) antes de mostrar la tienda.
	var is_final_wave := wave_number >= total_waves
	var announce := tr("Wave %d cleared!") % wave_number
	if is_final_wave:
		announce += tr("\nThe boss approaches...")
	_show_announce(announce)
	await get_tree().create_timer(2.0).timeout
	if not is_instance_valid(self):
		return
	_hide_announce()

	# Curación automática entre rondas, EXCEPTO en la ronda previa al jefe.
	if not is_final_wave:
		if player != null and is_instance_valid(player) and player.has_method("full_heal"):
			player.full_heal()

	# Main: tienda entre oleadas; tras la última, al salir aparece el jefe.
	if is_final_wave:
		_boss_pending = true
		_set_info("Buy upgrades and get ready for the BOSS")
	_enter_shop()

func _show_announce(text: String) -> void:
	announce_label.text = text
	announce_label.visible = true

func _hide_announce() -> void:
	announce_label.visible = false
	announce_label.text = ""

func _enter_shop() -> void:
	# Al entrar a la tienda: las balas en vuelo desaparecen y el jugador se
	# congela (las monedas en el suelo NO se tocan, se recogen en la próxima oleada).
	_clear_bullets()
	if player != null and is_instance_valid(player) and player.has_method("set_frozen"):
		player.set_frozen(true)
	# Ocultar el HUD del jugador para que no estorbe a la tienda
	_set_gameplay_ui_visible(false)
	shop.open(wave_number)

func _clear_bullets() -> void:
	for bullet in get_tree().get_nodes_in_group("spin_bullet"):
		bullet.queue_free()

func _on_shop_continue() -> void:
	if player != null and is_instance_valid(player) and player.has_method("set_frozen"):
		player.set_frozen(false)
	# Restaurar el HUD al salir de la tienda
	_set_gameplay_ui_visible(true)
	# En tutorial, el controlador decide qué pasa al cerrar la tienda (no oleadas).
	if tutorial_active:
		return
	if _boss_pending:
		# Al salir de la tienda tras la oleada final, aparece el jefe
		_boss_pending = false
		_spawn_boss()
	elif auto_start_waves:
		# Main: empieza automáticamente la siguiente oleada
		_start_wave()
	elif debug_mode:
		_set_info("DEV-ROOM:  M = next wave  ·  O = shop  ·  B = boss")

# =============================================================================
# TABLA DE OLEADAS
# =============================================================================
# Cada oleada define su intervalo de aparición y un "pool" de tipos de enemigo
# con pesos: [escena, peso]. El spawner elige al azar según esos pesos. Para
# modificar o añadir oleadas, edita _build_waves() (ver docs/oleadas.md).
func _build_waves() -> void:
	# Introducción progresiva de enemigos (ver docs/oleadas.md). En CADA oleada
	# aparecen minions + el resto del repertorio acumulado; las oleadas "sin
	# cambios" (8, 9) NO añaden un tipo nuevo: repiten el repertorio de la 7 con
	# más intensidad.
	#   R1 minions · R2 +bigminion · R3 +bulletminion · R4 +support
	#   R5 +charger (peso bajo: pocos a la vez) · R6 +variantes (sad/gótica)
	#   R7 +capitán · R8-R9 mismo repertorio (más intenso) · R10 minijefe.
	_waves = [
		{"interval": 0.8, "pool": [[minion_scene, 1]]},
		{"interval": 0.8, "pool": [[minion_scene, 5], [bigminion_scene, 1]]},
		{"interval": 0.9, "pool": [[minion_scene, 5], [bigminion_scene, 1], [bulletminion_scene, 1]]},
		{"interval": 0.9, "pool": [[minion_scene, 5], [bigminion_scene, 1], [bulletminion_scene, 1], [support_scene, 1]]},
		{"interval": 1.0, "pool": [[minion_scene, 5], [bigminion_scene, 2], [bulletminion_scene, 1], [support_scene, 1], [charger_scene, 1]]},
		{"interval": 1.0, "pool": [[minion_scene, 4], [bigminion_scene, 2], [bulletminion_scene, 1], [support_scene, 1], [charger_scene, 1], [sad_scene, 1], [gotica_scene, 1]]},
		{"interval": 1.0, "pool": [[minion_scene, 4], [bigminion_scene, 2], [bulletminion_scene, 1], [support_scene, 1], [charger_scene, 1], [sad_scene, 1], [gotica_scene, 1], [capitan_scene, 1]]},
		{"interval": 0.9, "pool": [[minion_scene, 4], [bigminion_scene, 2], [bulletminion_scene, 1], [support_scene, 1], [charger_scene, 2], [sad_scene, 1], [gotica_scene, 1], [capitan_scene, 1]]},
		{"interval": 0.9, "pool": [[minion_scene, 4], [bigminion_scene, 3], [bulletminion_scene, 2], [support_scene, 1], [charger_scene, 2], [sad_scene, 1], [gotica_scene, 1], [capitan_scene, 2]]},
		{"interval": 0.8, "pool": [[minion_scene, 4], [bigminion_scene, 3], [bulletminion_scene, 2], [support_scene, 1], [charger_scene, 2], [sad_scene, 1], [gotica_scene, 1], [capitan_scene, 2]]},
	]

func _spawn_interval() -> float:
	var idx := clampi(wave_number - 1, 0, _waves.size() - 1)
	return _waves[idx].get("interval", 1.0)

func _group_interval() -> float:
	# Como ahora aparecen grupos (varios enemigos), se espacian más que el
	# intervalo de un solo enemigo, y se cuenta también el tiempo de aviso.
	return _spawn_interval() * 3.0 + spawn_warning_time

func _pick_enemy_scene() -> PackedScene:
	"""Elige un tipo de enemigo de la oleada actual por peso (ignora nulos)."""
	var idx := clampi(wave_number - 1, 0, _waves.size() - 1)
	var pool: Array = _waves[idx].get("pool", [])
	var total := 0
	for entry in pool:
		if entry[0] != null:
			total += int(entry[1])
	if total <= 0:
		return minion_scene
	var roll := randi() % total
	for entry in pool:
		if entry[0] == null:
			continue
		roll -= int(entry[1])
		if roll < 0:
			return entry[0]
	return minion_scene

func _spawn_host() -> Node:
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	return host

# Genera un grupo (pequeño o grande) precedido de indicadores rojos en cada
# punto exacto donde aparecerá un enemigo.
func _spawn_group(force_small: bool = false) -> void:
	if player == null or not is_instance_valid(player):
		player = _find_player()
	if player == null:
		return
	if _ground == null or not is_instance_valid(_ground):
		_ground = _find_ground()

	var is_large := (not force_small) and randf() < large_group_chance
	var count := randi_range(large_group_min, large_group_max) if is_large \
		else randi_range(small_group_min, small_group_max)

	# Centro del grupo: punto válido (sobre césped) a distancia del jugador. Si el
	# jugador está pegado a un borde/esquina, se prueban otros ángulos y radios.
	var center := _pick_grass_point_near_player()
	var spread := 140.0 if is_large else 70.0

	# Cada enemigo se reparte alrededor del centro, pero SIEMPRE sobre césped.
	var positions: Array = []
	for i in count:
		positions.append(_grass_spawn_position(center, spread))

	_telegraph_and_spawn(positions, is_large)

# =============================================================================
# VALIDACIÓN DE PUNTOS DE APARICIÓN (deben caer sobre el TileMap de césped)
# =============================================================================
func _find_ground() -> TileMapLayer:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var named := scene.find_child("Ground", true, false)
	if named is TileMapLayer:
		return named as TileMapLayer
	return _first_tilemap(scene)

func _first_tilemap(node: Node) -> TileMapLayer:
	if node is TileMapLayer:
		return node
	for c in node.get_children():
		var r := _first_tilemap(c)
		if r != null:
			return r
	return null

func _is_grass_cell(cell: Vector2i) -> bool:
	# Hay tile y es del bloque de césped (atlas 0..2, 0..2), no del borde de piedra.
	if _ground.get_cell_source_id(cell) == -1:
		return false
	var a := _ground.get_cell_atlas_coords(cell)
	return a.x >= 0 and a.x <= 2 and a.y >= 0 and a.y <= 2

func _is_on_grass(world_pos: Vector2) -> bool:
	# Sin tilemap localizado no se puede validar: se acepta el punto.
	if _ground == null or not is_instance_valid(_ground):
		return true
	return _is_grass_cell(_ground.local_to_map(_ground.to_local(world_pos)))

func _pick_grass_point_near_player() -> Vector2:
	"""Devuelve un punto sobre césped alrededor del jugador. Prueba varios
	ángulos al radio deseado y, si el jugador está en un borde/esquina, reduce el
	radio hasta encontrar césped. Como último recurso usa un punto lejano válido."""
	var origin: Vector2 = player.global_position
	var radii := [spawn_radius, spawn_radius * 0.75, spawn_radius * 0.5, spawn_radius * 0.35]
	for r in radii:
		var start := randf() * TAU
		for i in range(16):
			var ang: float = start + i * (TAU / 16.0)
			var p: Vector2 = origin + Vector2(cos(ang), sin(ang)) * r
			if _is_on_grass(p):
				return p
	return _random_grass_point_far(origin)

func _grass_spawn_position(center: Vector2, spread: float) -> Vector2:
	"""Reparte un enemigo alrededor del centro sin salirse del césped."""
	for attempt in range(10):
		var p: Vector2 = center + Vector2(randf_range(-spread, spread), randf_range(-spread, spread))
		if _is_on_grass(p):
			return p
	return center   # el centro ya está validado sobre césped

func _random_grass_point_far(from: Vector2) -> Vector2:
	"""Elige una celda de césped al azar, preferentemente a distancia del jugador."""
	if _ground == null or not is_instance_valid(_ground):
		return from
	var used := _ground.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return from
	var fallback := from
	var min_d := spawn_radius * 0.5
	for attempt in range(48):
		var cx := used.position.x + (randi() % used.size.x)
		var cy := used.position.y + (randi() % used.size.y)
		var cell := Vector2i(cx, cy)
		if not _is_grass_cell(cell):
			continue
		var w: Vector2 = _ground.to_global(_ground.map_to_local(cell))
		fallback = w
		if w.distance_to(from) >= min_d:
			return w
	return fallback

func _telegraph_and_spawn(positions: Array, is_large: bool) -> void:
	# 1) Mostrar los indicadores de aparición unos segundos
	var indicators: Array = []
	var ind_scale := 2.6 if is_large else 1.9
	for p in positions:
		var ind = SPAWN_INDICATOR.instantiate()
		_spawn_host().add_child(ind)
		ind.setup(p, INDICATOR_COLOR, ind_scale)
		indicators.append(ind)

	await get_tree().create_timer(spawn_warning_time).timeout
	if not is_instance_valid(self):
		return

	# 2) Quitar los indicadores
	for ind in indicators:
		if is_instance_valid(ind):
			ind.queue_free()

	# Si la oleada terminó o se abrió la tienda/pantalla durante el aviso, no
	# aparecen los enemigos.
	if not wave_active or _screen_active or shop.visible:
		return

	# 3) Spawnear el grupo en los puntos avisados
	for p in positions:
		_spawn_enemy_at(p)

func _spawn_enemy_at(pos: Vector2) -> void:
	var scene := _pick_enemy_scene()
	if scene == null:
		return
	var enemy = scene.instantiate()
	_spawn_host().add_child(enemy)
	enemy.global_position = pos

func _clear_enemies() -> void:
	# Limpia los minions de la oleada, pero NO al jefe.
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if enemy.is_in_group("boss"):
			continue
		enemy.queue_free()
	# También retira los indicadores de aparición pendientes.
	for ind in get_tree().get_nodes_in_group("spawn_indicator"):
		ind.queue_free()

func _collect_all_coins() -> void:
	for c in get_tree().get_nodes_in_group("coin"):
		if c.has_method("collect"):
			c.collect()

#=============================================================================
# JEFE
#=============================================================================
func _spawn_boss() -> void:
	if _boss != null and is_instance_valid(_boss):
		return   #ya hay un jefe en juego
	if boss_scene == null:
		_show_victory()   #sin jefe asignado: victoria directa
		return
	if player == null or not is_instance_valid(player):
		player = _find_player()

	var boss = boss_scene.instantiate()
	var host := get_tree().current_scene
	if host == null:
		host = get_parent()
	host.add_child(boss)
	if player != null:
		boss.global_position = player.global_position + Vector2.RIGHT.rotated(randf() * TAU) * 480.0
	if boss.has_signal("died"):
		boss.died.connect(_on_boss_defeated)
	_boss = boss

	wave_active = false
	timer_label.text = ""
	_set_info("FINAL BOSS!")
	_play_music(_music_boss2)

func _on_boss_defeated() -> void:
	_boss = null
	_stop_all_music()
	_show_victory()

# =============================================================================
# PANTALLAS (inicio / victoria / muerte)
# =============================================================================
func _build_screens() -> void:
	# Inicio: solo el sprite Rectangulo con el texto JUGAR (UI antigua eliminada).
	_start_screen = _build_start_screen()
	# Victoria y muerte: caja del sprite UI_stat con el mensaje y un botón.
	_victory_screen = _build_message_screen("VICTORY!",
		"You cleared all the waves.", "Play again", _on_restart_pressed)
	_death_screen = _build_message_screen("YOU DIED",
		"You were defeated.", "Retry", _on_restart_pressed)

func _dim_screen() -> Control:
	"""Crea una pantalla a rejilla completa con un fondo oscuro translúcido."""
	var screen := Control.new()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.03, 0.05, 0.9)
	screen.add_child(bg)
	return screen

# Botón con el sprite Rectangulo_UI_Para_texto de fondo (marco de madera).
func _make_rect_button(text: String, size: Vector2, font_size: int, cb: Callable) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = size
	holder.size = size

	var np := NinePatchRect.new()
	np.set_anchors_preset(Control.PRESET_FULL_RECT)
	np.texture = RECT_TEX
	np.region_rect = RECT_REGION
	np.patch_margin_left = 8
	np.patch_margin_right = 8
	np.patch_margin_top = 7
	np.patch_margin_bottom = 7
	np.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(np)

	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.24, 0.15, 0.07))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(label)

	var btn := Button.new()
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.focus_mode = Control.FOCUS_NONE
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	btn.mouse_entered.connect(func(): holder.modulate = Color(1.12, 1.12, 1.12))
	btn.mouse_exited.connect(func(): holder.modulate = Color.WHITE)
	btn.pressed.connect(func(): Audio.play("ui_click"))   # clic genérico de UI
	btn.pressed.connect(cb)
	holder.add_child(btn)
	return holder

func _build_start_screen() -> Control:
	var screen := _dim_screen()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 30)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "SPINSHOT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.apply_title(title, 64)
	vbox.add_child(title)

	var play := _make_rect_button("PLAY", Vector2(260, 96), 30, _on_start_pressed)
	play.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(play)

	# Tutoriales interactivos (para jugadores nuevos).
	var tut := _make_rect_button("Tutorials", Vector2(260, 64), 22, _open_tutorials)
	tut.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(tut)

	# Configuración accesible ANTES de empezar la partida (mismas ventanas que ESC).
	var cfg := HBoxContainer.new()
	cfg.alignment = BoxContainer.ALIGNMENT_CENTER
	cfg.add_theme_constant_override("separation", 10)
	vbox.add_child(cfg)
	var opts := [
		["Resolution", _on_opt_resolution],
		["Language", _on_opt_language],
		["Controls", _on_opt_controls],
		["Sound", _on_opt_sound],
		["Credits", _on_opt_credits],
	]
	for o in opts:
		var b := _make_rect_button(o[0], Vector2(150, 48), 15, o[1])
		cfg.add_child(b)

	screen.visible = false
	ui.add_child(screen)
	return screen

func _build_message_screen(title_text: String, body_text: String, button_text: String, cb: Callable) -> Control:
	var screen := _dim_screen()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(center)

	# Caja del sprite UI_stat (400x400)
	var box := Control.new()
	box.custom_minimum_size = Vector2(400, 400)
	center.add_child(box)

	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.texture = UI_STAT_TEX
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)

	# Título en la placa superior del sprite
	var title := Label.new()
	title.position = Vector2(130, 54)
	title.size = Vector2(140, 46)
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.22, 0.13, 0.06))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	# Cuerpo del mensaje en el panel interior
	var body := Label.new()
	body.position = Vector2(86, 138)
	body.size = Vector2(228, 110)
	body.text = body_text
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 14)
	body.add_theme_color_override("font_color", Color(0.24, 0.15, 0.07))
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(body)

	# Botón en la parte baja del panel interior
	var button := _make_rect_button(button_text, Vector2(196, 66), 18, cb)
	button.position = Vector2(102, 270)
	box.add_child(button)

	screen.visible = false
	ui.add_child(screen)
	return screen

func _show_start() -> void:
	_set_screen(_start_screen)

func _show_victory() -> void:
	_set_screen(_victory_screen)

func _show_death() -> void:
	_set_screen(_death_screen)

func _set_screen(screen: Control) -> void:
	_start_screen.visible = screen == _start_screen
	_victory_screen.visible = screen == _victory_screen
	_death_screen.visible = screen == _death_screen
	_screen_active = true
	_set_gameplay_ui_visible(false)
	get_tree().paused = true

func _hide_screens() -> void:
	_start_screen.visible = false
	_victory_screen.visible = false
	_death_screen.visible = false
	_screen_active = false
	_set_gameplay_ui_visible(true)
	get_tree().paused = false

func _on_start_pressed() -> void:
	_hide_screens()
	_play_music(_music_base)
	if debug_mode:
		_set_info("DEV-ROOM:  M=wave N=end B=boss · 1-5 dummies · 6-9 variants/miniboss · O=shop C=+100 G=god")
	elif auto_start_waves:
		_start_wave()   # Main: las oleadas empiezan automáticamente
	else:
		_set_info("Press to start")

func _on_restart_pressed() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

func _on_player_died() -> void:
	tutorial_active = false   # corta cualquier secuencia de tutorial en curso
	_stop_all_music()
	_show_death()

# =============================================================================
# INVENTARIO (ESC o desde la tienda)
# =============================================================================
func _build_inventory() -> void:
	_inventory_panel = Control.new()
	_inventory_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_inventory_panel.visible = false

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	_inventory_panel.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_inventory_panel.add_child(center)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	center.add_child(row)

	# Panel de inventario con el sprite UI_Inventario_E (500x400)
	var inv := Control.new()
	inv.custom_minimum_size = Vector2(500, 400)
	row.add_child(inv)

	var inv_bg := TextureRect.new()
	inv_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	inv_bg.texture = UI_INVENTORY_TEX
	inv_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	inv_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	inv_bg.stretch_mode = TextureRect.STRETCH_SCALE
	inv_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inv.add_child(inv_bg)

	var inv_title := Label.new()
	inv_title.position = Vector2(185, 52)
	inv_title.size = Vector2(130, 40)
	inv_title.text = "Inventory"
	inv_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inv_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	inv_title.add_theme_font_size_override("font_size", 18)
	inv_title.add_theme_color_override("font_color", Color(0.25, 0.16, 0.08))
	inv_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inv.add_child(inv_title)

	_inventory_grid = GridContainer.new()
	_inventory_grid.position = Vector2(74, 120)
	_inventory_grid.size = Vector2(352, 230)
	_inventory_grid.columns = 4
	_inventory_grid.add_theme_constant_override("h_separation", 8)
	_inventory_grid.add_theme_constant_override("v_separation", 8)
	inv.add_child(_inventory_grid)

	# Estadísticas (sprite UI_stat) al lado
	_inv_stats_holder = Control.new()
	_inv_stats_holder.custom_minimum_size = Vector2(400, 400)
	row.add_child(_inv_stats_holder)

	ui.add_child(_inventory_panel)

# =============================================================================
# MENÚ DE OPCIONES (ESC) — sprite UI_ESC
# =============================================================================
func _build_options() -> void:
	_options_panel = Control.new()
	_options_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_options_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_options_panel.visible = false

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	_options_panel.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_options_panel.add_child(center)

	# VBox para que el cuadro ESC y el nuevo botón Exit queden centrados y alineados.
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	center.add_child(vb)

	var panel := Control.new()
	panel.custom_minimum_size = Vector2(400, 400)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(panel)

	var esc_bg := TextureRect.new()
	esc_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	esc_bg.texture = UI_ESC_TEX
	esc_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	esc_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	esc_bg.stretch_mode = TextureRect.STRETCH_SCALE
	esc_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(esc_bg)

	# 7 botones en el orden pedido (huecos del sprite UI_ESC)
	var col_l := 78.0
	var col_r := 220.0
	var w := 104.0
	var h := 38.0
	_make_esc_button(panel, Vector2(148, 62), Vector2(w, h), "SpinShot", func(): _on_opt_placeholder("SpinShot"))
	_make_esc_button(panel, Vector2(col_l, 148), Vector2(w, h), "Controls", _on_opt_controls)
	_make_esc_button(panel, Vector2(col_r, 148), Vector2(w, h), "Language", _on_opt_language)
	_make_esc_button(panel, Vector2(col_l, 202), Vector2(w, h), "Resolution", _on_opt_resolution)
	_make_esc_button(panel, Vector2(col_r, 202), Vector2(w, h), "Sound", _on_opt_sound)
	_make_esc_button(panel, Vector2(col_l, 256), Vector2(w, h), "Credits", _on_opt_credits)
	# El último hueco del sprite ahora es REANUDAR (cierra el menú y quita la pausa),
	# no salir del juego, para que no se confunda con cerrar la app.
	_make_esc_button(panel, Vector2(col_r, 256), Vector2(w, h), "Resume", _on_opt_resume)

	# Botón EXIT real: sprite Rectangulo_UI_Para_texto, centrado y alineado con el
	# cuadro ESC (gracias al VBox). Este SÍ cierra el juego.
	var exit_btn := _make_rect_button("Exit", Vector2(220, 64), 22, _on_opt_exit)
	exit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(exit_btn)

	# El panel ESC se añade ANTES que las cajas para que estas (hijas de 'ui')
	# se dibujen POR ENCIMA de él al abrirlas.
	ui.add_child(_options_panel)
	_build_controls_box()
	_build_resolution_box()
	_build_language_box()
	_build_sound_box()
	_build_credits_box()

func _make_esc_button(parent: Control, pos: Vector2, size: Vector2, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.position = pos
	b.size = size
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Color(0.22, 0.14, 0.07))
	b.add_theme_color_override("font_hover_color", Color(0.05, 0.03, 0.02))
	b.pressed.connect(func(): Audio.play("ui_click"))   # clic genérico de UI
	b.pressed.connect(cb)
	parent.add_child(b)

func _build_controls_box() -> void:
	_controls_box = Control.new()
	_controls_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_box.visible = false
	# Bajo 'ui' (no bajo el panel ESC) para poder abrirlo también desde el menú inicial.
	ui.add_child(_controls_box)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.5)
	_controls_box.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_box.add_child(center)

	# Caja del sprite UI_stat (400x400)
	var box := Control.new()
	box.custom_minimum_size = Vector2(400, 400)
	center.add_child(box)

	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.texture = UI_STAT_TEX
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)

	var title := Label.new()
	title.position = Vector2(130, 54)
	title.size = Vector2(140, 46)
	title.text = "CONTROLS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.22, 0.13, 0.06))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var body := Label.new()
	body.position = Vector2(84, 128)
	body.size = Vector2(232, 132)
	body.text = "WASD / Arrows: move\nSpace: dodge\nRight click: blue SpinShot\nLeft click: orange SpinShot\nE: inventory\nESC: options\nF11: fullscreen"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 12)
	body.add_theme_color_override("font_color", Color(0.24, 0.15, 0.07))
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(body)

	var back := _make_rect_button("Back", Vector2(170, 60), 16, func(): _controls_box.visible = false)
	back.position = Vector2(115, 274)
	box.add_child(back)

# Caja superpuesta (sprite UI_stat) con título; devuelve [overlay, box, vbox].
# El vbox interior sirve para apilar botones de opciones.
func _make_overlay_box(title_text: String) -> Array:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	# Bajo 'ui' para poder mostrarlo tanto desde el menú ESC como desde el inicio.
	ui.add_child(overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.5)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var box := Control.new()
	box.custom_minimum_size = Vector2(400, 400)
	center.add_child(box)

	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.texture = UI_STAT_TEX
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)

	var title := Label.new()
	title.position = Vector2(130, 54)
	title.size = Vector2(140, 46)
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.22, 0.13, 0.06))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(100, 118)
	vbox.size = Vector2(200, 224)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 6)
	box.add_child(vbox)

	return [overlay, box, vbox]

func _build_resolution_box() -> void:
	var parts := _make_overlay_box("RESOLUTION")
	_resolution_box = parts[0]
	var vbox: VBoxContainer = parts[2]

	var sizes := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080)]
	for s in sizes:
		var label := "%d x %d" % [s.x, s.y]
		var b := _make_rect_button(label, Vector2(196, 30), 13, _apply_resolution.bind(s))
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		vbox.add_child(b)

	var fs := _make_rect_button("Fullscreen", Vector2(196, 30), 13, _apply_fullscreen)
	fs.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(fs)

	var back := _make_rect_button("Back", Vector2(196, 30), 13, func(): _resolution_box.visible = false)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(back)

func _build_language_box() -> void:
	var parts := _make_overlay_box("LANGUAGE")
	_language_box = parts[0]
	var vbox: VBoxContainer = parts[2]

	var en := _make_rect_button("English", Vector2(196, 34), 15, func(): _set_language("en"))
	en.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(en)

	var es := _make_rect_button("Español", Vector2(196, 34), 15, func(): _set_language("es"))
	es.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(es)

	var back := _make_rect_button("Back", Vector2(196, 34), 15, func(): _language_box.visible = false)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(back)

func _build_sound_box() -> void:
	var parts := _make_overlay_box("SOUND")
	_sound_box = parts[0]
	var vbox: VBoxContainer = parts[2]
	vbox.add_theme_constant_override("separation", 10)

	# Un canal de música y otro de efectos: silenciar (interruptor) + volumen.
	_add_sound_channel(vbox, "Music", Audio.music_enabled, Audio.music_volume,
		func(on): Audio.set_music_enabled(on),
		func(v): Audio.set_music_volume(v))
	_add_sound_channel(vbox, "Sound effects", Audio.sfx_enabled, Audio.sfx_volume,
		func(on): Audio.set_sfx_enabled(on),
		func(v): Audio.set_sfx_volume(v))

	var back := _make_rect_button("Back", Vector2(196, 32), 14, func(): _sound_box.visible = false)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(back)

func _add_sound_channel(vbox: VBoxContainer, label_text: String, enabled: bool, volume: float, on_toggle: Callable, on_volume: Callable) -> void:
	# Interruptor de encendido/silencio (CheckButton, se auto-traduce).
	var check := CheckButton.new()
	check.text = label_text
	check.button_pressed = enabled
	check.focus_mode = Control.FOCUS_NONE
	check.add_theme_font_size_override("font_size", 14)
	check.add_theme_color_override("font_color", Color(0.22, 0.13, 0.06))
	check.add_theme_color_override("font_pressed_color", Color(0.22, 0.13, 0.06))
	check.add_theme_color_override("font_hover_color", Color(0.05, 0.03, 0.02))
	check.toggled.connect(func(p):
		Audio.play("ui_click")
		on_toggle.call(p))
	vbox.add_child(check)

	# Deslizador de volumen (0..1).
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = volume
	slider.custom_minimum_size = Vector2(196, 18)
	slider.value_changed.connect(func(v): on_volume.call(v))
	vbox.add_child(slider)

func _on_opt_sound() -> void:
	_sound_box.visible = true

# =============================================================================
# CRÉDITOS (ventana emergente con sprite de UI)
# =============================================================================
func _build_credits_box() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	ui.add_child(overlay)
	_credits_box = overlay

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	# Columna: panel de créditos + botón Volver (centrados).
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	# El marco usa un NinePatchRect (9-patch): nítido a CUALQUIER tamaño, así que
	# sirve para bloques de texto grandes sin deformar bordes (la UI de sprites
	# fija no estaba pensada para tanto texto).
	var box := Control.new()
	box.custom_minimum_size = Vector2(560, 520)
	col.add_child(box)

	var frame := NinePatchRect.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.texture = RECT_TEX
	frame.region_rect = RECT_REGION
	frame.patch_margin_left = 8
	frame.patch_margin_right = 8
	frame.patch_margin_top = 7
	frame.patch_margin_bottom = 7
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(frame)

	# Título centrado arriba.
	var title := Label.new()
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 22.0
	title.offset_bottom = 70.0
	title.text = "CREDITS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.98, 0.9, 0.72))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("shadow_offset_x", 1)
	title.add_theme_constant_override("shadow_offset_y", 1)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	# Texto desplazable, con MÁRGENES dentro del marco (se redimensiona con él).
	_credits_label = RichTextLabel.new()
	_credits_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_credits_label.offset_left = 44.0
	_credits_label.offset_top = 84.0
	_credits_label.offset_right = -44.0
	_credits_label.offset_bottom = -36.0
	_credits_label.bbcode_enabled = true
	_credits_label.scroll_active = true
	_credits_label.fit_content = false
	_credits_label.add_theme_color_override("default_color", Color(0.98, 0.92, 0.78))
	_credits_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_credits_label.add_theme_constant_override("shadow_offset_x", 1)
	_credits_label.add_theme_constant_override("shadow_offset_y", 1)
	_credits_label.add_theme_font_size_override("normal_font_size", 15)
	_credits_label.add_theme_font_size_override("bold_font_size", 17)
	_credits_label.text = _credits_text()
	box.add_child(_credits_label)

	var back := _make_rect_button("Back", Vector2(200, 56), 16, func(): _credits_box.visible = false)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(back)

func _on_opt_credits() -> void:
	if _credits_label != null:
		_credits_label.text = _credits_text()   # respeta el idioma actual
	_credits_box.visible = true

func _credits_text() -> String:
	# Texto bilingüe de créditos (nombres propios y títulos de assets sin traducir).
	if I18n.current() == "es":
		return "[center][b]Creadores[/b]\nSlimeForge y wym[/center]\n\n" \
			+ "[b]Assets y Créditos[/b]\n\n" \
			+ "[b]Arte y Gráficos[/b]\n" \
			+ "- Mapa \"Tiny Swords\" por Pixel Frog\n" \
			+ "- UI: Basic Pixel Health Bar and Scroll Bar por bdragon1727\n" \
			+ "- 500 Pixel Bullet 24x24 por bdragon1727\n" \
			+ "- 750 Effect and FX Pixel All por bdragon1727\n\n" \
			+ "[b]Efectos de Sonido[/b]\n" \
			+ "- Pixel Combat por Helton Yan\n" \
			+ "- Efectos de cartas por Beto Bezerra\n\n" \
			+ "[b]Código y Tutoriales[/b]\n" \
			+ "- Sistema de Boss - Tutorial por 16BitDev\n" \
			+ "- Sistema de Shop - Tutorial por 16BitDev\n" \
			+ "- Máquina de Estados - Tutorial por Godot!\n\n" \
			+ "[b]Música[/b]\n" \
			+ "- Música de fondo y ambiente por Pixabay (https://pixabay.com/es/music/)\n" \
			+ "- Khutulun (Fantasy & Battle) por Pixabay (https://pixabay.com/es/music/titulo-principal-khutulun-fantasy-amp-battle-background-music-115812/)\n" \
			+ "- To The Death por Pixabay (https://pixabay.com/es/music/video-juegos-to-the-death-159171/)\n\n" \
			+ "[b]Motor[/b]\nHecho con Godot Engine (godotengine.org)"
	return "[center][b]Creators[/b]\nSlimeForge and wym[/center]\n\n" \
		+ "[b]Assets and Credits[/b]\n\n" \
		+ "[b]Art and Graphics[/b]\n" \
		+ "- Map \"Tiny Swords\" by Pixel Frog\n" \
		+ "- UI: Basic Pixel Health Bar and Scroll Bar by bdragon1727\n" \
		+ "- 500 Pixel Bullet 24x24 by bdragon1727\n" \
		+ "- 750 Effect and FX Pixel All by bdragon1727\n\n" \
		+ "[b]Sound Effects[/b]\n" \
		+ "- Pixel Combat by Helton Yan\n" \
		+ "- Card effects by Beto Bezerra\n\n" \
		+ "[b]Code and Tutorials[/b]\n" \
		+ "- Boss System - Tutorial by 16BitDev\n" \
		+ "- Shop System - Tutorial by 16BitDev\n" \
		+ "- State Machine - Tutorial by Godot!\n\n" \
		+ "[b]Music[/b]\n" \
		+ "- Background and ambience music by Pixabay (https://pixabay.com/es/music/)\n" \
		+ "- Khutulun (Fantasy & Battle) by Pixabay (https://pixabay.com/es/music/titulo-principal-khutulun-fantasy-amp-battle-background-music-115812/)\n" \
		+ "- To The Death by Pixabay (https://pixabay.com/es/music/video-juegos-to-the-death-159171/)\n\n" \
		+ "[b]Engine[/b]\nMade with Godot Engine (godotengine.org)"

func _set_language(locale: String) -> void:
	I18n.set_language(locale)
	if _language_box != null:
		_language_box.visible = false

func _apply_resolution(size: Vector2i) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	# Centrar la ventana en la pantalla actual
	var screen := DisplayServer.window_get_current_screen()
	var sp := DisplayServer.screen_get_size(screen)
	var pos := DisplayServer.screen_get_position(screen) + (sp - size) / 2
	DisplayServer.window_set_position(pos)
	if _resolution_box != null:
		_resolution_box.visible = false

func _apply_fullscreen() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	if _resolution_box != null:
		_resolution_box.visible = false

func _on_opt_controls() -> void:
	_controls_box.visible = true

func _on_opt_resolution() -> void:
	_resolution_box.visible = true

func _on_opt_language() -> void:
	_language_box.visible = true

func _on_opt_exit() -> void:
	get_tree().quit()

func _on_opt_resume() -> void:
	# Cierra el menú de pausa y reanuda el juego (no cierra la aplicación).
	_set_options(false)

func _on_opt_placeholder(_name: String) -> void:
	# Botón interactivo, pendiente de implementación futura.
	pass

# =============================================================================
# ESTADO DE LOS OVERLAYS (inventario / opciones)
# =============================================================================
func _set_inventory(open: bool) -> void:
	if _screen_active:
		return
	if open:
		_options_open = false
		_options_panel.visible = false
		_refresh_inventory()
	_inventory_open = open
	_inventory_panel.visible = open
	_apply_overlay_state()

func _set_options(open: bool) -> void:
	if _screen_active:
		return
	if open:
		_inventory_open = false
		_inventory_panel.visible = false
	else:
		_controls_box.visible = false
		if _resolution_box != null:
			_resolution_box.visible = false
		if _language_box != null:
			_language_box.visible = false
		if _sound_box != null:
			_sound_box.visible = false
		if _credits_box != null:
			_credits_box.visible = false
	_options_open = open
	_options_panel.visible = open
	_apply_overlay_state()

func _apply_overlay_state() -> void:
	var any := _options_open or _inventory_open
	_set_gameplay_ui_visible(not any and not shop.visible)
	get_tree().paused = any

func _set_gameplay_ui_visible(v: bool) -> void:
	"""Muestra/oculta el HUD de la partida (vida, esquive, monedas, oleada,
	tiempo, info) para que no estorbe al abrir el inventario o una pantalla."""
	wave_title.visible = v
	wave_label.visible = v
	timer_label.visible = v
	info_label.visible = v
	if not v:
		announce_label.visible = false
	if player != null and is_instance_valid(player) and player.has_method("set_hud_visible"):
		player.set_hud_visible(v)

func _refresh_inventory() -> void:
	for c in _inventory_grid.get_children():
		c.queue_free()

	if player == null or not is_instance_valid(player):
		player = _find_player()

	# Reconstruir el panel de estadísticas
	if _inv_stats_holder != null:
		for c in _inv_stats_holder.get_children():
			c.queue_free()
		_inv_stats_holder.add_child(StatsPanel.build(player))
	var inv: Dictionary = {}
	if player != null:
		var v = player.get("inventory")
		if v is Dictionary:
			inv = v

	if inv.is_empty():
		var empty := Label.new()
		empty.text = "(You haven't bought any item yet)"
		UiTheme.apply_label(empty)
		_inventory_grid.add_child(empty)
		return

	for id in inv.keys():
		_inventory_grid.add_child(_make_inventory_slot(inv[id]))

func _make_inventory_slot(data: Dictionary) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(80, 80)
	UiTheme.apply_slot(slot)
	slot.tooltip_text = "%s\n\n%s\n\n%s" % [
		tr(String(data.get("name", ""))),
		tr(String(data.get("desc", ""))),
		tr("Qty/Level: %d") % int(data.get("count", 1)),
	]

	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 6.0
	icon.offset_top = 6.0
	icon.offset_right = -6.0
	icon.offset_bottom = -6.0
	icon.texture = data.get("icon", null)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)

	var count := Label.new()
	count.text = "x%d" % int(data.get("count", 1))
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -30.0
	count.offset_top = -24.0
	count.offset_right = -4.0
	count.offset_bottom = -2.0
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.add_theme_color_override("font_color", UiTheme.GOLD)
	count.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("shadow_offset_x", 1)
	count.add_theme_constant_override("shadow_offset_y", 1)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count)

	return slot

# =============================================================================
# UI
# =============================================================================
func _update_wave_label() -> void:
	# El título "Wave" (auto-traducido) va aparte, encima; aquí solo el contador.
	if wave_number == 0:
		wave_label.text = "-"
	else:
		wave_label.text = "%d / %d" % [wave_number, total_waves]

func _update_timer_label() -> void:
	timer_label.text = tr("Time: %d s") % ceili(maxf(time_left, 0.0))

# --- Texto contextual de info_label (se re-traduce al cambiar de idioma) ---
func _set_info(key: String, args: Array = []) -> void:
	_info_key = key
	_info_args = args
	_refresh_info()

func _clear_info() -> void:
	_info_key = ""
	_info_args = []
	info_label.text = ""

func _refresh_info() -> void:
	if _info_key == "":
		info_label.text = ""
	elif _info_args.is_empty():
		info_label.text = tr(_info_key)
	else:
		info_label.text = tr(_info_key) % _info_args

func _on_language_changed(_locale: String) -> void:
	# Refrescar los textos con formato (los estáticos se auto-traducen solos).
	_update_wave_label()
	if wave_active:
		_update_timer_label()
	_refresh_info()
	if _inventory_open:
		_refresh_inventory()
	if _credits_label != null:
		_credits_label.text = _credits_text()   # créditos en el nuevo idioma

# =============================================================================
# MÚSICA
# =============================================================================
func _play_music(player: AudioStreamPlayer) -> void:
	for p in [_music_base, _music_boss1, _music_boss2]:
		if p != player and p.playing:
			p.stop()
	if not player.playing:
		player.play()

func _stop_all_music() -> void:
	_music_base.stop()
	_music_boss1.stop()
	_music_boss2.stop()

# =============================================================================
# TUTORIALES — ventana de cartas, hooks y "Felicidades"
# =============================================================================
const COIN_ICON_TEX := preload("res://Items assets/COIN_SPRITE.png")
const _ENEMY_SHEETS := {
	"minion": preload("res://Sprites_Minions/Minion.png"),
	"big": preload("res://Sprites_Minions/BigMinion.png"),
	"bullet": preload("res://Sprites_Minions/Sprite_BulletMinion_var1.png"),
	"sad": preload("res://Sprites_Minions/Sprite_BulletMinion_var3.png"),
	"gotica": preload("res://Sprites_Minions/Sprite_BulletMinion_var2.png"),
	"support": preload("res://Sprites_Minions/SupportMinion.png"),
	"charger": preload("res://Sprites_Minions/ChargerMinion.png"),
}

func _tutorial_cards() -> Array:
	# nombre/desc en inglés (clave de traducción); coins = monedas al morir.
	return [
		{"id": "minion", "sheet": "minion", "name": "Green Slime", "desc": "Basic chaser. Practice moving, dodging and shooting.", "coins": 1},
		{"id": "big", "sheet": "big", "name": "Dark Slime", "desc": "Tougher and hits harder than a minion.", "coins": 3},
		{"id": "bullet", "sheet": "bullet", "name": "Sorcerer Slime", "desc": "Ranged attacker that keeps its distance.", "coins": 2},
		{"id": "sad", "sheet": "sad", "name": "Archmage Slime", "desc": "Eats your SpinShots and fires them back.", "coins": 3},
		{"id": "gotica", "sheet": "gotica", "name": "Punk Slime", "desc": "Teleports around and shoots.", "coins": 3},
		{"id": "support", "sheet": "support", "name": "Support Slime", "desc": "Buffs and heals nearby allies.", "coins": 3},
		{"id": "charger", "sheet": "charger", "name": "Orange Slime", "desc": "Winds up and charges, knocking things back.", "coins": 3},
	]

func _portrait(sheet_key: String) -> AtlasTexture:
	var a := AtlasTexture.new()
	a.atlas = _ENEMY_SHEETS[sheet_key]
	a.region = Rect2(0, 0, 64, 64)
	return a

func _open_tutorials() -> void:
	if _tutorial_box != null:
		_tutorial_box.visible = true

func _build_tutorial_box() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	ui.add_child(overlay)
	_tutorial_box = overlay

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)

	var title := Label.new()
	title.text = "TUTORIALS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.apply_title(title, 40)
	col.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(grid)
	for data in _tutorial_cards():
		grid.add_child(_make_tutorial_card(data))

	var back := _make_rect_button("Back", Vector2(200, 52), 16, func(): _tutorial_box.visible = false)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(back)

func _make_tutorial_card(data: Dictionary) -> Control:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(168, 196)
	UiTheme.apply_slot(card)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 8.0
	vb.offset_top = 8.0
	vb.offset_right = -8.0
	vb.offset_bottom = -8.0
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	var portrait := TextureRect.new()
	portrait.texture = _portrait(String(data["sheet"]))
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait.custom_minimum_size = Vector2(0, 64)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(portrait)

	var name_lbl := Label.new()
	name_lbl.text = String(data["name"])
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.add_theme_color_override("font_color", Color(0.98, 0.86, 0.55))
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = String(data["desc"])
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_lbl.add_theme_font_size_override("font_size", 11)
	desc_lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.custom_minimum_size = Vector2(0, 54)
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(desc_lbl)

	var coins_row := HBoxContainer.new()
	coins_row.alignment = BoxContainer.ALIGNMENT_CENTER
	coins_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(coins_row)
	var coin_icon := TextureRect.new()
	coin_icon.texture = COIN_ICON_TEX
	coin_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	coin_icon.custom_minimum_size = Vector2(20, 20)
	coin_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coins_row.add_child(coin_icon)
	var coin_lbl := Label.new()
	coin_lbl.text = "x%d" % int(data["coins"])
	coin_lbl.add_theme_color_override("font_color", UiTheme.GOLD)
	coin_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coins_row.add_child(coin_lbl)

	# Botón transparente que cubre la carta.
	var btn := Button.new()
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.focus_mode = Control.FOCUS_NONE
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	btn.mouse_entered.connect(func(): card.modulate = Color(1.15, 1.15, 1.15))
	btn.mouse_exited.connect(func(): card.modulate = Color.WHITE)
	var id := String(data["id"])
	btn.pressed.connect(func(): _start_tutorial(id))
	card.add_child(btn)
	return card

func _start_tutorial(id: String) -> void:
	Audio.play("ui_click")
	if _tutorial_box != null:
		_tutorial_box.visible = false
	if _congrats_box != null:
		_congrats_box.visible = false
	_hide_screens()                 # quita la pantalla de inicio y despausa
	_set_gameplay_ui_visible(true)
	Game.reset()
	wave_number = 0
	_update_wave_label()
	tutorial_active = true
	if player == null or not is_instance_valid(player):
		player = _find_player()
	_play_music(_music_base)
	_tutorial.run(id)

# --- Hooks usados por el TutorialController ---
func tut_announce(text: String) -> void:
	_show_announce(tr(text))

func tut_clear_announce() -> void:
	_hide_announce()

func tut_freeze(v: bool) -> void:
	if player != null and is_instance_valid(player) and player.has_method("set_frozen"):
		player.set_frozen(v)

func tut_lock_movement(v: bool) -> void:
	if player != null and is_instance_valid(player) and "movement_locked" in player:
		player.movement_locked = v

func tut_give_coins(n: int) -> void:
	Game.add_coins(n)

func tut_open_shop() -> void:
	_enter_shop()

func tut_player() -> Node2D:
	if player == null or not is_instance_valid(player):
		player = _find_player()
	return player

func tut_host() -> Node:
	return _spawn_host()

func tut_spawn(scene: PackedScene, pos: Vector2) -> Node:
	if scene == null:
		return null
	var e = scene.instantiate()
	_spawn_host().add_child(e)
	e.global_position = pos
	return e

func tut_point(angle: float, radius: float) -> Vector2:
	var origin: Vector2 = tut_player().global_position if tut_player() != null else Vector2(960, 576)
	var p := origin + Vector2(cos(angle), sin(angle)) * radius
	p.x = clampf(p.x, 90.0, 1830.0)
	p.y = clampf(p.y, 90.0, 1060.0)
	return p

func tut_grass_point() -> Vector2:
	if _ground == null or not is_instance_valid(_ground):
		_ground = _find_ground()
	if player == null or not is_instance_valid(player):
		player = _find_player()
	if player == null:
		return Vector2(960, 576)
	return _pick_grass_point_near_player()

func tut_enemies_alive() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(e) and not e.is_in_group("ally"):
			n += 1
	return n

func tut_clear_enemies() -> void:
	_clear_enemies()
	_clear_bullets()
	for b in get_tree().get_nodes_in_group("enemy_projectile"):
		if is_instance_valid(b):
			b.queue_free()

# --- Ventana de Felicidades ---
func show_congrats() -> void:
	tutorial_active = false
	tut_clear_announce()
	tut_clear_enemies()
	if player != null and is_instance_valid(player):
		if player.has_method("set_frozen"):
			player.set_frozen(true)
		if "movement_locked" in player:
			player.movement_locked = false
	if _congrats_box != null:
		_congrats_box.visible = true

func _build_congrats_box() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	ui.add_child(overlay)
	_congrats_box = overlay

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	center.add_child(col)

	var title := Label.new()
	title.text = "Congratulations!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiTheme.apply_title(title, 44)
	col.add_child(title)

	var b1 := _make_rect_button("More tutorials", Vector2(280, 60), 20, func():
		_congrats_box.visible = false
		_open_tutorials())
	b1.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(b1)

	var b2 := _make_rect_button("Normal game", Vector2(280, 60), 20, _on_congrats_normal)
	b2.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(b2)

	var b3 := _make_rect_button("Exit", Vector2(280, 60), 20, _on_opt_exit)
	b3.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(b3)

func _on_congrats_normal() -> void:
	if _congrats_box != null:
		_congrats_box.visible = false
	tutorial_active = false
	tut_clear_enemies()
	if player != null and is_instance_valid(player):
		if player.has_method("set_frozen"):
			player.set_frozen(false)
		if "movement_locked" in player:
			player.movement_locked = false
	Game.reset()
	wave_number = 0
	_update_wave_label()
	_play_music(_music_base)
	_start_wave()
