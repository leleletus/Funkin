# Nintendo Switch Port Tracker & Master Control

Documento maestro de trazabilidad, control de versiones y especificación técnica del port de **Friday Night Funkin'** para **Nintendo Switch** (`feature/switch-fixes-and-perf`).

> **REGLA DE ORO:** Este archivo DEBE leerse antes de realizar cualquier cambio en el código para no reintroducir regresiones superadas. Se actualiza en cada iteración de compilación.

---

## 1. Tabla de Compilaciones (Build History)

| # Build | Tag / Ref | Commit Hash | Estado en Hardware | Cambios Clave |
| :--- | :--- | :--- | :--- | :--- |
| **Build 0** | `v0.8.1-nx-base-working` | `8e3a516` | Estable (Base) | Versión inicial funcional en Switch. Base de comparación. |
| **Preview 1** | `v0.8.1-nx-preview-1` | `4b18c21` | Inestable | Primeros ajustes de rendimiento y bindings iniciales. |
| **Preview 2** | `v0.8.1-nx-preview-2` | `295a02e` | Inestable | Intentos de optimización de assets y carga de texturas. |
| **Preview 3** | `v0.8.1-nx-preview-3` | `65917b8c4` | Estable (Hito) | Restauración de Story Mode, controles R3/L3 con debounce, fix fin de canción, [A] en ResultState. |
| **Build 4** | `feature/switch-fixes-and-perf` | `0a6324ec1` | Roto (Regresiones) | Crashes por scripts `.hxc`, pantalla blanca en Blazin', sustains a 2x velocidad de corte. |
| **Build 5** | `v0.8.1-nx-preview-4` | `46e35c859` | **Validado en Hardware Real (Éxito)** | 100% erradicación de errores `.hxc`, sustains perfectos (manual y Botplay universal en Bopeebo), shaders de lluvia y reflejos activos y visibles en Philly Streets, eliminación de pantalla blanca en Blazin', controles L3/R3/[A] con total estabilidad. |
| **Build 6** | `v0.8.1-nx-preview-5` | `a621511f0` | **Inestable (Regresión de memoria)** | Purga agresiva destructiva (`purgeVRAMAggressive()`) provocó colapsos en `FlxBar` (UI de salud destruida) y excepciones en scripts de Polymod (`backcard-bf.hxc`, `sortedLetters`). |
| **Build 7** | `v0.8.1-nx-preview-6` | `c50d3862d` | Validado en Hardware (Con hallazgos) | UI y Polymod 100% estables, pantalla de carga intermedia erradicada. Sin embargo, retención excesiva de escenarios (Weekend 1) provocó saturación de heap y crash por OOM en 2Hot/Freeplay. |
| **Build 8** | `v0.8.1-nx-preview-7` | `7194358b5` | Validado en Hardware (Con hallazgos) | Purga selectiva de escenarios pesados (`purgeStageCache`), remoción del bypass de retención `persist=true`, consolidación de heap Horizon OS (`cpp.vm.Gc.run(true)` / `compact()`), watchdog de audio contra softlock por parada anómala al final de canción, reorganización de menús de Switch y defaults de test. Hallazgos: OOM al salir por menú de pausa, freeze en Spaghetti por buffering sincrónico de audio en Go!, cinemáticas sin empaquetar en RomFS. |
| **Build 9** | `v0.8.1-nx-preview-8` | `06fa488ce` | Validado en Hardware | Confinamiento de `SwitchSettingsMenu` dentro de `PreferencesMenu`, erradicación total de fuga OOM en salidas por pausa (`PauseSubState.quitToMenu`), precarga y pre-buffering de OpenAL durante el conteo para eliminar freeze en `startSong` (Spaghetti), integración y empaquetado de cinemáticas convertidas en RomFS (`assets/videos/converted/`) con soporte multi-sheet en `NXVideoPlayer`. |
| **Build 12** | `v0.8.1-nx-preview-10` | `b6a2d31a2` | Validado en Hardware (Con hallazgos) | Protección de atlas FlxAnimate (`spritemap1.png`, `backing-text`) en `FunkinMemory` (`isProtectedGraphic` y `clearFreeplay`); corrección de pantalla negra al reentrar a canciones revirtiendo `moveToResultsScreen()` 1:1 con V-Slice; reescritura de `NXVideoPlayer` con streaming de 1 hoja a la vez y cargador multinivel de audio Vorbis `.ogg`. Hallazgos: Crash Null Object Reference en `FlxSignal.hx#295` al terminar hoja de cutscene, video en negro en Week 7/Weekend 1, crash Unmapped Write64 en transición Blazin->2Hot por shaders colgados e I/O thrashing en deep_engine_trace.log. |
| **Build 13 (Actual)** | `v0.8.1-nx-preview-11` | `HEAD` | **Validado en Hardware / Release (1.1 GB)** | Desacoplamiento total del avance de hojas y finalización de video en `NXVideoPlayer` hacia `FlxG.signals.postUpdate` (erradicación definitiva del crash `FlxSignal.hx#295`); corrección de visualización de video (`setGraphicSize(1280, 720)` y centrado tras asignar frames, `zIndex = 10000`, fondo negro puro en `camCutscene`); limpieza de filtros de shaders en cámaras (`performCleanup`) y purga de escenario post-`super.destroy()` en `PlayState.destroy()` para evitar OOM/Unmapped Write64 en Blazin->2Hot; y optimización de I/O en `NXDeepTrace.hx`. |

---

## 2. Registro de Componentes Validados (100% Funcionales)

Los siguientes componentes han sido exhaustivamente verificados en hardware real de Nintendo Switch y **NO DEBEN SER ALTERADOS NI REFACTORIZADOS**:

### Controles y Mapeo NX
- **L3 (Stick Izquierdo Push):** Cicla el overlay de rendimiento nativo (`Preferences.debugDisplay`: Off -> Simple -> Advanced) con debounce real de 250ms.
- **R3 (Stick Derecho Push):**
  - En partida (`PlayState`): Alterna Botplay de forma inmediata sin corromper la entrada del jugador.
  - En Freeplay (`FreeplayState`): Abre selector de personaje (`CharSelectSubState`).
- **Botón Menos (-):** Exclusivo para Reset rápido de canción (`FlxG.debugger.toggleKeys = []` deshabilitado para evitar conflictos).
- **Botón A:** Salida confirmada y fluida de la pantalla de resultados (`ResultState`).

### Menús y Transiciones
- **Story Menu -> PlayState:** Transición fluida sin corrupción de datos de notas.
- **LoadingState:** Pantalla de carga opcional gobernada por `Preferences.switchShowLoadingScreen` (por defecto `false` para transiciones 1:1 nativas idénticas a PC).
- **Submenú "Nintendo Switch":** Submenú dedicado con exclusivamente 5 ajustes de hardware: `Stage Shaders`, `Show Loading Screen` (default false), `Verbose Audio Telemetry`, `Resolution Mode` (720p, Docked, 540p) y `Note Splashes`.
- **Menú General de Opciones:** `Ghost Tapping` preservado en Jugabilidad (Gameplay) general; Performance HUD unificado con `Debug Display` nativo.

### Política de Memoria y Purga Selectiva de Escenarios
- **NUNCA destruir cachés globales a ciegas:** Se erradicó `purgeVRAMAggressive()`, `openfl.Assets.cache.clear()` y el vaciado indiscriminado de `FlxG.bitmap._cache`.
- **Protección estricta de UI y Scripts:** `FunkinMemory.isProtectedGraphic()` resguarda permanentemente:
  - Elementos de UI (`healthBar`, `icons`, `fonts`, `ui/`, `flixel/`).
  - Bitmaps dinámicos generados por `FlxBar` (`flixel.ui.FlxBar`).
  - Assets y spritesheets requeridos por scripts de Polymod (`assets/scripts/`, `backcards/`, `sortedLetters`).
- **Purga Selectiva de Escenarios (`FunkinMemory.purgeStageCache`):**
  - Identifica y destruye bitmaps pesados asociados a escenarios concluidos (`philly`, `stage`, `erect`, `spraycan`, `Spraypaint`, `weekend1`, etc.) al terminar canción o salir de semana.
  - Asegura que al salir de Story Mode al menú principal o Freeplay, los recursos gráficos de Weekend 1 queden 100% liberados de la GPU/VRAM antes de montar `FreeplayState`.
  - Invocación obligatoria de `cpp.vm.Gc.run(true)` y `cpp.vm.Gc.compact()` inmediatamente tras la purga para consolidar el heap de memoria unificada en Horizon OS.

### Watchdog de Audio en PlayState
- **Supervisión de fin de canción:** Si `!isGamePaused` y `!isInCutscene`, y la última nota del chart ya cruzó la línea de impacto hace más de 2.0 segundos, pero `FlxG.sound.music` no ha disparado `onComplete` o se detuvo anómalamente por underrun de buffer en OpenAL:
  - Se despacha limpiamente `endSong(true)`.
  - Evita softlocks donde el Conductor se congela y la partida queda atrapada en un bucle zombi.

### Telemetría de Sistema Real (Horizon OS)
- **libnx `svcGetInfo`:** Consulta directa al kernel de Horizon OS mediante `InfoType_UsedMemorySize` (7) y `InfoType_TotalMemorySize` (6) con `CUR_PROCESS_HANDLE`.
- **Overlay HUD Avanzado y Simple:** Muestra `GC: [Haxe MB] | SYS: [usedMemory / totalMemory MB]`, reportando con exactitud la memoria física real utilizada frente al heap total mapeado por libnx con `svcSetHeapSize`.

### Shaders y Efectos Gráficos
- **RuntimeRainShader:** Compilación y renderizado exitoso de lluvia y reflejos en Philly Streets y Philly Streets Erect sobre Tegra X1 (Mesa OpenGLES).
- **PhillyBlazin:** Eliminado el colapso a pantalla blanca mediante sanitización de `bitmapCoordScale` contra divisiones por cero y desactivación segura de filtros vacíos en `FunkinCamera.hx`.

### Jugabilidad y Notas
- **Notas Largas (Sustains):** Consumo proporcional exacto 1:1 restaurado en `SustainTrail.hx`. Operatividad total tanto en juego manual como con Botplay universal en todas las canciones (Bopeebo, Fresh, Spaghetti, etc.).

### Subsistema de Audio OpenAL
- **Fuga de canales OpenAL:** Eliminada. Los canales se limpian adecuadamente al cambiar de estado o reiniciar canciones.
- **Terminación natural de canciones:** Las canciones terminan y disparan el callback natural sin recortes artificiales (`musicLen - 25ms` prohibido).
- **Buffer Underrun Shield:** Almacenamiento en búfer nativo ajustado a 8 buffers (`native_audio_buffers = 8`).
- **Resync Shield:** `FunkinSound.set_time()` y `resyncVocals()` no destruyen ni recrean canales OpenAL si el desfase es despreciable (<15ms/<25ms).

---

## 3. Lista Negra de Archivos Protegidos (Prohibido Modificar)

> **ADVERTENCIA:** Modificar cualquiera de estos archivos sin autorización explícita reintroducirá crashes catastróficos en el intérprete HScript de Polymod o desestabilizará el pipeline de renderizado.

1. `assets/preload/scripts/stages/*.hxc`
   - `phillyStreets.hxc`
   - `phillyStreetsErect.hxc`
   - `phillyBlazin.hxc`
   - `sserafim.hxc`
   * **Motivo:** El parser de Polymod / HScript no soporta sintaxis tipada (`Null<T>`), directivas `#if`, ni resolución estática de `FlxG`. Los shaders y lógica Switch deben residir en código Haxe compilado (`source/funkin/...`), JAMÁS en scripts de assets.

---

## 4. Incidencias y Estado de Resolución

| ID | Incidencia | Causa Raíz Identificada | Estado |
| :--- | :--- | :--- | :--- |
| **INC-01** | Crash en arranque: `unexpected token "FlxG"` en `phillyBlazin.hxc#70`, `phillyStreets.hxc#178`, `phillyStreetsErect.hxc#185`. | Inserción de código Haxe compilado con tipos y llamadas directas en scripts `.hxc` interpretados por HScript. | **RESUELTO:** Rollback 100% de `preload/scripts/stages/*.hxc` a la versión base original. |
| **INC-02** | Pantalla blanca en *Blazin'* por colapso del framebuffer del shader. | En Mesa / Tegra X1 OpenGLES, si un shader filter de cámara (`RuntimeRainShader`) satura o falla, contamina `flashSprite.filters`. También división por cero en `bitmapCoordScale`. | **RESUELTO:** Protección en `FunkinCamera.hx`: si el shader falla o no tiene buffer válido, `filtersEnabled = false; flashSprite.filters = []`. Sanitización contra división por cero en `RuntimePostEffectShader.hx` y helper compilado `PhillyStreets.hx`. |
| **INC-03** | Sustains (notas largas) recortándose al doble de velocidad. | En `PlayState.hx:2941` se decrementa `holdNote.sustainLength = (holdEndTime - songPosition)`, y luego en `SustainTrail.hx:updateClipping` se restaba `(songTime - strumTime)` una SEGUNDA VEZ, duplicando la tasa de consumo visual de la cola. | **RESUELTO:** Cálculo proporcional exacto basado en el tiempo restante real y la longitud original sin doble resta. |
| **INC-04** | Desincronización/parada de audio en canciones con cutscenes largas (*Spaghetti*). | La canción inició a los ~14.4s tras la cutscene; llamadas redundantes a `set_time` y `resyncVocals()` destruían y recreaban canales OpenAL en caliente. | **RESUELTO:** Blindaje en `FunkinSound.hx` (ignorar reseek si delta < 15ms), `VoicesGroup.hx` (eliminada doble asignación de offset) y `PlayState.hx:resyncVocals()`. |
| **INC-05** | Regresión Preview-5: Crash en `FlxBar.hx` y en scripts de Polymod (`backcard-bf.hxc`, `sortedLetters`). | `purgeVRAMAggressive()` destruyó indiscriminadamente `FlxG.bitmap._cache` y `openfl.Assets.cache`, eliminando bitmaps internos de `FlxBar` y spritesheets requeridos por Polymod antes de montar o durante el desmontaje de estados. | **RESUELTO:** Erradicación total de purgas ciegas. Creación de lista blanca `isProtectedGraphic` para UI, FlxBar, fuentes y Polymod. Purga selectiva no destructiva y `cpp.vm.Gc.run(false)`. |
| **INC-06** | Auditoría y compatibilidad de rutas de videos/cinemáticas en RomFS. | En upstream, las cinemáticas de Weekend 1 y Week 7 dependen de archivos de vídeo (`.mp4`/`.mkv`) ubicados en `assets/videos/videos/`. En Switch, `FEATURE_VIDEO_PLAYBACK` no está habilitado por carecer de libvlc. `Paths.videos()` debe resolver rutas tanto anidadas como de raíz sin romper el prefijo de OpenFL. | **RESUELTO:** `Paths.videos()` ahora verifica existencia física y en RomFS de `videos/$file` y `$file`. `NXVideoPlayer` realiza omisión segura garantizada sin fugas de audio si no existen atlas convertidos (`.png`/`.xml`). Pipeline de conversión disponible en `tools/nx-tools/convert_video.py`. |
| **INC-07** | Agrupación limpia de opciones y telemetría de memoria física real en Horizon OS. | Opciones de Switch dispersas contaminaban el menú de preferencias estándar. El contador de RAM del HUD sólo reportaba el heap de Haxe (`openfl.system.System.totalMemory`), omitiendo el consumo de texturas de GPU y buffers de OpenAL. | **RESUELTO:** Submenú dedicado "Nintendo Switch" en `SwitchSettingsMenu.hx`. Consulta directa al kernel de Switch mediante `svcGetInfo` en `NXPerformance.hx` reflejada en el HUD como `GC: [Haxe MB] | SYS: [used / total MB]`. |
| **INC-08** | Saturación de VRAM y Crash por OOM al reentrar a Weekend 1 / 2Hot en Freeplay. | En Preview 6, `isProtectedGraphic` consideraba protegido todo asset con `persist = true`. Como `cacheTexture()` marca por defecto todos los gráficos con `persist = true`, los fondos, props y partículas pesadas de Weekend 1 (`phillyStreets`, `phillyBlazin`, `SpraycanPile`, etc.) se retuvieron indefinidamente. El valor `SYS: 3185 / 3189 MB` reflejaba el heap virtual mapeado por libnx con `svcSetHeapSize`, dejando margen nulo ante picos de asignación de GPU. | **RESUELTO:** Implementado `FunkinMemory.purgeStageCache(stageId)` que destruye explícitamente bitmaps de escenarios concluidos sin tocar UI ni Polymod. Eliminada la comprobación `if (obj.persist) return true;` para assets de escenario. Invocación de `cpp.vm.Gc.run(true)` y `cpp.vm.Gc.compact()` para consolidar el heap de memoria unificada. |
| **INC-09** | Softlock zombi por detención anómala de streaming OpenAL al final de canciones. | En ocasiones, tras la última nota, OpenAL no disparaba `onComplete` o sufría un corte por underrun de buffer, congelando el avance del Conductor e impidiendo la transición a `ResultState` o a la siguiente canción. | **RESUELTO:** Implementado watchdog en `PlayState.hx:update()`. Si han transcurrido > 2.0s desde que la última nota del chart cruzó la línea de impacto (`lastChartNoteTime`) y la música se encuentra detenida o no dispara `onComplete`, se invoca limpiamente `endSong(true)`. |
| **INC-10** | Duplicación de opciones y falta de defaults optimizados para testing en Switch. | Opciones duplicadas entre menús y necesidad de encender manualmente HUD y Botplay en cada sesión de prueba. | **RESUELTO:** Reorganizado `SwitchSettingsMenu.hx` limitándolo a 5 ajustes de hardware. Ghost Tapping conservado en Gameplay general. Defaults para builds de prueba: `debugDisplay = "Advanced"`, `botplay = true`, `switchShowLoadingScreen = false`. |
| **INC-11** | Fuga de VRAM y Crash OOM por salidas prematuras desde el menú de pausa. | Al pulsar "Exit to Menu" en `PauseSubState.hx`, `PlayState` se descartaba pero `purgeStageCache()` no se ejecutaba, provocando acumulación de escenarios en VRAM (Week 7 -> Weekend 1 -> Freeplay Pico -> 2Hot). | **RESUELTO:** Invocación explícita de `purgeStageCache()`, `purgeCache(true)`, `cpp.vm.Gc.run(true)` y `cpp.vm.Gc.compact()` en `PauseSubState.hx` (`quitToMenu`), refuerzo en `PlayState.hx:destroy()`, y purga preventiva en `StoryMenuState.hx:create()` y `FreeplayState.hx:create()` / `build()`. |
| **INC-12** | Congelamiento del hilo principal en "Go!" en Spaghetti (I/O contention). | Al pasar de `startCountdown()` a `startSong()`, la inicialización sincrónica de múltiples canales vocales con 8 buffers OpenAL (`native_audio_buffers=8`) bloqueaba el hilo principal por ~33 segundos. | **RESUELTO:** Precarga y encolado de buffers OpenAL en `PlayState.hx:startCountdown()` durante el conteo "Three, Two, One" manteniéndolos en pausa; en beat 0 ("Go!") solo se invoca `.play()` sin contención de I/O. |
| **INC-13** | Cinemáticas saltadas por ausencia de assets en RomFS y soporte multi-sheet. | `FEATURE_VIDEO_PLAYBACK` omitía la librería de assets `videos` en `project.hxp` para Switch. Además, faltaba ejecutar `convert_video.py` y `NXVideoPlayer.hx` carecía de soporte para hojas de atlas múltiples (`_0.png`, `_1.png`). | **RESUELTO:** Empaquetado de `assets/videos` en `project.hxp` para Switch (excluyendo contenedores pesados `.mp4`/`.mkv`). Conversión de todas las cinemáticas de campaña a secuencias Sparrow con audio Vorbis. `NXVideoPlayer.hx` extendido con soporte multi-sheet (`frames.addAtlas()`), escalado automático a 720p y purga de VRAM al terminar. |
| **INC-14** | `SwitchSettingsMenu` expuesto en la raíz de `OptionsState.hx`. | La entrada "Nintendo Switch" en la raíz del menú de opciones contaminaba la lista oficial de FNF. | **RESUELTO:** Eliminada la categoría de la raíz de `OptionsState.hx`; acceso confinado exclusivamente dentro de `PreferencesMenu.hx`. |
| **INC-15** | Destrucción de texturas de escenario y personajes al concluir cinemáticas. | `NXVideoPlayer.stop()` ejecutaba `FunkinMemory.purgeCache(true)`. En canciones como Ugh, Guns, Stress o Darnell, `PlayState.create()` precarga el escenario y los personajes antes de reproducir el video. Al terminar el video, `purgeCache(true)` destruía las texturas recién cargadas, causando sprites invisibles o colapsos Use-After-Free al iniciar el conteo. | **RESUELTO:** Eliminado `purgeCache(true)` de `NXVideoPlayer.stop()`. El reproductor ahora solo destruye sus propios `FlxAtlasFrames` y consolida memoria con `cpp.vm.Gc.run(true)` y `cpp.vm.Gc.compact()`. |
| **INC-16** | Micro-congelamientos por resync de OpenAL en gameplay y acumulación de VRAM en transición a `ResultState`. | En `PlayState.resyncVocals()`, se pausaba y relanzaba `FlxG.sound.music`, provocando micro-cortes y estallidos de buffer OpenAL. En `beatHit()`, las pistas de voz ya finalizadas seguían evaluándose provocando resyncs falsos. Al finalizar la canción, `ResultState` se instanciaba mientras el escenario (`currentStage`) y las voces permanecían cargados en VRAM/heap. | **RESUELTO:** `FlxG.sound.music` se mantiene continuo sin pausa; solo se ajusta `vocals.time` si el desfase supera `RESYNC_THRESHOLD = 85ms`. Pistas de voz terminadas (`instTime >= voice.length - 150`) son ignoradas. En `moveToResultsScreen()`, `vocals` se destruyen y `currentStage.kill()` se ejecuta antes de crear `ResultState`. Adicionalmente, en `StoryMenuState` se destruye `oldBackground` tras el fade y se invoca `super.destroy()` antes de `purgeTextureCache()`, y en `FreeplayState` se ejecuta `FunkinMemory.clearFreeplay()` al confirmar canción. |
| **INC-17** | Cuelgues en el analizador de Haxe / compilador por bucle `while (true)` en `NXVideoPlayer.hx`. | `while (true)` sin cota superior de iteración para buscar hojas múltiples (`_0.png`, `_1.png`...) podía causar bucles infinitos en el analizador de macros de Haxe o ante ambigüedades en RomFS. | **RESUELTO:** Bucle acotado explícitamente a `while (sheetIdx < 50)`. |
| **INC-18** | Crash Use-After-Free en "Exit to Menu" desde `PauseSubState` (`Cannot queue shared:... spritemap1.png. This sprite was destroyed`). | En `PauseSubState.hx:quitToMenu()`, se invocaba `purgeStageCache()` y `purgeCache(true)` sincrónicamente mientras `PlayState` aún estaba dibujando en ese frame (`persistentDraw = true`). La GPU intentaba renderizar a Girlfriend tras la destrucción de su textura. | **RESUELTO:** En `PauseSubState.quitToMenu()`, se desactivó `persistentDraw`, `persistentUpdate` y `visible` en `PlayState.instance` y se eliminó la purga sincrónica dentro del subestado. La purga se delegó a `PlayState.destroy()`, ejecutándose de forma segura después de `super.destroy()`. Adicionalmente, `FunkinMemory` ahora valida `!graphic.isDestroyed` y no elimina texturas en uso (`graphic.useCount > 0`). |
| **INC-19** | Error al presionar L3 (Left Stick click) y crash en Freeplay (`FunkinDebugDisplay`). | Al alternar modos de HUD con L3, si los componentes del grafo de rendimiento aún no estaban inicializados o el gamepad arrojaba excepción de estado, se producía un error. Además, la llamada a `purgeCache(true)` en `FreeplayState.create()` destruía sprites recién cargados en `new FreeplayState()`. | **RESUELTO:** Bloques `try/catch` de salvaguarda en `NXPerformance.hx` (detección de stick y toggle de HUD) y `Preferences.setDebugDisplayMode()`. Null guards en `FunkinDebugDisplay.hx` (`fpsGraph`, `gcMemGraph`, `textDisplay`). Eliminación de la llamada destructiva en `FreeplayState.create()` y `StoryMenuState.create()`. |
| **INC-20** | Cuelgue infinito del compilador Haxe (15+ min al 100% CPU) en la fase de tipado y macros. | `FunkinMemory.hx` tenía `@:nullSafety` habilitado sobre una cadena de 25 condiciones booleanas `||` en `purgeStageCache()`. El analizador de seguridad de nulos de Haxe (`camlNullSafety.process_condition`) evaluaba bifurcaciones exponenciales ($2^{25} = 33.5$ millones de ramas), saturando la pila de llamadas OCaml y congelando la compilación. | **RESUELTO:** Refactorización de las 25 condiciones a un arreglo estático `STAGE_PURGE_PATTERNS` evaluado en bucle lineal con corte temprano (`break`), y desactivación de nullSafety en `FunkinMemory.hx` (`@:nullSafety(Off)`). Tiempo de compilación de Haxe reducido de 15+ minutos (softlock) a **17.8 segundos**. |
| **INC-21** | Crash en Freeplay (`Cannot queue ... backing-text-yeah/spritemap1.png. This sprite was destroyed`). | Las animaciones de Adobe Animate (`FlxAnimate` / `BackingCard`) mantienen instancias internas cacheadas en `AtlasInstance` asociadas a `spritemap1.png`. `FunkinMemory.clearFreeplay()` (y la llamada agregada en `FreeplayState.capsuleOnConfirmDefault` o `purgeTextureCache()`) destruían manualmente el `FlxGraphic`, dejando referencias dangling vivas que explotaban al reingresar a Freeplay. | **RESUELTO:** En `FunkinMemory.isProtectedGraphic()`, se protegen explícitamente todas las texturas que contengan `"spritemap"`, `"backing-text"` o `"freeplay/"`. En `clearFreeplay()`, se excluyen estas texturas y se verifica `!obj.isDestroyed` y `obj.useCount > 0`. Se eliminó la llamada prematura a `clearFreeplay()` en `capsuleOnConfirmDefault` de `FreeplayState.hx` y el `destroy()` destructivo de `StoryMenuState.hx`. |
| **INC-22** | Pantalla negra de escenario y personajes al reingresar a una canción tras pasar por `ResultState`. | En `PlayState.moveToResultsScreen()`, la llamada a `currentStage.kill()` y `vocals.destroy()` dejaba el escenario en estado muerto y corrompía su reactivación en `StageRegistry`. Adicionalmente, el efecto `FlxG.camera.fade(FlxColor.BLACK, 0.6)` de `zoomIntoResultsScreen()` permanecía activo en `camGame`. | **RESUELTO:** Se revirtió `moveToResultsScreen()` 1:1 con el V-Slice oficial (`persistentUpdate = false; vocals?.stop(); camHUD.alpha = 1;`), permitiendo que `performCleanup()` gestione el ciclo de vida real al destruir `PlayState`. En `loadStage()`, se garantiza `currentStage.visible = true; currentStage.revive();` y se invocan `camGame.stopFX()` y `FlxG.camera.stopFX()` para limpiar cualquier fade residual. |
| **INC-23** | Fuga de 607 MB de RAM (GC: 607.1 MB), ausencia de audio y softlock al concluir cinemáticas en Week 7 / Weekend 1. | `NXVideoPlayer.hx` acumulaba todas las hojas atlas en RAM simultáneamente vía `frames.addAtlas()` (cargando ~540 MB de Bitmaps descomprimidos). El audio Vorbis `.ogg` fallaba en Switch porque `project.hxp` empaqueta la librería `videos` como `BINARY`, impidiendo la carga tradicional vía `Assets.getSound()`. Al no arrancar el audio, la guarda `if (!hasAudio)` impedía que `onFinish` se despachara, congelando el juego indefinidamente al terminar la animación. | **RESUELTO:** Reescritura total de `NXVideoPlayer.hx` con **streaming estricto de 1 hoja a la vez**: cada hoja se reproduce individualmente y al terminar se desecha su `BitmapData` (`disposeImage()`, `dispose()`) y su `FlxGraphic`, manteniendo el heap en ~35 MB. Se implementó un cargador multinivel para audio `.ogg` (resolución directa en `romfs:/` y decodificación de `AudioBuffer.fromBytes()`). Se añadió un watchdog por animación (`FlxG.signals.preUpdate` y `finishCallback`) que despacha `finishCutscene()` en cuanto concluye la última hoja sin quedarse esperando al canal de audio. |
| **INC-24** | Imposibilidad de saltar cinemáticas de video en Nintendo Switch. | `PlayState.handleCutsceneKeys` solo gestionaba pausa estándar mediante teclado/touch, omitiendo el mapeo de botones nativos de Switch durante la reproducción de videos adaptados. | **RESUELTO:** En `PlayState.handleCutsceneKeys`, se condicionó `#if switch` para que al presionar `controls.CUTSCENE_ADVANCE` (Botón A), `controls.ACCEPT`, `controls.PAUSE_P` (+) o `controls.BACK` (Botón B), se invoque inmediatamente `skipVideoCutscene()`, permitiendo saltar cualquier cinemática de forma instantánea. |
| **INC-25** | Crash `Null Object Reference in flixel/util/FlxSignal.hx#295` al terminar hojas de cutscene. | Dentro del callback `animation.finishCallback`, `NXVideoPlayer` mutaba o destruía sincrónicamente el `FlxSprite` (`loadAndPlaySheet()` o `stop()`). Al ocurrir dentro del bucle activo de `FlxSignal.dispatch()`, la lista interna de listeners se destruía, provocando una excepción fatal inmediata al retornar a `FlxSignal.hx#295`. | **RESUELTO:** Eliminado el uso de `finishCallback` y `onFinish.add`. El avance de hojas y la llamada a `finishCutscene()` se desacoplaron por completo hacia `FlxG.signals.postUpdate.add(onPostUpdate)`, garantizando que el ciclo interno de Flixel y sus señales concluya antes de alterar o destruir sprites. |
| **INC-26** | Video en negro en cinemáticas de Week 7 y Weekend 1 a pesar de audio Vorbis funcional. | En HaxeFlixel, reasignar `sprite.frames = newFrames` resetea automáticamente la escala interna a `(1, 1)` y las dimensiones al tamaño original de los subframes (480x270 o 640x360). Como `setGraphicSize(1280, 720)` se ejecutaba antes de cargar la hoja, el sprite quedaba encogido, descentrado, con `zIndex` default (0) y sin fondo negro dedicado en `camCutscene`. | **RESUELTO:** En `NXVideoPlayer.loadAndPlaySheet()`, se aplican `setGraphicSize(1280, 720)`, `updateHitbox()`, `screenCenter()`, `zIndex = 10000`, `visible = true` y `alpha = 1.0` de forma estricta **después** de asignar `frames`. Se configuró `camCutscene.bgColor = 0xFF000000` durante el video (y restauración a transparente en `stop()`) y se añadió fallback robusto de lectura de `BitmapData` desde `romfs:/` mediante bytes. |
| **INC-27** | Crash nativo `Unmapped Write64` en Citron al salir a mitad de Blazin' y entrar a 2Hot. | Al pulsar "Exit to Menu" en `phillyBlazin` (que usa shaders pesados de lluvia y relámpagos), los filtros de shaders en `camGame.filters` y `camHUD.filters` quedaban retenidos en GPU. Además, al haberse omitido la purga en salidas por pausa, los atlas pesados de Blazin' colisionaban en memoria con `phillyStreets` (2Hot), provocando fallo de asignación en C++ / GPU. | **RESUELTO:** En `PlayState.performCleanup()`, se limpian explícitamente todos los filtros (`filters = []`, `filtersEnabled = false`, `stopFX()`) en `camGame`, `camHUD` y `FlxG.camera`. En `PlayState.destroy()`, tras invocar `super.destroy()`, se ejecuta `#if switch funkin.FunkinMemory.purgeStageCache(currentStageId); cpp.vm.Gc.run(true); cpp.vm.Gc.compact(); #end`, liberando con seguridad el escenario previo sin peligro de Use-After-Free en el frame de dibujado. |
| **INC-28** | Sobrecarga de I/O y micro-tirones por apertura/cierre de `deep_engine_trace.log` en cada `trace()`. | `NXDeepTrace.hx` interceptaba cada llamada global de `haxe.Log.trace`, ejecutando `sys.io.File.append(logFilePath)`, `flush()` y `close()` decenas de veces por segundo en el hilo principal. | **RESUELTO:** En `NXDeepTrace.hx`, las llamadas rutinarias de frame se envían únicamente a la consola/salida estándar; a disco solo se escriben eventos críticos (`ERROR`, `WARN`, `STATE`, `SONG`, `[NXVideoPlayer]`, `STAGE`, `MEMORY`, `INPUT`, `AUDIO`) a menos que `Preferences.switchVerboseAudioLog` esté activado. |

---

## 5. Arquitectura de Git, Remotos y Flujo de Despliegue Automático

Para garantizar sincronización fluida entre computadoras de desarrollo y evitar desfasajes o sobreescrituras accidentales de historial, se define la siguiente topología de remotos:

### Mapeo de Remotos Git

| Nombre Remoto | URL del Repositorio | Propósito | Rama de Trabajo |
| :--- | :--- | :--- | :--- |
| **`personal`** *(Principal)* | `https://github.com/leleletus/Funkin.git` | Fork personal de desarrollo activo de @djvemo / @leleletus. **Aquí se suben los avances locales y versiones compiladas**. | `feature/switch-fixes-and-perf` |
| **`origin`** | `https://github.com/FunkinNXTeam/Funkin.git` | Repositorio central de la organización FunkinNXTeam. | `feature/switch-fixes-and-perf` / `nx-develop` |
| **`upstream`** | `https://github.com/FunkinCrew/Funkin.git` | Repositorio oficial de Friday Night Funkin' (upstream base). | `main` |

### Comandos de Despliegue y Sincronización Automática

1. **Subir cambios a GitHub personal (Recomendado):**
   ```bash
   git push personal feature/switch-fixes-and-perf
   ```
   *Si se ha reescrito o restaurado historial con commits limpios (como tras un rescate por reflog):*
   ```bash
   git push --force-with-lease personal feature/switch-fixes-and-perf
   ```

2. **Actualizar el fork personal hacia la organización (`origin`):**
   ```bash
   git push origin feature/switch-fixes-and-perf
   ```

3. **Sincronizar otra PC desde el fork personal:**
   ```bash
   git fetch personal
   git checkout feature/switch-fixes-and-perf
   git pull personal feature/switch-fixes-and-perf
   ```

4. **Regla de Oro Anti-Desfase:**
   - La rama local `feature/switch-fixes-and-perf` está configurada para rastrear `personal/feature/switch-fixes-and-perf`.
   - Antes de iniciar sesión de trabajo en otra máquina: `git pull personal feature/switch-fixes-and-perf`.
   - Al finalizar cada sesión de trabajo: `git push personal feature/switch-fixes-and-perf`.



