extends Node

# =============================================================================
# TUTORIAL CONTROLLER — Secuencias scripteadas por enemigo
# =============================================================================
# Conduce los tutoriales interactivos sobre la MISMA escena de juego (Main),
# usando los hooks públicos del GameMode (tut_*). Cada carta lanza run(id) y este
# nodo orquesta mensajes, apariciones, demos y la tienda. Al terminar pide al
# GameMode la ventana de "Felicidades".
#
# Se aísla aquí (no en game_mode.gd) para que los eventos del tutorial no se
# mezclen con el bucle normal de oleadas.

var gm: Node = null   # referencia al GameMode (lo asigna game_mode._ready)

func run(id: String) -> void:
	match id:
		"minion": await _t_minion()
		"big": await _t_big()
		"bullet": await _t_bullet()
		"sad": await _t_sad()
		"gotica": await _t_gotica()
		"support": await _t_support()
		"charger": await _t_charger()
		_: pass
	if not _aborted():
		gm.show_congrats()

# =============================================================================
# AYUDANTES
# =============================================================================
func _aborted() -> bool:
	return gm == null or not is_instance_valid(gm) or not gm.tutorial_active

func _wait(secs: float) -> void:
	await get_tree().create_timer(secs).timeout

func _big(text: String, secs: float = 2.5) -> void:
	# Mensaje grande centrado durante 'secs' (0 = permanente hasta el siguiente).
	if _aborted():
		return
	gm.tut_announce(text)
	if secs > 0.0:
		await _wait(secs)
		if not _aborted():
			gm.tut_clear_announce()

func _spawn_group(scene: PackedScene, count: int, spread: float = 90.0) -> Array:
	var out: Array = []
	if scene == null:
		return out
	var center: Vector2 = gm.tut_grass_point()
	for i in count:
		var off := Vector2(randf_range(-spread, spread), randf_range(-spread, spread))
		var e = gm.tut_spawn(scene, center + off)
		if e != null:
			out.append(e)
	return out

func _wait_cleared() -> void:
	# Espera a que no queden enemigos vivos (o a que se aborte el tutorial).
	await get_tree().process_frame
	while not _aborted() and gm.tut_enemies_alive() > 0:
		await _wait(0.2)

func _demo(e: Node) -> void:
	# Coloca a un enemigo como demostración: no daña y se queda quieto.
	if e == null or not is_instance_valid(e):
		return
	if e.has_method("make_passive"):
		e.make_passive()
	if "ai_frozen" in e:
		e.ai_frozen = true

# =============================================================================
# CARTA: SLIME VERDE (Minion)
# =============================================================================
func _t_minion() -> void:
	await _big("Move with WASD. Press SPACE to dodge!", 3.5)
	if _aborted(): return
	_spawn_group(gm.minion_scene, 3, 70.0)
	await _wait_cleared()
	if _aborted(): return
	await _big("Left click and right click to attack!", 3.5)
	if _aborted(): return
	# 4 grupos más, espaciados por varios segundos.
	for i in 4:
		if _aborted(): return
		_spawn_group(gm.minion_scene, randi_range(3, 5), 90.0)
		await _wait(4.0)
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME OSCURO (BigMinion)
# =============================================================================
func _t_big() -> void:
	await _big("Watch out: these ones are tougher and hit harder!", 3.5)
	if _aborted(): return
	_spawn_group(gm.bigminion_scene, 3, 90.0)
	await _wait_cleared()
	if _aborted(): return
	await _big("Here comes a bigger group!", 2.5)
	if _aborted(): return
	_spawn_group(gm.bigminion_scene, 6, 130.0)
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME HECHICERO (BulletMinion)
# =============================================================================
func _t_bullet() -> void:
	gm.tut_freeze(true)
	await _big("This one attacks from afar and keeps its distance. It's shy.", 3.0)
	if _aborted(): return
	var demo = gm.tut_spawn(gm.bulletminion_scene, gm.tut_point(0.0, 320.0))
	_demo(demo)
	await _wait(0.4)
	if demo != null and is_instance_valid(demo) and demo.has_method("demo_ability"):
		await demo.demo_ability()
	if _aborted(): return
	if is_instance_valid(demo):
		demo.queue_free()
	# Tienda con 50 monedas.
	gm.tut_give_coins(50)
	gm.tut_open_shop()
	await gm.shop.continue_pressed
	if _aborted(): return
	# Se devuelve el movimiento y aparecen 3 con IA normal.
	gm.tut_freeze(false)
	for i in 3:
		gm.tut_spawn(gm.bulletminion_scene, gm.tut_point(TAU * i / 3.0, 360.0))
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME ARCOMAGO (BulletMinionSad)
# =============================================================================
func _t_sad() -> void:
	gm.tut_lock_movement(true)   # no se mueve pero PUEDE disparar
	await _big("Shoot it! It will eat your SpinShots and fire them back.", 3.0)
	if _aborted(): return
	var demo = gm.tut_spawn(gm.sad_scene, gm.tut_point(0.0, 220.0))
	_demo(demo)
	if demo != null and is_instance_valid(demo) and demo.has_method("demo_ability"):
		await demo.demo_ability()
	if _aborted(): return
	if is_instance_valid(demo):
		demo.queue_free()
	gm.tut_lock_movement(false)
	gm.tut_give_coins(50)
	gm.tut_open_shop()
	await gm.shop.continue_pressed
	if _aborted(): return
	# 2 sads + algunos minions normales.
	gm.tut_spawn(gm.sad_scene, gm.tut_point(0.4, 360.0))
	gm.tut_spawn(gm.sad_scene, gm.tut_point(3.4, 360.0))
	_spawn_group(gm.minion_scene, 4, 90.0)
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME PUNK (BulletMinionGotica)
# =============================================================================
func _t_gotica() -> void:
	gm.tut_freeze(true)
	await _big("Watch how it teleports around the arena!", 3.0)
	if _aborted(): return
	var demo = gm.tut_spawn(gm.gotica_scene, gm.tut_point(0.0, 300.0))
	_demo(demo)
	if demo != null and is_instance_valid(demo) and demo.has_method("demo_ability"):
		await demo.demo_ability()
	if _aborted(): return
	if is_instance_valid(demo):
		demo.queue_free()
	# Movimiento devuelto y gótica con IA normal (teletransporte + disparos).
	gm.tut_freeze(false)
	await _big("Now fight it for real!", 2.0)
	if _aborted(): return
	gm.tut_spawn(gm.gotica_scene, gm.tut_point(0.0, 320.0))
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME DE SOPORTE (SupportMinion)
# =============================================================================
func _t_support() -> void:
	gm.tut_freeze(true)
	await _big("The Support buffs and heals its allies.", 2.5)
	if _aborted(): return
	# Maniquíes a los que potenciar + el soporte, todos quietos.
	var center: Vector2 = gm.tut_point(0.0, 280.0)
	var dummies: Array = []
	for i in 3:
		var d = gm.tut_spawn(gm.minion_scene, center + Vector2(60 * (i - 1), 40))
		_demo(d)
		dummies.append(d)
	var sup = gm.tut_spawn(gm.support_scene, center + Vector2(0, -60))
	_demo(sup)
	await _big("See the warm glow? Those minions are getting stronger.", 2.5)
	if _aborted(): return
	if sup != null and is_instance_valid(sup) and sup.has_method("demo_ability"):
		await sup.demo_ability()
	if _aborted(): return
	# Quitar maniquíes y el soporte de prueba.
	for d in dummies:
		if is_instance_valid(d): d.queue_free()
	if is_instance_valid(sup): sup.queue_free()
	gm.tut_freeze(false)
	await _big("Take it down before it powers up the others!", 2.0)
	if _aborted(): return
	gm.tut_spawn(gm.support_scene, gm.tut_point(0.0, 340.0))
	_spawn_group(gm.minion_scene, 5, 110.0)
	await _wait_cleared()

# =============================================================================
# CARTA: SLIME NARANJA (ChargerMinion)
# =============================================================================
func _t_charger() -> void:
	gm.tut_freeze(true)
	await _big("The Charger winds up, then dashes and knocks things back!", 3.0)
	if _aborted(): return
	# Pinos de boliche (minions en fila) y el cargador a un lado.
	var p: Vector2 = gm.tut_player().global_position if gm.tut_player() != null else Vector2(960, 576)
	var line_x := p.x + 120.0
	var pins: Array = []
	for i in 5:
		var d = gm.tut_spawn(gm.minion_scene, Vector2(line_x + i * 46.0, p.y - 120.0))
		_demo(d)
		pins.append(d)
	var ch = gm.tut_spawn(gm.charger_scene, Vector2(line_x - 220.0, p.y - 120.0))
	_demo(ch)
	await _wait(0.5)
	if ch != null and is_instance_valid(ch):
		if "demo_charge_dir" in ch:
			ch.demo_charge_dir = Vector2.RIGHT
		if ch.has_method("demo_ability"):
			await ch.demo_ability()
	if _aborted(): return
	await _wait(0.6)
	for d in pins:
		if is_instance_valid(d): d.queue_free()
	if is_instance_valid(ch): ch.queue_free()
	gm.tut_give_coins(50)
	gm.tut_open_shop()
	await gm.shop.continue_pressed
	if _aborted(): return
	gm.tut_freeze(false)
	_spawn_group(gm.minion_scene, 4, 100.0)
	gm.tut_spawn(gm.charger_scene, gm.tut_point(0.0, 380.0))
	await _wait_cleared()
