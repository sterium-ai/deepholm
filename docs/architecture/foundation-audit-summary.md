# Auditoría de la base: resumen para el propietario

> **En corto:** Las reglas del juego están bien hechas y son sólidas: el juego es
> predecible, está probado y separa bien la simulación de lo que se dibuja. Lo que todavía no
> aguanta crecer es la maquinaria por debajo. Lo peor: si 10 colonos tienen sed a la vez, ese
> tick tarda 1,6 segundos, y con 100 colonos tarda 2,5 minutos. Con 1.000 colonos, cada tick
> normal tarda 1,9 segundos sin hacer nada y 4,5 segundos trabajando, y el juego necesita 2
> ticks por segundo. Hoy se juega con 3 colonos. Además hay límites fijos: un solo nivel de
> mapa, una sola carpeta de contenido, nada de escenarios, historias ni traducciones, y solo
> exportación Web. Nada de esto obliga a reescribir el juego. Son 18 arreglos acotados, las
> tareas `A1`–`A18` del backlog, que aceptaste el 2026-10-25.

El detalle, con cada afirmación citada en el código y cada número medido, está en
[foundation-audit.md](foundation-audit.md). Aquí va lo esencial, sin jerga.

## Lo que es sólido (no hay que tocarlo)

- **El juego es determinista.** Con la misma semilla y las mismas órdenes, el resultado es
  idéntico, y hay pruebas que lo comprueban. Esto es la base de las partidas guardadas, de
  la depuración y de las repeticiones.
- **La simulación está separada de la pantalla.** Las reglas no dependen de cómo se dibujan.
  Por eso se pueden probar sin abrir el juego (90 pruebas automáticas) y, más adelante, se
  podrán ejecutar en otro hilo o en un móvil.
- **Hay un único motor de trabajo.** Todo lo que hace un colono es una tarea hecha de pasos,
  con un solo planificador justo. Es la forma correcta de crecer a miles de comportamientos.
- **El contenido son datos.** Objetos, tareas, actores y facciones se definen en JSON, con
  validación al arrancar.
- **Las partidas guardadas son robustas:** escritura atómica, comprobación de integridad y
  24 migraciones de versión con sus pruebas.
- **El proceso de trabajo:** contratos antes que código, decisiones escritas (ADR), límites de
  tamaño de archivo y la fase R, que está troceando `world_state.gd`.

## Lo que no aguanta todavía, en el orden en que se rompería

| # | Problema | Qué significa en el juego | Medido |
| --- | --- | --- | --- |
| 1 | **Buscar agua (o comida) cuesta el cuadrado del número de colonos.** Cada colono con sed compara cada casilla de agua con cada colono. | Cuando todos tienen sed a la vez (y la tienen, porque empiezan iguales), el juego se congela. | Sed simultánea: 10 colonos 1,6 s, 25 colonos 9,6 s, 50 colonos 38 s, 100 colonos 153 s, en un solo tick |
| 2 | **No hay "mapa de quién está dónde".** Para saber qué hay junto a un colono se recorre la lista entera de actores u objetos. | El combate cuesta el cuadrado del número de actores, aunque nadie pelee. | 1.000 colonos sin enemigos: 1.788 ms de 1.879 ms por tick (95 %) |
| 3 | **Buscar caminos es lento.** Cada paso de la búsqueda crea objetos nuevos, y el algoritmo no se orienta hacia el destino. | Un colono tarda en "pensar" la ruta antes de echar a andar. Cruzar el mapa de 256×256 lleva unos 120 s de juego a velocidad normal. | Ruta de 256 casillas: 15.462 pasos y 242 ticks |
| 4 | **Se copian listas enteras en cada tick.** Tareas y colonos se duplican varias veces por tick para leerlos. | Cuantas más órdenes pendientes, más lento va todo. | 10 colonos con 2.000 órdenes: 235 ms por tick (sin órdenes: 1,6 ms) |
| 5 | **Nada se olvida.** Las tareas terminadas, los eventos y las casillas cambiadas se acumulan para siempre. | Una partida larga se va volviendo más lenta, aunque la colonia sea pequeña. | 10 colonos: de 17 a 25 ms por tick en 6.000 ticks |
| 6 | **Guardar es lento y bloquea la pantalla.** Se valida y se convierte a texto varias veces, y el mapa se guarda casilla a casilla. | Con 1.000 colonos, cada autoguardado congela el juego. | 1.000 colonos: 2,0 s guardar, 2,1 s cargar, 1,4 MB |
| 7 | **Cada partida cargada se queda en memoria.** El mundo viejo no se libera al cargar otro. | Cargar muchas veces en una misma sesión va llenando la memoria. | 32 objetos sin liberar por cada mundo descartado |
| 8 | **Un solo nivel de mapa.** Todo el código supone un mapa plano (506 sitios con coordenadas 2D). | Antes del subsuelo (F4) hay que decidir cómo se dirán las coordenadas con capas. | — |
| 9 | **Los comportamientos siguen en código.** Qué produce talar, cavar o labrar está escrito en código, no en datos. | Añadir un tipo de trabajo nuevo obliga a tocar el archivo más grande. | — |
| 10 | **Sin escenarios, historias ni misiones.** No hay formato de nivel ni sistema de "si pasa X, ocurre Y". | Cada historia sería código a mano. | — |
| 11 | **Sin traducciones ni mods.** Hay textos en inglés dentro del código, y el contenido se lee de una sola carpeta. | Traducir o cargar un paquete de contenido no es posible todavía. | — |
| 12 | **Sin versión para móvil.** Solo hay exportación Web, no hay control táctil y no se ha medido nada en un teléfono. | No sabemos cuánto más lento irá en un móvil. Seguramente varias veces más. | — |

## Cuánto cuesta arreglarlo y en qué orden

Cada tarea es del tamaño de una tarea R: un worktree, una rama, un PR y una revisión de Codex.

1. **A1:** guardar los números de referencia, para que cada arreglo demuestre su mejora. Es
   muy pequeña.
2. **A2–A6, el rendimiento base.** Consultas al mapa sin crear objetos (A2), búsqueda de
   caminos sin crear objetos (A3), búsqueda de agua y comida por región e índice de quién está dónde (A4), tareas sin copias ni
   acumulación (A5) y eventos con límite (A6). Son 5 tareas medianas. Ninguna cambia lo que
   pasa en el juego, solo lo rápido que pasa, y se comprueba comparando partidas byte a
   byte. A5 cambia además el formato del guardado, con su migración. Algunas esperan a la tarea R que crea su módulo (R3 en especial).
3. **A7, guardar rápido y en segundo plano.** Una tarea mediana. Cambia el formato del
   guardado, con su migración.
4. **A8, caminos con A\*.** Los colonos encuentran rutas mucho antes. Puede cambiar cuál de
   dos caminos igual de cortos eligen, así que necesita una decisión escrita (ADR).
5. **A9, la pantalla con 1.000 colonos.** Dibujar en lote en vez de un nodo por colono.
   Una tarea mediana.
6. **A10 y A11, red de seguridad.** A10 avisa del código sin tipos y A11 graba y reproduce
   partidas para cazar errores. Son 2 tareas pequeñas.
7. **A12–A17, la base para la variedad.** Decidir las capas del mapa (solo documento, antes
   de F4), paquetes de contenido, trabajos definidos en datos, textos traducibles,
   escenarios y diseño del sistema de historias (solo documento). Los documentos pueden ir
   ya; el código, después de R12.
8. **A18, prueba en un móvil real** antes de prometer nada en móvil.

**Mi recomendación:** sigue con la fase R tal como está y mete A2–A6 entre las tareas R
según su dependencia (detalle en la auditoría, §7). El objetivo medible es que
1.000 colonos bajen de 1,9–4,5 s por tick a algo jugable, sin cambiar ninguna regla del juego.
No prometo una cifra hasta medir cada arreglo. A12 y A17 son solo
documentos, así que conviene cerrarlos contigo antes de llegar a F4 y a las historias.

## Decisión

Aceptaste las 18 tareas el 2026-10-25. Están en `todo` en `docs/orca/BACKLOG.md`, en la
sección *Accepted by the owner (2026-10-25)*, y ninguna está empezada. En A5 y A7 queda
escrito que, después de R14, todo cambio de esquema lleva subida de versión, migración y
fixture.
