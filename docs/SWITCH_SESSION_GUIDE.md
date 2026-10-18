# Guía de Inicio de Sesión — Port de Nintendo Switch (V-Slice)

Texto de arranque para cada sesión de trabajo en la rama `feature/switch-fixes-and-perf`. Se pega al comenzar y se completa la sección **"Tarea de esta sesión"** con el problema concreto.

---

Actúa como **Lead C++/Haxe Engine Architect** del port de **Friday Night Funkin' (V-Slice)** para **Nintendo Switch** (rama `feature/switch-fixes-and-perf`).

## 1. Reglas inquebrantables del proyecto (leer antes de actuar)

1. **Port 1:1 y modular**
   - El juego debe comportarse **1:1 idéntico al V-Slice oficial de PC** en mecánicas, visuales, shaders y cinemáticas. Ninguna optimización puede quitar efectos (lluvia, niebla, polvo, splashes, shaders).
   - Toda la lógica nueva de Switch va en `source/nx/` (`NXVideoPlayer`, `NXAutoTest`, `NXRegressionSuite`, `NXDeepTrace`, `NXPerformance`, `NXAudioDiagnostics`, `NXTextureMemory`).
   - Los cambios en el motor oficial (`source/funkin/...`) deben ser mínimos, sin hardcode y dentro de `#if switch ... #end`, para que `git merge upstream/main` siga limpio cuando FunkinCrew publique actualizaciones (Week 8).
2. **Lista negra**
   - **Prohibido** modificar los `.hxc` de `assets/preload/scripts/` (el parser HScript de Polymod falla con `Null<T>`, `#if` o accesos estáticos).
   - **Prohibido** hacer commits dentro del submódulo `assets`. Debe apuntar a un commit oficial de `FunkinCrew/Funkin.assets` (actual: `39d4b3f`). Los assets de Switch derivados (cinemáticas) se **generan** al compilar con `tools/nx-tools/prepare_switch_assets.py`; nunca se versionan ni se redistribuyen (la licencia de los assets lo prohíbe).
   - No debilitar `FunkinMemory.isProtectedGraphic()` ni volver a limpiezas ciegas de caché (ver INC-05, INC-18, INC-21).
3. **Evidencia empírica obligatoria**
   - No asumir ni adivinar: reproducir el problema con un escenario automatizado, citar la salida literal de `deep_engine_trace.log` y verificar la corrección con las suites de Citron.
   - Para errores vistos en la consola real, pedir que se active el FTP (normalmente apagado) y leer los logs de la Switch antes de tocar nada.
4. **Higiene del repositorio**
   - El repositorio solo contiene código, herramientas y documentación del port: nada de archivos de configuración de herramientas externas en la raíz, y commits, tags y releases sin firmas automáticas ni líneas `Co-Authored-By`. Toda la documentación vive en `docs/`.
   - Todo cambio, rama y tag se sube al remoto `personal`. Nada debe quedar solo en local.
5. **Citron**
   - Cerrar siempre el emulador al terminar cada prueba (consume ~10 GB de RAM). Comprobar con `ps -eo pid,comm | awk '$2=="citron"'`.
   - No recompilar mientras Citron está ejecutando el `.nro`.

## 2. Fase 1 — Puesta al día

1. Leer íntegro `docs/SWITCH_PORT_TRACKER.md`: builds, componentes validados, lista negra, incidencias (`INC-01` en adelante), remotos Git, flujo de trabajo (sección 6) y **protocolo de sesión y bitácora (sección 7)**.
2. Revisar el estado:
   ```bash
   git status -s
   git log -n 6 --oneline
   ls -la source/nx/ source/nx/video/ tools/nx-tools/
   ```
3. Revisar las incidencias **ABIERTAS** y la última entrada de la bitácora del tracker.

## 3. Herramientas disponibles (no hay que crearlas)

| Herramienta | Uso |
| :--- | :--- |
| `haxelib run lime build switch -release -DHXCPP_COMPILE_THREADS=4 -DNX_DEV_TOOLS` | Compilación incremental de pruebas (~45 s; sin `-DNX_DEV_TOOLS` = build pública sin botplay ni autotests). No borrar `export/release/switch/obj/` salvo necesidad. |
| `./tools/nx-tools/run_citron_autotest.sh <ESCENARIO> <TIMEOUT>` | Prueba en Citron. Cierra el emulador al terminar y detecta crashes nativos. |
| Escenarios | `WEEKEND1_PLAYLIST`, `WEEKEND1_FULL`, `REGRESSION_SUITE`, `REGRESSION_FROM_<n>`, `SOAK`, `CUTSCENE_DARNELL`, `CUTSCENE_2HOT`, `CUTSCENE_UGH`, `BLAZIN`, `AUDIO_TORTURE`, `AUDIO_STARVE`, `AUDIO_DRIVER_STALL`, `AUDIO_DRIVER_STALL_LEGACY`, `HAPTICS` (detalle en la sección 6 del tracker). Sufijos de diagnóstico: `NOTEXMEM`, `NOUPLOADREL`, `NOPOSTREL`. |
| `python3 tools/nx-tools/decode_switch_crash.py [log]` | Traduce backtraces nativos (Citron o Atmosphère) a funciones con `aarch64-none-elf-addr2line`. |
| `./tools/nx-tools/check_ogg_overflow.sh` | Verifica que ningún `.ogg` desborde el decodificador de lime-nx (INC-37). |
| `python3 tools/nx-tools/prepare_switch_assets.py` | Genera las cinemáticas de Switch desde los vídeos oficiales (lo ejecuta `project.hxp` automáticamente). |

Rutas clave:
- Emulador: `/home/djvemo/Applications/citron_nightly-308bc267c-linux-x86_64-use-nopgo_f1ac8aeaee5c67403a7d350daea956eb.AppImage`
- Traza del motor: `/home/djvemo/.local/share/citron/sdmc/switch/Friday-Night-Funkin/logs/deep_engine_trace.log` (también `crash-*.log`, `citron-native-crash-*.log` y capturas `autotest_*.png`)
- Log del emulador: `/home/djvemo/.local/share/citron/log/citron_log.txt`
- FTP de la consola: `192.168.18.198:5000`, carpeta `/switch/Friday-Night-Funkin/`

## 4. Fase 2 — Tarea de esta sesión

> Completar antes de pegar: síntoma exacto, dónde ocurre (consola real o Citron, modo, semana, canción, dificultad), pasos para reproducirlo y qué se espera.

Pasos:
1. Localizar en el tracker si la incidencia ya existe (misma causa o síntoma parecido) y qué se intentó.
2. Reproducirla con un escenario existente o crear uno nuevo en `NXAutoTest` / `NXRegressionSuite` que la provoque de forma determinista.
3. Diagnosticar con evidencia: telemetría `[MEMORY]` / `[MEMSAMPLE]` / `[PEAK]` / `[PERF]` / `[AUDIO]`, pila de `END_SONG`, backtrace decodificado y capturas de frame. Hacer pruebas A/B cuando haya varias causas posibles.
4. Presentar el diagnóstico y el plan antes de implementar.

## 5. Fase 3 — Corrección y validación

1. Implementar la corrección en `source/nx/` con cambios mínimos en `source/funkin/` (siempre dentro de `#if switch`).
2. Compilar y validar, como mínimo, con `REGRESSION_SUITE` y el escenario de la incidencia. Si toca memoria, audio o transiciones, añadir `SOAK` y `WEEKEND1_FULL`.
3. Revisar visualmente las capturas `autotest_*.png` cuando el cambio pueda afectar al render.
4. Mostrar la salida literal del log que demuestra la corrección.

## 6. Fase 4 — Cierre de sesión

Seguir la sección 7 del tracker:
1. Fila de la build nueva en la tabla de compilaciones.
2. Fila `INC-XX` por cada incidencia (síntoma, causa raíz demostrada y estado).
3. Entrada en la bitácora de sesiones (fecha, build, trabajo realizado, pendiente).
4. Commit sin trailers de atribución, push a `personal`, tag anotado `v0.8.1-nx-preview-N` y push del tag.
5. Release en GitHub según la política vigente sobre el `.nro` (ver bitácora).
6. Despliegue en la consola por FTP si está activo: respaldar `saves/` y `logs/`, limpiar la carpeta y subir el `.nro`.
