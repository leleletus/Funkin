# Cambios de V-Slice por Versión (y qué significan para Switch)

Resumen en español del `CHANGELOG.md` oficial de FunkinCrew para cada versión que el port ha atravesado, con una nota de cómo afecta a Switch. El detalle completo (con los PR y autores) está en el [`CHANGELOG.md`](../CHANGELOG.md) del repositorio. El estado de las librerías y de las funciones que no están en Switch está en [`SWITCH_TECHNICAL_STATUS.md`](SWITCH_TECHNICAL_STATUS.md).

Marcas usadas en las notas de Switch:

- **[Sí]**: llega a Switch tal cual.
- **[Switch]**: llega, con un comentario.
- **[No aplica]**: es de otra plataforma o de los editores, que no se compilan en Switch.
- **[Distinto]**: en Switch se hace de otra forma.

## Historial del port

| Versión oficial | Fecha oficial | En el port | Notas |
| :--- | :--- | :--- | :--- |
| 0.8.1 | 2026-01-04 | Builds 1-32, release `v0.8.1-nx-release-1` | Base inicial del port. |
| 0.8.2 + 0.8.3 | 2026-02-23 | Build 33 (fusión de v0.8.3) | Sin cambiar los forks. |
| 0.8.4 - 0.8.7 | 2026-03-26 a 2026-08-23 | Build 40 (fusión de v0.8.7) | Forks en la base de 0.8.1; lo que falta se guarda solo en Switch. |

En GitHub, la 0.8.6 aparece como "Latest" porque la 0.8.7 (igual que la 0.8.5) solo trae arreglos de Android. A 2026-10-20 no hay versiones más nuevas: `main` y `develop` siguen en 0.8.7.

---

## De 0.8.1 a 0.8.3

### 0.8.2 (2026-02-23)

**Nuevo**

- 14 modos de mezcla (blend modes) nuevos para efectos visuales. **[Switch]** Siempre por shader (`FORCE_BLEND_SHADER`): Mesa no da la variante coherente de la extensión que usan.
- Parámetro de PlayState para reflejar las notas durante una canción. **[Sí]**
- Editor de charts: gráficas de los easing de los eventos, reflejar notas en X e Y. Editor de escenarios: botón y atajo para deseleccionar. **[No aplica]**

**Cambiado**

- Polymod (scripts de mods), todo **[Sí]**:
  - interpolación de strings;
  - clases que no heredan de nada o que heredan de otras clases de scripts;
  - errores más claros;
  - `scriptHas` y `staticScriptHas`;
  - `is` más fiel a Haxe;
  - `using` en funciones estáticas;
  - `interface`;
  - `typedef` con campos opcionales;
  - comprobación más estricta de los argumentos opcionales. Puede romper scripts viejos.
  - enums con varios argumentos;
  - `is` con tipos básicos sin importarlos.
- Charts ajustados en unas 30 canciones **[Sí]**:
  - Bopeebo (Pico Mix), Fresh Erect, DadBattle Erect y Pico Mix, Spookeez Erect y Pico Mix, South Erect, Pico;
  - Satin Panties Erect, High Erect, M.I.L.F, Cocoa Erect y Pico Mix, Eggnog Erect, Senpai (Pico Mix), Roses, Thorns Erect;
  - Ugh Erect, Guns (Pico Mix), SPAGHETTI, Darnell (BF Mix), Lit Up y BF Mix, y 2hot (Easy y Normal recharteados para ser más predecibles).
- El menú de Lag Adjustment admite offsets grandes. **[Sí]**
- El evento Set Camera Bop acepta decimales (precisión de 0,25). **[Sí]**
- Más imports por defecto para mods. **[Sí]**
- macOS sin alto DPI. **[No aplica]**
- Cambios en la exportación del editor de charts. **[No aplica]**

**Optimizado**

- Todas las variantes de Pico pasan a texture atlas para usar menos memoria. **[Switch]** En Citron, la memoria con 0.8.3 salió más alta que con 0.8.1 (suelo después de LE SSERAFIM: ~1166 MB nativos frente a ~806). Está en estudio en el tracker.
- Fondo de la mansión de Week 2 en atlas. **[Sí]**
- Render más rápido en Character Select. **[Sí]**
- Los tankmen corriendo en Stress (Pico Mix) ya no bajan el rendimiento. **[Sí]**
- Fuga de memoria en Freeplay corregida. **[Sí]**

**Arreglado**

- Polymod, todo **[Sí]**:
  - constructores con más de 4 argumentos y funciones con más de 8;
  - variables de script que se perdían en callbacks;
  - fuga de memoria con objetos anónimos;
  - propiedades `get_`/`set_` más fieles a Haxe.
- Sprites reexportados **[Sí]**: chispas del DJ Pico, retry de Pico (Blazin'), marcas en Pico (Christmas), offset de Nene (Christmas), pose de Daddy Dearest, sombrero de Monster (Christmas) y lata con brillo en 2hot.
- Freeplay **[Sí]**:
  - scroll muy rápido ya no crashea;
  - dificultades de mods bien dibujadas;
  - cápsulas con nombres largos y BPM bien alineados;
  - animación de confirmación del ícono pixel.
- Gameplay **[Sí]**:
  - los covers de las notas largas siguen al strumline;
  - pausa y game over ya no ponen el tema de otro personaje;
  - el foco de cámara del game over es consistente;
  - personajes pixel con `RetroCameraFade`;
  - el título de la canción se oculta al empezar Results;
  - los stickers ya no tapan el volumen.
- Escenarios **[Sí]**:
  - más rayos en South Erect y South (Pico Mix);
  - la música de la cinemática de Week 3 ya no se corta;
  - la cinemática de Stress se ve bien la segunda vez;
  - las latas de 2hot ya no suenan doble con offsets altos.
- Más clases bloqueadas por seguridad. **[Sí]**
- Arreglos de escritorio, móvil, Android, Windows, HTML5 y de los editores. **[No aplica]**

### 0.8.3 (2026-02-23)

- **El juego ya no tiene picos de lag constantes durante la partida** (PR #6970). **[Sí]** Es relevante para el rendimiento en Switch.
- Golpear una lata en 2hot ya no da error de script en HTML5. **[No aplica]**

---

## De 0.8.3 a 0.8.7

### 0.8.4 (2026-03-26)

**Nuevo**

- Polymod, todo **[Sí]**:
  - soporte completo de abstracts;
  - `'h'.code`;
  - imports por defecto (`import.hx`/`import.hxc`);
  - `scriptInit` y `listScriptClasses`;
  - parseo de `.hx`;
  - preprocesador `#if`/`#else` en scripts;
  - IDs de mod;
  - `_merge` de scripts.
- Escala para pantallas anchas en el evento Zoom Camera. **[Sí]**
- `flipY` en los props de Story Mode. **[Sí]**
- Inicio y fin configurables en las previews de Freeplay. **[Switch]** Las previews en Switch las decodifica `NXPreviewAudio`; hay que comprobar que respeta esos tiempos.
- `albumOSTName` y campo `capsule` en los datos de nivel. **[Sí]**
- `ScriptedBaseFreeplayDJ`. **[Sí]**
- Clase `FunkinGroup`. **[Sí]**
- `Reflect.makeVarArgs`. **[Sí]**
- Eventos de script para los eventos de canción. **[Sí]**
- Evento nuevo Set Target Bop Speed. **[Sí]**
- Editor de charts: seleccionar por encima o por debajo, editar el tiempo, "Edit Note", vista previa de personaje. **[No aplica]**

**Cambiado**

- **La entrada pasa de SDL2 a SDL3**: más precisión (nanosegundos), más mandos, opción "Unlocked Framerate". **[Distinto]** Switch sigue en SDL2. `PreciseInputManager` convierte los milisegundos a nanosegundos y "Unlocked Framerate" está oculto. Ver la sección 3 del estado técnico.
- Avisos emergentes cuando un mod tiene problemas (por ejemplo, la versión de API). **[Sí]**
- Al perder el foco, el volumen baja al 25 % (antes 50 %). **[No aplica]** Es solo de escritorio.
- La tecla de Character Select queda oculta hasta desbloquear un personaje. **[Sí]**
- Puntuación de Story Mode con comas. **[Sí]**
- Etiquetas de semana de Freeplay con fuente. **[Sí]**
- La pista de cambiar de personaje en Freeplay cambia con mando. **[Sí]** En Switch se muestran los nombres de los botones de Switch.
- La cinemática de Winter Horrorland pasa a script. **[Sí]**
- `FlxFilteredSprite` fusionado en `FunkinSprite`. **[Sí]**

**Optimizado**

- Mejor rendimiento en canciones con muchos eventos. **[Sí]**
- Ladrillos de Week 7 con mejor calidad. **[Sí]**

**Arreglado**

- Las notas largas puntúan igual a cualquier framerate. **[Sí]**
- Ventanas de acierto exactas para cada juicio. **[Sí]**
- Las notas largas ya no se suben al pulsarlas antes de tiempo. **[Sí]**
- El oponente ya no deja de cantar al fallar si Boyfriend no tiene voces. **[Sí]**
- Los eventos de cámara se pausan siempre con el menú de pausa. **[Sí]**
- El bop de cámara ya no se detiene con zoom de 1,35x o más. **[Sí]**
- El offset de la pausa cambia igual a cualquier framerate. **[Sí]**
- El rastro de Spirit es igual a cualquier framerate. **[Sí]**
- `onPause` se llama durante cinemáticas y diálogos. **[Sí]**
- El sound tray aparece siempre y suena al volumen correcto. **[Sí]**
- Los stickers se pausan al perder el foco. **[Sí]**
- Story Mode solo muestra las dificultades que tienen todas sus canciones. **[Sí]**
- Bop continuo de Girlfriend en Story Mode. **[Sí]**
- Freeplay **[Sí]**:
  - brillo del rank nuevo;
  - la cápsula Random sin números;
  - favoritos sin romper el texto de las cápsulas;
  - íconos pixel inválidos ya no se duplican;
  - salida del 100 %;
  - fondo alineado.
- Vídeos **[Distinto]**: ya no se silencian con volumen 3 o menos, y ya no tienen glitches al empezar. Switch usa su propio reproductor (o hojas PNG), así que no le afecta.
- Escenarios **[Sí]**:
  - rayos de Week 2 Erect, A-Bot (Dark), muerte junto a un rayo y Pico/Nene (Dark);
  - pelo de Girlfriend en Week 3;
  - bordes de Week 6 Erect al pasar a Results;
  - offsets de los personajes pixel;
  - líneas de Tankman en el game over de Ugh y Guns (Pico Mix);
  - reinicio en Stress (Pico Mix);
  - la lluvia se desvanece al pasar a Results.
- Íconos de vida con offsets uniformes. **[Sí]**
- Se quitó el beat en silencio al inicio de Ugh Erect. **[Sí]**
- Mods **[Sí]**:
  - OpenFL y algunas clases de lime accesibles;
  - clases de API protegidas accesibles;
  - más clases bloqueadas por seguridad.
- Arreglos de editores, Windows, Linux, HTML5 y móvil. **[No aplica]**

### 0.8.5 (2026-04-06)

- Solo Android: arreglos de visuales, controles y mandos. **[No aplica]**

### 0.8.6 (2026-08-12)

**Nuevo**

- Opciones de Discord RPC (activar estados, ocultar la canción). **[No aplica]** Discord RPC está apagado en Switch.
- Wayland en Linux. **[No aplica]**
- La versión del juego como flag de compilación para mods. **[Sí]**
- `shouldBop` para íconos animados. **[Sí]**
- Álbum y pack de stickers en la ventana de metadatos del editor. **[No aplica]**

**Cambiado**

- `FunkinGroup` con mejoras de ancho, alto y cliprect. **[Sí]**
- Imágenes de Discord RPC configurables en los datos. **[No aplica]**
- Las animaciones forzadas del jugador vuelven a activar sus voces. **[Sí]**
- El editor de animaciones con música y sonidos del editor de charts. **[No aplica]**

**Optimizado**

- Shader rimlight más rápido en el escenario Week 7 Erect. **[Sí]** Ayuda a la GPU de Switch.

**Arreglado**

- Polymod **[Sí]**:
  - la validación de argumentos ya no crashea;
  - `cast`;
  - todas las plataformas salvo Windows sin distinguir mayúsculas;
  - preprocesadores de archivo completo;
  - herencia de varias capas;
  - imports con nombre de módulo.
- **El blend Darken ya no dibuja cajas negras** (animación del DJ de Boyfriend con Dad en Freeplay). **[Switch]** El arreglo está en OpenFL nuevo, que el port no tiene. En Switch, DARKEN va por el shader de `FunkinCamera`, así que probablemente no tiene el fallo. Hay que verificarlo en consola.
- Gameplay **[Sí]**:
  - la latencia al acertar tarde se calcula bien;
  - pulsar una nota con dos teclas castiga la vida;
  - los covers de las notas largas ya no desaparecen cuando hay muchos;
  - pausar justo cuando salta un evento de cámara ya no lo cancela;
  - pausar durante el fundido de un diálogo pausa el fundido;
  - los eventos del Conductor no se disparan con un substate abierto;
  - ángulo de los íconos;
  - fallback del notestyle;
  - los personajes fuera de PlayState no crean íconos.
- Menús **[Sí]**:
  - desconectar el mando en el menú de controles ya no crashea;
  - Lag Adjustment ya no crashea al reentrar, ocupa toda la pantalla y calcula bien la latencia;
  - los avisos de datos de guardado bloquean el scroll de Opciones;
  - `onExit` se llama al salir.
- Freeplay **[Sí]**:
  - la preview se actualiza después del rank;
  - el título ya no se recorta;
  - el texto de las cápsulas no se aplasta;
  - alpha del fondo;
  - álbum OST Vol 1;
  - pista de personaje con mando;
  - nombres en Character Select.
- Escenarios **[Sí]**:
  - ojos de A-Bot;
  - voces del Pico doble tras el easter egg;
  - coche de Week 4 con zoom;
  - ícono de Spirit;
  - tankmen de Stress en pausa.
- Las variaciones de semana usan sus scripts propios. **[Sí]**
- Las carpetas de mods sin metadatos ya no dan error. **[Sí]**
- La lista negra de Polymod se aplica también en `ReflectUtil`, y se bloquean más clases por seguridad. **[Sí]**
- El diálogo de abrir archivos recuerda la carpeta. **[No aplica]** En Switch no hay diálogos de archivo.
- Arreglos del editor de charts y de escenarios, y de iOS. **[No aplica]**

### 0.8.7 (2026-08-23)

- Solo Android: crash al abrir un `.fnfc`, errores del backend de lime y un shader. **[No aplica]**

---

## Plantilla para la próxima versión

```
### X.Y.Z (fecha)
Fuente: CHANGELOG.md de la etiqueta vX.Y.Z. Plataforma: (escritorio / solo Android / ...)

**Nuevo** — cada punto con [Sí] / [Switch] / [No aplica] / [Distinto]
**Cambiado**
**Optimizado**
**Arreglado**

Librerías: pines de lime/openfl/flixel/hxcpp cambiados (sí/no); API nueva que use el juego.
Conflictos de la fusión: N archivos (lista en el mensaje del merge).
```
