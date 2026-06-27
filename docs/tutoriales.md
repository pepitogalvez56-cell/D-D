# Tutoriales interactivos

Sistema para enseñar cada enemigo a jugadores nuevos. Se accede desde el botón
**Tutorials** del menú inicial.

## Arquitectura (por qué NO son escenas nuevas)

Los tutoriales corren sobre la **misma escena de juego (`Main`)**: necesitan el
jugador completo (mover/disparar/esquivar), la IA real de los enemigos, la tienda
y el HUD. Duplicar todo eso en escenas aparte sería clonar medio juego. En su
lugar, un controlador (`Scripts/tutorial.gd`, nodo hijo del `GameMode`) **scripta
los eventos** sobre la escena viva usando hooks públicos del `GameMode`. Así los
eventos del tutorial quedan aislados del bucle normal de oleadas.

- `game_mode.tutorial_active`: cuando es `true`, el bucle de oleadas (`_process`)
  no corre y la tienda al cerrarse no encadena oleadas; manda el controlador.
- `TutorialController.run(id)`: corutina que ejecuta la secuencia del enemigo y,
  al terminar, llama a `gm.show_congrats()`.

## Flujo de UI

1. **Menú inicial** → botón `Tutorials` (`_open_tutorials`) abre la ventana de
   cartas (`_build_tutorial_box`).
2. Cada **carta** (`_make_tutorial_card`) muestra: retrato del enemigo (primer
   fotograma de su hoja, `_portrait`), nombre, descripción corta y las monedas
   que suelta. Clic → `_start_tutorial(id)`.
3. Al acabar el tutorial → ventana **"Felicidades"** (`_build_congrats_box`) con
   3 botones: **Más tutoriales** (reabre las cartas), **Juego normal**
   (`_on_congrats_normal` arranca la partida real) y **Salir**.

## Hooks del GameMode usados por el controlador

`tut_announce` / `tut_clear_announce` (mensaje grande centrado, traducido),
`tut_freeze(v)` (inmoviliza y bloquea disparo, para la tienda/observar),
`tut_lock_movement(v)` (inmoviliza pero DEJA disparar — `billy.movement_locked`),
`tut_give_coins(n)`, `tut_open_shop()` (+ `await gm.shop.continue_pressed`),
`tut_spawn(scene, pos)`, `tut_point(angle, radius)`, `tut_grass_point()`,
`tut_enemies_alive()`, `tut_clear_enemies()`, `show_congrats()`.

## Demos de cada enemigo

Para las fases "quieto mostrando su habilidad", el controlador hace
`make_passive()` + `ai_frozen = true` (en `enemy.gd`: se queda quieto, sin IA,
pero sigue recibiendo empujes) y llama a **`demo_ability()`**, una corutina que
cada especial implementa para ejecutar su mecánica una vez sin moverse:

| Enemigo | `demo_ability()` |
|---------|------------------|
| BulletMinion | telegrafía y dispara teledirigido varias veces + anillo |
| BulletMinionSad | se come las SpinShots del jugador unos segundos y suelta su anillo |
| BulletMinionGotica | solo teletransportes (humo + reaparición), sin disparar |
| SupportMinion | potencia/cura a los maniquíes cercanos (aura visible) |
| ChargerMinion | telegrafía y embiste en `demo_charge_dir` empujando los "pinos" (usa `_demo_velocity`) |

## Secuencias (resumen)

- **Slime Verde (Minion):** mensaje de esquive → grupo pequeño → mensaje de
  ataque → 4 grupos más espaciados → Felicidades.
- **Slime Oscuro (BigMinion):** aviso "más fuertes" → grupo → grupo mayor.
- **Slime Hechicero (BulletMinion):** jugador congelado, demo de ataque a
  distancia, tienda (+50), luego 3 con IA normal.
- **Slime Arcomago (Sad):** jugador inmóvil pero puede disparar, demo de comer
  SpinShots, tienda (+50), luego 2 Sads + minions.
- **Slime Punk (Gótica):** jugador congelado, demo de teletransporte, luego
  gótica con IA normal.
- **Slime de Soporte (Support):** jugador congelado, soporte + maniquíes, demo de
  buff, mensajes, luego soporte + minions reales.
- **Slime Naranja (Charger):** jugador congelado, pinos de boliche + embestida
  demo, tienda (+50), luego minions + 1 Cargador.

Si el jugador muere en un tutorial, `_on_player_died` pone `tutorial_active=false`
(corta la secuencia) y muestra la pantalla de muerte.

## Añadir / ajustar un tutorial

1. Añade una entrada a `_tutorial_cards()` en `game_mode.gd` (id, sheet, name,
   desc, coins) y su traducción en `i18n.gd`.
2. Añade `func _t_<id>()` en `tutorial.gd` y su rama en `run()`.
3. Si el enemigo necesita una demo, implementa `demo_ability()` en su script.
