# Exportar una build de Windows (para beta testers) desde Linux

Guía para generar el `.exe` del juego desde **Linux (CachyOS)**, arrancando en
la escena **Main** y protegiendo el código todo lo posible.

> Versión del proyecto: **Godot 4.6 stable**. Las plantillas de exportación
> deben ser **exactamente** de esa versión.

---

## 0. Requisitos

- **Godot 4.6 stable** (el editor con el que abres el proyecto).
- **Export Templates 4.6.stable** (incluyen la plantilla de Windows ya
  compilada → **NO necesitas mingw ni compilar nada** para una build normal).
- *(Opcional)* `rcedit` + `wine` solo si quieres ponerle **icono/metadatos** al
  `.exe`. La build funciona sin ello (solo saldrá un aviso).
- Compilar plantillas desde código (scons + mingw-w64) **solo** si quieres
  **cifrar el .pck** (ver §5, "máxima protección").

### Instalar las Export Templates (lo más fácil)

En el editor: **Editor → Manage Export Templates… → Download and Install**.
Descarga la versión que coincida con el editor (4.6.stable) y las deja en:

- Instalación normal: `~/.local/share/godot/export_templates/4.6.stable/`
- Flatpak: `~/.var/app/org.godotengine.Godot/data/godot/export_templates/4.6.stable/`

(Alternativa offline: descarga `Godot_v4.6-stable_export_templates.tpz` de la web
oficial e instálalo con **Install from File…**.)

---

## 1. Asegurar que arranca en la escena Main

Ya está configurado en el repo: `project.godot` →
`run/main_scene="uid://ckhnygos5ovi6"` (que es `res://Scenes/Main.tscn`).

> ⚠️ Antes apuntaba a un UID obsoleto que solo resolvía por la caché local
> (`.godot/`, ignorada por git); en un clon limpio o en CI la build no
> encontraba la escena. Ya está corregido. Verifícalo en el editor:
> **Project → Project Settings → Application → Run → Main Scene** debe ser
> `res://Scenes/Main.tscn`.

`Main.tscn` es la partida real (suelo, jugador, GameMode con la pantalla de
inicio). **No** uses `DEV-ROOM.tscn` como main (es la sala de pruebas).

---

## 2. Crear el preset de exportación de Windows

**Project → Export… → Add… → Windows Desktop.**

Ajustes recomendados en ese preset:

- **Runnable:** activado.
- **Export Path:** `build/spinshot.exe` (crea la carpeta `build/`).
- **Resources → Export Mode:** `Export all resources in the project`.
- **Resources → Filters to exclude files/folders from project:**
  ```
  docs/*, *.md, Scenes/DEV-ROOM.tscn, mecanicas de jefe/*.txt
  ```
  (No queremos enviar documentación, la sala de pruebas ni notas de diseño.)
- **Options → Binary Format → Embed Pck:** **activado** → genera **un único
  `.exe`** con todo dentro (los testers no ven un `.pck` suelto ni carpetas).
- **Options → Binary Format → Architecture:** `x86_64`.

---

## 3. Protección del código (lo importante)

Hay tres niveles. Para beta testers suele bastar con el **nivel 2**; el cifrado
real (nivel 3) requiere compilar plantillas.

### Nivel 1 — Por defecto (siempre): empaquetado binario
Al exportar, el juego se entrega como `.exe` (con el `.pck` embebido). Los testers
**no ven** tu árbol de carpetas ni tus `.gd`/`.tscn` como archivos sueltos.
> Aviso honesto: un `.pck`/`.exe` se puede **abrir con herramientas** (p. ej.
> gdsdecomp) y recuperar recursos. Por eso conviene el nivel 2 o 3.

### Nivel 2 — GDScript como *binary tokens* (fácil, sin compilar) ✅ recomendado
En el preset: **Script → Export Mode → `Compressed binary tokens`** (o
`Binary tokens`). Así tus `.gd` **no viajan como texto legible** (sin comentarios
ni nombres de fuente claros), sino tokenizados. En `export_presets.cfg` es
`script_export_mode=2`.
> No es indescifrable (existen decompiladores), pero elimina el código fuente en
> claro y es suficiente para un beta cerrado.

### Nivel 3 — Cifrado del .pck (máxima protección, requiere compilar plantillas)
Las plantillas **oficiales no pueden descifrar** un `.pck` cifrado: hay que
**compilarlas desde código** con tu clave. Pasos (en Linux):

1. Genera una clave AES-256 (64 caracteres hex):
   ```bash
   openssl rand -hex 32
   ```
2. Exporta la clave y compila las plantillas de Windows (necesitas `scons` y
   `mingw-w64`):
   ```bash
   export SCRIPT_AES256_ENCRYPTION_KEY="<tu_clave_de_64_hex>"
   # en el repo del código fuente de Godot 4.6:
   scons platform=windows target=template_release arch=x86_64 use_mingw=yes
   scons platform=windows target=template_debug   arch=x86_64 use_mingw=yes
   ```
3. En el preset → **Options → Custom Template → Release/Debug:** apunta a los
   `.exe` recién compilados (`bin/godot.windows.template_release.x86_64.exe`, etc.).
4. En el preset → pestaña **Encryption:** pon la **misma clave** y los filtros de
   lo que se cifra, p. ej.:
   ```
   Include: *.gd, *.tscn, *.tres, *.scn, *.res
   ```
   Activa **Encrypt PCK** (y opcionalmente Encrypt Index).
> No subas la clave al repositorio. Guárdala aparte.

---

## 4. Exportar

### Desde el editor
**Project → Export… → (selecciona el preset) → Export Project…** → guarda como
`build/spinshot.exe`. Desmarca "Export With Debug" para la build de testers
(release).

### Desde la terminal (headless, una vez creado el preset)
```bash
mkdir -p build
godot --headless --export-release "Windows Desktop" build/spinshot.exe
```
(Usa `--export-debug` si quieres la consola de depuración.)

---

## 5. Entregar a los testers

- Comprime la carpeta `build/` en un `.zip` (si embebiste el PCK, basta el
  `.exe`; si no, incluye también el `.pck` junto al `.exe`).
- Windows SmartScreen puede avisar de "editor desconocido" (normal en builds sin
  firmar): los testers pulsan **Más información → Ejecutar de todas formas**.
- Prueba el `.exe` tú mismo (en Windows o con `wine build/spinshot.exe`) antes de
  enviarlo, y confirma que **arranca en la pantalla de inicio de Main**.

---

## Solución de problemas

### El `.exe` se cierra al arrancar / "page fault on read access to 0" (Wine o Windows)
Casi siempre es el **renderizador/driver gráfico**, no el juego (corre bien en
headless). El proyecto estaba en **Forward+** y forzaba el driver **D3D12** en
Windows (`rendering_device/driver.windows="d3d12"`), que bajo **Wine** (vkd3d)
suele provocar un *segfault* al iniciar, y en Windows real exige GPU/driver más
nuevos.

**Solución aplicada:** se cambió el renderizador a **Compatibility (OpenGL3)**
(`renderer/rendering_method="gl_compatibility"`) y se quitó el driver D3D12. Es
lo ideal para un juego 2D: mínimos requisitos y máxima compatibilidad (Wine, GPUs
viejas, etc.). **Vuelve a exportar** tras este cambio.

> Si por algún motivo quisieras volver a Forward+/Vulkan, hazlo solo si tus
> testers tienen GPU/drivers recientes; para un beta amplio, Compatibility es más
> seguro.

### Otras comprobaciones
- **Plantillas = versión del editor:** el editor y las Export Templates deben ser
  la MISMA versión (la build reporta `v4.6.3.stable`; usa plantillas 4.6.3).
- **Probar en Windows real:** Wine es buena referencia pero no idéntica; si algo
  falla solo en Wine, prueba en una máquina Windows antes de descartar.
- **Ejecutar desde terminal** para ver el log:
  `wine build/spinshot.exe` (o `spinshot.console.exe` si activaste el wrapper de
  consola en el preset).

## Resumen rápido

| Objetivo | Qué hacer |
|----------|-----------|
| Arranca en Main | Ya fijado (`run/main_scene` → `Main.tscn`). |
| Un solo archivo | `Embed Pck = ON` → un `.exe`. |
| Ocultar código (fácil) | Script Export Mode = *Compressed binary tokens*. |
| Cifrado real del .pck | Compilar plantillas con `SCRIPT_AES256_ENCRYPTION_KEY` + pestaña Encryption. |
| Exportar Windows desde Linux | Plantillas oficiales 4.6.stable (sin mingw para build normal). |
| No enviar de más | Excluir `docs/*`, `*.md`, `DEV-ROOM.tscn`, `*.txt`. |

---

# Exportar para navegador (HTML5) y publicar en itch.io

El juego ya usa el renderizador **Compatibility (OpenGL3)**, que es justo el que
funciona en web (WebGL2). Forward+/Vulkan NO funciona en navegador, así que no
hay que cambiar nada del render.

## 1. Plantillas

Necesitas las **Export Templates de la MISMA versión** (4.6.stable) instaladas
(Editor → Manage Export Templates). Incluyen la plantilla de Web; no hay que
compilar nada.

## 2. Crear el preset Web

**Project → Export… → Add… → Web.**

- **Export Path:** `build/web/index.html` (el archivo principal DEBE llamarse
  `index.html`; itch.io lo busca por ese nombre).
- Deja las opciones por defecto. Godot generará varios archivos:
  `index.html`, `index.js`, `index.wasm`, `index.pck`, `index.audio.worklet.js`,
  `index.icon.png`, etc. **Todos** deben ir juntos.
- Para ocultar el código aplica lo mismo que en escritorio: **Script → Export
  Mode → `Compressed binary tokens`** (el cifrado de PCK no aplica al export web
  estándar).

## 3. Exportar

Editor: **Export Project…** a `build/web/index.html` (desmarca "Export With
Debug" para la versión de jugadores).

Terminal (tras crear el preset):

```bash
mkdir -p build/web
godot --headless --export-release "Web" build/web/index.html
```

## 4. Empaquetar para itch.io

Comprime **el contenido** de `build/web/` en un `.zip` con `index.html` en la
**raíz** del zip (no dentro de una subcarpeta):

```bash
cd build/web && zip -r ../spinshot_web.zip . && cd -
```

## 5. Subir y configurar en itch.io

1. En tu página del juego: **Edit game → Uploads → Upload files**, sube
   `spinshot_web.zip`.
2. Marca **"This file will be played in the browser"**.
3. **Embed options:**
   - **Viewport dimensions:** `1280 x 720` (la base del proyecto). Marca
     "Mobile friendly" si quieres.
   - Marca **"Fullscreen button"** y **"Enable scrollbars"** off.
   - **MUY IMPORTANTE:** marca **"SharedArrayBuffer support"**. Godot 4 usa hilos
     en web y los necesita (itch añade las cabeceras COOP/COEP). Sin esto, el
     juego se queda en negro o no carga.
4. **Kind of project:** HTML. Guarda y prueba con "View page" → el juego corre en
   el navegador.

## Solución de problemas (web)

- **Pantalla negra / "SharedArrayBuffer is not defined":** falta marcar
  "SharedArrayBuffer support" en itch (paso 5.3).
- **No carga / 404:** el `index.html` no estaba en la raíz del zip, o renombraste
  los archivos. Mantén todos los `index.*` juntos y con sus nombres.
- **Audio que no suena hasta hacer clic:** los navegadores bloquean el audio
  hasta la primera interacción del usuario; es normal, suena al pulsar PLAY.
- **Va lento:** ya estás en Compatibility (lo correcto para web). Baja la
  resolución del viewport en itch si hace falta.
