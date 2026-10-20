# Estado Técnico del Port de Switch

Documento de referencia para entender cómo está montado el port, qué librerías usa frente a las oficiales, qué partes del juego oficial no funcionan igual en Switch y qué queda pendiente. Se revisa en cada actualización de V-Slice. Los cambios de contenido de cada versión oficial están en [`SWITCH_UPSTREAM_CHANGES.md`](SWITCH_UPSTREAM_CHANGES.md); el día a día (builds, incidencias, bitácora) sigue en [`SWITCH_PORT_TRACKER.md`](SWITCH_PORT_TRACKER.md).

Última revisión: 2026-10-20, rama `nx-develop` (Build 41, V-Slice 0.8.7).

---

## 1. Cómo está montado el port (capas)

| Capa | Dónde | Qué contiene | Cómo se actualiza |
| :--- | :--- | :--- | :--- |
| Juego oficial | `source/funkin/`, `assets/` (submódulo oficial), `project.hxp` | Código de FunkinCrew sin cambios, salvo los enganches de Switch | `git merge vX.Y.Z` de `upstream` |
| Código propio de Switch | `source/nx/` | Driver de audio, reproductor de vídeo con FFmpeg, relojes, memoria, telemetría, pruebas automáticas, menús de Switch | No lo toca la fusión |
| Parches de compilación | `source/nx/macro/` (`NXLibraryPatches`, etc.) | Cambios a lime y OpenFL aplicados al compilar, sin editar la librería; la compilación falla si el código original cambia | Se revisan si la compilación falla |
| Forks de librerías | `hmm.json` (commits fijados) | lime-nx (SDL2), openfl, flixel, hxcpp, hx_libnx | Rebase de los cambios de Switch sobre los pines nuevos (sección 3) |
| Herramientas | `tools/nx-tools/` | Compilación de FFmpeg, despliegue, Citron, preparación de cinemáticas, sincronización de librerías | No lo toca la fusión |
| Documentación | `docs/SWITCH_*.md` | Tracker, guía de sesión, este documento, cambios de versiones | — |

### Aislamiento (contra la etiqueta oficial `v0.8.7`)

Regla: en PC, móvil y web el juego tiene que compilar **exactamente** como el oficial. Todo cambio de Switch en un archivo del juego va dentro de `#if switch` (con `#else` + el código original cuando sustituye algo), y la lógica larga vive en `source/nx/`.

**Estado (2026-10-20, Build 41): fase 1 hecha.**

| | Antes (Build 40) | Ahora (Build 41) |
| :--- | :--- | :--- |
| Archivos del juego que también cambiaban otras plataformas | 31 | **0** |
| Líneas oficiales quitadas o cambiadas | 232 | 42 (solo condiciones ampliadas, p. ej. `#if mobile` → `#if (mobile \|\| switch)`) |
| Archivos fuera de las carpetas propias tocados | 53 | 51 (se borraron una clase sin uso y un plugin que solo se registraba fuera de Switch) |

Cómo se comprueba (`tools/nx-tools/check_switch_isolation.py`):

- `python3 tools/nx-tools/check_switch_isolation.py`: resuelve el preprocesador como una build que no es de Switch (`switch` y los defines `NX_`/`nx_` falsos, el resto sin tocar), quita comentarios y formato y compara cada archivo del juego con la etiqueta oficial. Tiene que salir `0 also change other platforms`. Los archivos que no son Haxe (`project.hxp`, `hmm.json`, `.gitignore`...) se listan para revisarlos a mano: `project.hxp` decide lo de Switch con `isSwitch()`.
- `--switch-against <commit>`: compara la vista de Switch (`switch` verdadero) con otro commit, para comprobar que un cambio de organización no altera lo que compila Switch.
- `--guard <archivo>...`: envuelve automáticamente cada bloque que también cambia otras plataformas en `#if switch` + `#else` + original. Los bloques que empiezan o terminan a medias de otro `#if` los deja para hacerlos a mano. Revisar siempre el resultado.
- Prueba de tipos de PC (manual, hecha para la Build 41): `haxelib run lime display linux` da el hxml; con él, `haxe <hxml>` (sin las inclusiones de librerías) sobre el árbol del port y sobre `git archive v0.8.7 source` produce **los mismos 13 errores**, todos por API de lime 8.3/flixel 6.2 que los forks no tienen (`deltaWheel`, `MessageBoxType`, `Display.orientation`, diálogos de archivo). Ninguno viene del código de Switch.

**Fase 2 (pendiente):** reducir los conflictos de fusión moviendo los bloques largos (`PlayState`, `FunkinMemory`, `FunkinSound`, `CrashHandler`, `VideoCutscene`) a clases de `source/nx/` con una llamada de una línea en el juego, o a parches de compilación por macro como `NXLibraryPatches`. No cambia el comportamiento; solo hace las fusiones más cortas.

Consecuencias para las actualizaciones:

- El port **no se pierde** al actualizar: git conserva los cambios y el comprobador avisa si algo de Switch se sale de sus guardas.
- Todavía hay conflictos donde FunkinCrew toca las mismas líneas (17 archivos en 0.8.3, 23 en 0.8.7); la fase 2 los reduce.

---

## 2. Librerías: oficiales frente a las del port

Pines de `hmm.json` de cada etiqueta oficial y de la rama del port:

| Librería | 0.8.1 oficial | 0.8.3 oficial | 0.8.7 oficial | Port (Build 40) |
| :--- | :--- | :--- | :--- | :--- |
| **lime** | FunkinCrew `318253ea3` | FunkinCrew `cae0c0bc1` | FunkinCrew `268dacfb2` (lime 8.3, **SDL3**) | **FunkinNXTeam/lime-nx `ad669eeb6`** (lime 8.2.2, SDL2) |
| **openfl** | FunkinCrew `a69a6e778` | FunkinCrew `5399946b6` | FunkinCrew `74a51908a` (9.5) | **FunkinNXTeam/openfl `33c6f1a2a`** (base `a69a6e778`) |
| **flixel** | FunkinCrew `c8e79d2a4` | igual | FunkinCrew `141f23c40` (6.2) | **FunkinNXTeam/flixel `a09ca08f2`** (base `c8e79d2a4`) |
| **hxcpp** | FunkinCrew `5932340d0` | igual | FunkinCrew `0376e9b19` | **FunkinNXTeam/hxcpp `3bf11bfd2`** (base `5932340d0`) |
| hx_libnx | — | — | — | Slushi-Github `5d7eb030d` (solo Switch) |
| polymod | larsiusprime `9824bf4f0` | FunkinCrew `5d47a5c7c` | FunkinCrew `acfdc2e26` | = 0.8.7 |
| flixel-addons | `6fa30b3f5` | igual | `762843536` | = 0.8.7 (sin `screengrab` en Switch) |
| flixel-animate | `c61476f4b` | `c5e3393c7` | igual | = 0.8.7 |
| FlxPartialSound | `26ed20b9c` | igual | `13a094939` | **`26ed20b9c` (el de 0.8.3)**: el nuevo necesita `lime.media.AudioDecoder` |
| haxeui-core | `088b153b3` | igual | `998534fb8` | = 0.8.7 (los editores no se compilan en Switch) |
| json2object | `a7e4cef3d` | `59e0467c9` | `dc945d58c` | = 0.8.7 |
| format | 3.5.0 | igual | 3.8.0 | = 0.8.7 |
| hxvlc | 2.2.5 | igual | 2.3.0 | = 0.8.7 (no se usa en Switch: vídeo propio) |
| newgrounds | `b2b53cd0a` | igual | `60162762e` | = 0.8.7 |
| Extensiones de móvil (admob, haptics, iap, iar, webview, agesignals) | — | — | nuevas o actualizadas | = 0.8.7 (no se compilan en Switch) |
| hscript | FunkinCrew `dcc6f822e` | eliminado | eliminado | eliminado (polymod lo incluye) |

Resumen: **todas las librerías del juego están en las versiones de 0.8.7**, salvo los cuatro forks de motor (lime, openfl, flixel, hxcpp) y FlxPartialSound. Los forks siguen en la base de 0.8.1 más los cambios de Switch.

### Qué traen las versiones oficiales de los forks que el port no tiene (0.8.3 → 0.8.7)

| Librería | Commits nuevos | Lo importante |
| :--- | ---: | :--- |
| lime | 772 | Paso a **SDL3** (entrada con marcas en nanosegundos, más mandos), API estática de `FileDialog`, `lime.media.AudioDecoder`, `System.setHint`, ventana `transparent`, `Display.orientation`; limpieza grande (quita Flash, Raspberry Pi, `Haptic`, herramientas viejas). |
| openfl | 397 | Subida de texturas con `texSubImage2D`, **arreglo del blend DARKEN con la extensión de ecuaciones de mezcla**, rueda del ratón con decimales (`deltaWheel`), `rumble` y LED en `GameInputDevice`, `__enterFrame` con `Float`, arreglos de seguridad, caché de filtros, quita Flash/AMF/ATF/hashlink/cppia. |
| flixel | 98 | **Rendimiento con el depurador cerrado (~1 ms por frame)**, `zIndex` en `FlxBasic`, rotación de cámara, interfaz común de grupos, `FlxSave.exists`, volumen logarítmico (revertido), `rumble` y LED en `FlxGamepad`, gestos de deslizar en táctil, giroscopio, arreglos de memoria en `FlxText`, arreglos de seguridad. |
| hxcpp | 72 | Mutex y variables de condición de C++11, zonas libres del GC en semáforos, objetos invocables tipados, Tracy 0.13.1, `HXCPP_CPP20`, arreglos de reflexión de arrays y de `String.fromCharCode`. |

Ninguno de estos cambios impide compilar el juego 0.8.7: lo que el juego nuevo usa y los forks no tienen está guardado solo en Switch (sección 4). Algunos merecen traerse a mano a los forks más adelante (pendiente H): el rendimiento del depurador de flixel, el arreglo de DARKEN (si la prueba en consola muestra el fallo), los arreglos de seguridad de openfl y flixel, y los arreglos del GC de hxcpp.

---

## 3. SDL3 y el lime propio

**No hace falta SDL3 para jugar 0.8.7 en Switch.** FunkinCrew cambió lime a SDL3 desde el pin de 0.8.4, pero el código del juego compila y funciona sobre nuestro lime-nx con SDL2, con guardas en los pocos sitios que usan API nueva.

Por qué el port sigue en SDL2:

- **devkitPro solo empaqueta SDL2 para Switch.** Su repositorio `devkitPro/SDL` tiene ramas `switch-sdl-3.2` y `switch-sdl-3.4`, pero son trabajo en curso (último commit de `switch-sdl-3.4`: 2026-02-01) y no hay paquete `switch-sdl3` en pacman. Usarlas significaría compilar y mantener SDL3 nosotros.
- **lime-nx no comparte historial con el lime de FunkinCrew** (es lime 8.2.2 subido de golpe), así que no se puede rebasar: pasar a lime 8.3 es reaplicar todos los cambios de Switch a mano sobre el lime nuevo.
- **Las partes críticas ya son propias y no dependen de SDL:**
  - audio: `nx/NXAudioDriver.hx` sustituye el driver de audio de SDL2 (INC-43). El PR que propusimos a devkitPro para ese fallo (`devkitPro/SDL#135`) lo cerró fincs sin fusionar el 2026-10-19, así que el driver propio sigue siendo necesario;
  - vídeo: FFmpeg propio (`nx/video/`);
  - previews de Freeplay: `nx/NXPreviewAudio`;
  - texturas e imágenes: parches de `NXLibraryPatches`.

Qué se pierde por seguir en SDL2:

| Función de SDL3 | Efecto en Switch |
| :--- | :--- |
| Marcas de tiempo de entrada en nanosegundos | `PreciseInputManager` convierte los milisegundos de SDL2 a nanosegundos. La precisión es de 1 ms, muy por debajo de las ventanas de acierto (las más estrechas, unos 45 ms). Además, Switch lee los mandos una vez por frame. |
| Más mandos y dispositivos | No aplica: Switch usa los Joy-Con y el Pro Controller por su propio driver. |
| "Unlocked Framerate" | Oculto en Switch: la pantalla va a 60 Hz. |

**Rama del experimento:** `feature/switch-lime83-sdl3` (creada el 2026-10-20 desde la Build 41). `nx-develop` sigue con lime-nx/SDL2 hasta que esa rama pase Citron y la consola.

**Cuándo replantearlo:** si devkitPro publica un paquete de SDL3 para Switch, si una versión futura del juego usa API de lime 8.3 que no se pueda guardar, o si FunkinCrew publica el motor nuevo de sus ramas de pruebas (`bgfx/public-playtest` para gráficos, `miniaudio/public-playtest` para audio). En cualquiera de esos casos, el plan es un lime propio sobre la versión de FunkinCrew con los cambios de Switch reaplicados (sección 8 del tracker).

---

## 4. Funciones del juego oficial que en Switch no están o funcionan distinto

### Por la plataforma (decisión de diseño, igual que en versiones anteriores)

| Función | En Switch | Motivo |
| :--- | :--- | :--- |
| Editores (charts, escenarios, animaciones) y haxeui | Apagados | Necesitan ratón y teclado; tampoco existen en móvil. |
| Vídeo con hxvlc (`FEATURE_VIDEO_PLAYBACK`) | Sustituido | Reproductor propio con FFmpeg (o las hojas PNG en la build pública, hasta el pendiente D). |
| Abrir URLs (`FEATURE_OPEN_URL`) | Apagado | Switch no abre URLs de forma fiable. |
| Discord RPC, volumen al perder el foco, capturas (`FEATURE_SCREENSHOTS`), arrastrar archivos | Apagados | Solo escritorio. Las capturas se hacen con el botón de la consola. |
| VSync y "Unlocked Framerate" | Ocultos y forzados a apagado | La pantalla va a 60 Hz y el port controla el ritmo de frames. |
| Mezclas avanzadas (`FORCE_BLEND_SHADER`) | Siempre por shader | Mesa no da la variante coherente de `KHR_blend_equation_advanced`. |
| Texturas comprimidas (`FEATURE_COMPRESSED_TEXTURES`) | Apagado | La condición oficial exige `isMobile()`; el uso en Switch es el pendiente E. |
| Controles táctiles (`FEATURE_TOUCH_CONTROLS`) | Apagado | Solo móvil; el táctil en portátil es el pendiente G. |
| Vibración (`FEATURE_HAPTICS`) | Sustituido | `nx/NXHaptics.hx` (HD Rumble). |

### Por los forks viejos (consecuencia de no actualizar lime, openfl y flixel; nuevo en 0.8.7)

| Función de 0.8.4-0.8.7 | En Switch | Notas |
| :--- | :--- | :--- |
| Diálogos de archivo (`FileUtil.browse*`, `saveFile`) | No hacen nada, como en HTML5 | Lo usan los editores (apagados) y "exportar datos de guardado como JSON" (`Save.hx`). |
| Captura de pantalla de flixel-addons (`screengrab`) | Fuera de la compilación | Las capturas son apagadas en Switch de todos modos. |
| Rueda del ratón con decimales (`FlxMouse.deltaWheel`) | Se usa `FlxMouse.wheel` | Sin efecto: en Switch no hay ratón. |
| `Display.orientation` | Siempre horizontal | Sin efecto en Switch. |
| `System.setHint` y ventana `transparent` | Quitados en Switch | Solo afectan a escritorio. |
| Marcas de tiempo de entrada de SDL3 | Milisegundos de SDL2 | Ver sección 3. |
| Previews parciales de FlxPartialSound nuevo | Pin de 0.8.3 | Las previews de Freeplay en Switch van por `NXPreviewAudio`. |
| Arreglo del blend DARKEN de 0.8.6 (DJ de Boyfriend con Dad en Freeplay) | Por verificar en consola | En Switch DARKEN pasa por el shader de `FunkinCamera` (`FORCE_BLEND_SHADER`), así que probablemente no tiene el fallo; comprobarlo en la prueba de consola. |
| Mods que usen API nueva de flixel u OpenFL (`zIndex`, rotación de cámara, `FlxSave.exists`...) | Fallarían en Switch | El juego base no las usa (compila); afecta solo a mods hechos para 0.8.6+. |

No se perdió ninguna función de Switch en la fusión: las 17 pruebas de `REGRESSION_SUITE`, las 9 de `CUTSCENE_SKIP` y `WEEKEND1_FULL` pasan en Citron sobre 0.8.7. El resto de escenarios y la prueba en consola están en el pendiente A.

---

## 5. Funciones de juego en Switch (resumen de flags de `project.hxp`)

Activas: Polymod (mods), FunkVis, Lag Adjustment, Newgrounds, menú de depuración, pantalla de depuración, ghost tapping (opción propia de Switch), registro de trazas. Apagadas o sustituidas: las de la sección 4.

---

## 6. Pendientes (orden acordado con el responsable del port)

| Paso | Qué | Detalle |
| :--- | :--- | :--- |
| **A** | Cerrar la Build 40 (0.8.7) | Terminar la validación en Citron (`MEMORY_BUDGET`, `AUDIO_DRIVER_STALL`, `SOAK`); `.nro` público con `PUBLIC_SMOKE` y la comprobación de `strings`; etiqueta `v0.8.7-nx-preview-1`. Prueba en consola: Freeplay, Spaghetti en portátil (GPU a 460,8 MHz), cinemáticas, antialiasing, memoria en sesión larga, nombres de botones, atajos L/R, relojes (460,8 MHz portátil, 768 MHz en dock) y el DJ con DARKEN. Instalar SwitchRPC v0.1.7 desactivado y, si sigue fallando, comentar en su issue #17. |
| **B** | Aislar el código de Switch | Fase 1 hecha en la Build 41 (sección 1). Fase 2, reducir conflictos de fusión, pendiente. |
| **C** | Instalador de assets | `.nro` público sin assets de FunkinCrew: al arrancar busca los assets oficiales en la SD; si no están, los descarga del GitHub oficial (el commit de la versión) o se copian a mano. Plan completo en `~/switch-builds/design/asset_installer_plan_2026-10-19.md` (pasos I1-I12). **Hecho (2026-10-20):** I5, `tools/nx-tools/gen_asset_manifest.py` (manifiesto por versión desde los manifiestos de lime de la build; 0.8.7 = 1939 archivos, 734 MB, idéntico al árbol de GitHub del commit `724eba9de`); I6a, núcleo del verificador en C (`source/nx/installer/nx_install_core.h`: manifiesto, comprobación rápida por tamaños, verificación completa SHA-256 con reparación de saltos de línea CRLF, estado), probado en el PC con `tools/nx-tools/installer-test/run_tests.py` (9/9). **Siguiente:** I3/I4 (raíz de assets en la SD), I1 (banco de red en consola; necesita `sudo pacman -S switch-curl`). |
| **D** | Vídeo y audio nativos en la build pública | Reproductor FFmpeg (hoy solo en la build de desarrollo). El audio de las cinemáticas sale del propio contenedor: Vorbis en Week 7, AAC en Weekend 1. Los "vídeos nativos" de la build son los archivos oficiales sin convertir (mismo tamaño que `videos/videos/*` del repo), así que con el instalador basta con leerlos de la SD: D va justo después de C. |
| **E** | ASTC | Rama aparte (`feature/switch-astc`) para comparar con la principal: conversión única en la consola tras la descarga; la decodificación por hardware necesita el ajuste de chipset de `libdrm_nouveau` (sección 4 de pendientes del tracker). Se compara memoria, tiempos de carga y fps con los mismos escenarios y solo se fusiona si mejora. |
| **F** | Release pública | `.nro` sin assets adjunto (posible solo después de C). |
| **G** | Rendimiento y táctil | Resolución interna real (INC-39), picos del GC, CPU de flixel-animate. Táctil en dos hitos: lector propio sin dedos fantasma (INC-52) y los controles táctiles de la versión de móvil (`FEATURE_TOUCH_CONTROLS`) solo en modo portátil, con opción en ajustes. |
| **H** | Después | Deriva de memoria con LE SSERAFIM (INC-55) y reserva del GC; traer a los forks las mejoras útiles de la sección 2; SDL3 cuando se cumpla alguna condición de la sección 3; reportes a devkitPro (táctil, chipset), en inglés y con visto bueno. |

---

## 7. Procedimiento para la próxima versión oficial

1. `git fetch upstream --tags` y `gh release list -R FunkinCrew/Funkin`. Leer el `CHANGELOG.md` de la versión nueva y anotarla en `SWITCH_UPSTREAM_CHANGES.md` (qué aplica a Switch y qué no). Ojo: hay versiones solo para Android (0.8.5 y 0.8.7), y GitHub marca como "Latest" la última de escritorio.
2. Comparar `hmm.json` de la etiqueta nueva con el de la rama (tabla de la sección 2). Si cambian los pines de lime, openfl, flixel o hxcpp, listar sus commits nuevos y buscar API que el juego empiece a usar.
3. Rama nueva desde la rama del port y `git merge vX.Y.Z`. Resolver conflictos conservando todos los bloques de Switch, y anotar en el mensaje de la fusión cada archivo en conflicto y cómo se resolvió.
4. Compilar para Switch. Cada error por API que los forks no tienen se arregla guardado solo en Switch, y se anota en la sección 4 de este documento.
5. `python3 tools/nx-tools/check_switch_isolation.py` tiene que dar 0 archivos que cambian otras plataformas; si no, `--guard` sobre los archivos que liste, revisar, y `--switch-against <commit anterior>` para confirmar que Switch no cambia.
6. Validar en Citron: `REGRESSION_SUITE`, `CUTSCENE_SKIP`, `WEEKEND1_FULL`, `MEMORY_BUDGET`, `AUDIO_DRIVER_STALL`, `SOAK`; después, prueba en consola.
7. Actualizar este documento (secciones 2, 4 y 6), el tracker (fila de build y bitácora) y la guía de sesión si cambia el método.
