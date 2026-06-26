# Sistema de oleadas

El bucle de oleadas vive en `Scripts/game_mode.gd` (escena reutilizable
`Scenes/GameMode.tscn`, instanciada en `Main` y `DEV-ROOM`).

## Mapa (compartido por Main y DEV-ROOM)

Ambas escenas usan la misma base de mapa, construida por `Scripts/floor_builder.gd`:

- Campo de **césped** de `30×18` tiles de 64 px (1920×1152 px), ~25% más pequeño
  que el anterior.
- **Borde de piedra** (`TILE_STONE`, anillo de `stone_border` tiles) que delimita
  visualmente el área jugable.
- **Muros** (`StaticBody2D`) en el límite del césped para que el jugador no salga.
- El exterior se cubre con **nubes** (`Scripts/cloud_border.gd`, assets
  *Terrain/Decorations/Clouds*) más un cielo de fondo, para que no se vea el
  fondo por defecto de Godot.

> Los enemigos **solo aparecen sobre césped** (no sobre la piedra ni fuera del
> mapa): `_is_grass_cell()` comprueba que la celda es del bloque de césped.

### Contraste del fondo (por código, sin editar assets)

Para que el jugador, los enemigos y la UI **resalten** sobre el suelo, el
`floor_builder` aplica por código un `ShaderMaterial`
(`Shaders/ground_tint.gdshader`) al `Ground` que **oscurece y desatura** el
césped/piedra, y atenúa el `CloudBorder` con `modulate`. Es barato (un material
en GPU), respeta el pixel art y se ajusta con los `@export` del nodo raíz:
`ground_darken`, `ground_desaturation`, `ground_tint` y `dim_clouds`.

## Cómo funciona

1. El jugador pulsa **N** (`start_wave`) para iniciar una oleada.
2. La oleada dura `wave_duration` segundos (60 por defecto), con cuenta atrás
   en pantalla. También se puede terminar antes con **M** (`end_wave`).
3. Mientras la oleada está activa, cada cierto tiempo aparece un **grupo** de
   enemigos a `spawn_radius` píxeles alrededor del jugador. Los grupos pueden ser
   **pequeños** (`small_group_min`–`small_group_max`) o **grandes**
   (`large_group_min`–`large_group_max`, con probabilidad `large_group_chance`).
   Antes de cada grupo, durante `spawn_warning_time` segundos, se muestra un
   **indicador rojo animado** en el punto exacto donde aparecerá cada enemigo
   (sprite `Spritesheet_UI_Flat_Animated`, escena `Scenes/SpawnIndicator.tscn`,
   teñido de rojo por código). El tiempo entre grupos es
   `_group_interval()` = `interval` × 3 + `spawn_warning_time`.
   - **Todos los puntos de aparición se validan sobre el TileMap de césped**
     (`Ground`): `_is_on_grass()` comprueba que la celda tiene tile. Si el
     jugador está en un borde/esquina, `_pick_grass_point_near_player()` prueba
     varios ángulos y reduce el radio hasta hallar césped, y como último recurso
     `_random_grass_point_far()` elige una celda de césped lejana. Así los
     enemigos nunca aparecen fuera del mapa.
4. Al terminar la oleada se limpian los enemigos restantes y:
   - si quedan oleadas, se abre la **tienda** y al continuar empieza la siguiente;
   - si era la **última** oleada (`total_waves`, por defecto **10**), aparece el **jefe**.
5. Al derrotar al jefe se muestra la pantalla de **victoria**.

Variables principales (exportadas en el nodo `GameMode`):

| Variable | Significado |
|----------|-------------|
| `total_waves` | Número de oleadas antes del jefe (10). |
| `wave_duration` | Duración de cada oleada en segundos. |
| `spawn_radius` | Distancia a la que aparecen los enemigos. |
| `spawn_warning_time` | Segundos que se muestra el indicador rojo antes del grupo. |
| `large_group_chance` | Probabilidad de que un grupo sea grande. |
| `small_group_min` / `small_group_max` | Tamaño de los grupos pequeños. |
| `large_group_min` / `large_group_max` | Tamaño de los grupos grandes. |
| `minion_scene`, `bigminion_scene`, `bulletminion_scene`, `charger_scene`, `support_scene` | Escenas de cada tipo de enemigo. |
| `boss_scene` | Escena del jefe final. |

## Cómo se decide qué enemigos aparecen

La composición de cada oleada está en la función `_build_waves()` como una
**tabla de datos**. Cada entrada del array `_waves` (índice 0 = oleada 1) es un
diccionario:

```gdscript
{"interval": 0.9, "pool": [[minion_scene, 2], [charger_scene, 2], [support_scene, 1]]}
```

- `interval`: segundos entre apariciones en esa oleada (menor = más enemigos).
- `pool`: lista de pares `[escena, peso]`. Al aparecer un enemigo se elige una
  escena al azar **ponderada por su peso** (`_pick_enemy_scene()`).
  En el ejemplo: 40% minion, 40% charger, 20% support.

Las entradas con escena `null` (un tipo sin asignar) se ignoran automáticamente,
así que el juego no falla si falta una escena.

Composición actual (resumen):

Cada tipo se **introduce de forma progresiva** (una vez que aparece, se mantiene
en las oleadas siguientes):

| Oleada | Enemigos (pesos) | Novedad |
|-------:|------------------|---------|
| 1 | Minion ×1 | — |
| 2 | Minion ×5, BigMinion ×1 | +BigMinion (sin Cargador) |
| 3 | Minion ×5, BigMinion ×1, BulletMinion ×1 | +BulletMinion |
| 4 | Minion ×5, BigMinion ×1, BulletMinion ×1, Apoyo ×1 | +Apoyo |
| 5 | Minion ×5, BigMinion ×2, BulletMinion ×1, Apoyo ×1, Cargador ×1 | +Cargador (peso bajo: pocos a la vez) |
| 6 | Minion ×4, BigMinion ×2, BulletMinion ×1, Apoyo ×1, Cargador ×1, Sad ×1, Gótica ×1 | +variantes de BulletMinion (Sad/Gótica) |
| 7 | … + Bigminion_capitan ×1 (repertorio completo) | +Capitán |
| 8 | Mismo repertorio que la 7 (Cargador ×2) | sin enemigo nuevo, más intenso |
| 9 | Mismo repertorio (BigMinion ×3, BulletMinion ×2, Capitán ×2) | sin enemigo nuevo, más intenso |
| 10 | **Minijefe** (Bigminion_gran_capitan) + refuerzos (grupos pequeños espaciados) → luego **Jefe** | oleada sin temporizador |

> **En todas las oleadas aparecen Minions + el resto del repertorio acumulado**
> (la única excepción es la oleada 1, solo Minions, y la 10, que es el minijefe).
> Las oleadas marcadas "sin enemigo nuevo" (8 y 9) **no introducen un tipo
> nuevo**: repiten el repertorio de la oleada 7 con más cantidad/intensidad.
>
> El **Minion** lleva un peso alto en cada oleada para que sea el enemigo más
> frecuente, **sin reducir** el peso de los demás tipos (solo cambia su
> proporción relativa).

> El **Cargador** se introduce tarde (oleada 5) y con **peso bajo** para que solo
> aparezcan unos pocos a la vez: antes saturaba la oleada 2 y la hacía
> injusta. La **oleada 10** invoca al minijefe (su `pool` no se usa).

## Cómo modificar o agregar oleadas

1. **Cambiar la composición** de una oleada: edita su entrada en `_build_waves()`
   (pesos, tipos, `interval`).
2. **Añadir más oleadas**: agrega más diccionarios al array `_waves` y sube
   `total_waves` al nuevo total. Si `wave_number` supera el tamaño de `_waves`,
   se reutiliza la última entrada (clamp), así que conviene que coincidan.
3. **Añadir un tipo de enemigo nuevo a las oleadas**:
   - Crea su escena (ver un enemigo existente como plantilla, p. ej.
     `Scenes/ChargerMinion.tscn`).
   - Añade un `@export var nuevo_scene: PackedScene` en `game_mode.gd`.
   - Asígnalo en `Scenes/GameMode.tscn`.
   - Úsalo dentro de los `pool` de `_build_waves()`.

> Nota: los enemigos deben estar en el grupo `"enemy"` (lo hace `enemy.gd` en
> `_ready`) para que las Spin-Bullets los dañen y el sistema los limpie.

## Enemigo de Apoyo (`Scripts/support_minion.gd`)

No ataca al jugador; potencia a los aliados dentro de `heal_radius`:

- **Movimiento (independiente del jugador):** busca el **grupo de enemigos más
  denso** (`_best_cluster()` = centroide del enemigo con más vecinos en
  `heal_radius`) y se mantiene **dentro** de él (a `heal_radius * 0.45`) para
  curar/potenciar, sin importar si el jugador está cerca o lejos. Navega con
  `_avoid_bounds()` para no quedarse pegado a las paredes. Si no hay otros
  enemigos, frena en el sitio.
- **Curación** periódica (`heal_amount` cada `heal_interval`).
- **Aura de daño**: otorga `+damage_buff` al daño por contacto de los aliados en
  rango. Se **refresca cada frame** mientras estén dentro del radio y **caduca**
  (~0.3 s) al salir, así el efecto solo dura mientras el enemigo esté en el área
  de influencia (`enemy.apply_damage_buff` / decaimiento en `enemy._physics_process`).
  Los enemigos potenciados muestran un tinte cálido.
