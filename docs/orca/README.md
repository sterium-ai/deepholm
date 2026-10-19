# Trabajar en Deepholm desde Orca (guía del propietario)

> **En corto:** Orca abre un *worktree* (una copia aislada del repo con su propia rama) por
> tarea, lanza Claude Code (Opus) dentro para hacerla, y Codex revisa el resultado. Tú no
> tocas el código: eliges la tarea, lees el informe, pides la revisión y fusionas.

Esta carpeta sustituye al antiguo pipeline automático (`agent-orchestrator`). Ya no hay
supervisor, ni issues `agent-ready`, ni tareas programadas en el PC. Cada tarea es un worktree
de Orca que tú abres y cierras.

## Qué hay aquí

| Archivo | Para qué |
| --- | --- |
| `README.md` | Esta guía: cómo operar día a día |
| `BACKLOG.md` | La lista ordenada de tareas, con criterios de aceptación. **Las tareas se cogen de aquí, en orden** |
| `REFACTOR-PLAN.md` | El plan técnico para convertir `world_state.gd` (5.000 líneas) en módulos pequeños sin romper nada |
| `REVIEW.md` | Lo que Codex comprueba al revisar. Claude lo lee antes de entregar; Codex lo usa como guion |
| `../design/baseline.md` | El inventario del mínimo que el juego debe cubrir antes de añadir ideas nuevas |

## Preparación (una sola vez)

1. Repo local: `C:\dev\deepholm` (clon de `sterium-ai/deepholm`, rama `main`).
2. Godot: variable de entorno de usuario `GODOT` apuntando al ejecutable de consola 4.7.2
   (ya configurada; `tools\run_tests.ps1` la usa).
3. Orca: el repo está registrado (`orca repo list` lo muestra como `deepholm`). Los worktrees
   se crean en `C:\Users\<usuario>\orca\workspaces\deepholm\<nombre>`.
4. Claude Code usa Opus por defecto en este repo (`.claude/settings.json`). Codex revisa con
   `codex review`.

## Ciclo de una tarea

### 1. Abrir la tarea

Desde cualquier PowerShell en `C:\dev\deepholm`:

```powershell
tools\orca\new-task.ps1 R1
```

Esto crea el worktree `R1`, lanza Claude Code dentro y le entrega el encargo
"haz la tarea R1 de docs/orca/BACKLOG.md" con las reglas del repo. También puedes hacerlo a
mano en Orca: *New worktree* → nombre `R1` → agente *Claude* → prompt:

```
Lee AGENTS.md y docs/orca/README.md. Haz la tarea R1 de docs/orca/BACKLOG.md.
Termina con el informe de entrega que pide AGENTS.md.
```

Claude trabaja solo: importa el proyecto, hace el cambio, corre la suite de tests headless y
escribe un informe. Si pregunta algo, contesta en su terminal.

### 2. Revisar con Codex

Cuando Claude diga que ha terminado, en una terminal **del mismo worktree** (Orca → `+` →
Terminal) ejecuta:

```powershell
tools\orca\review.ps1
```

Codex compara la rama con `main`, aplica `docs/orca/REVIEW.md` y escribe su veredicto en
`.orca-review.md` (ignorado por git). El script intenta además enviar el informe a la terminal
de Claude con la instrucción de corregir lo que proceda. Si no lo consigue, escríbele tú:

```
Lee .orca-review.md y corrige lo que proceda. Vuelve a pasar los tests y actualiza el informe.
```

Repite revisión → corrección hasta que Codex no tenga hallazgos bloqueantes (normalmente 1–2
vueltas). Codex **no** edita código; solo Claude escribe.

### 3. Enviar y fusionar

```powershell
tools\orca\ship.ps1
```

Sube la rama y abre el pull request. GitHub Actions corre la suite completa en Windows. Cuando
esté en verde, fusiona desde la pestaña *PR* de Orca (o `gh pr merge --squash`). Después borra
el worktree en Orca (clic derecho → *Delete*).

### 4. Siguiente tarea

Vuelve al paso 1 con el siguiente id del `BACKLOG.md`. Las tareas `R*` (refactor) van en
orden estricto, de una en una, porque cada una toca `world_state.gd`. Las tareas `F*`
(funcionalidad) pueden ir en paralelo cuando el backlog lo indique.

## Reglas que no cambian

- **Tú decides reglas de juego; los agentes deciden implementación.** Antes de abrir una
  tarea `F*` cuyo diseño no esté cerrado en `BACKLOG.md`, pídele a Claude (en el chat de
  Claude, no en Orca) que te haga las preguntas de diseño y actualice el backlog.
- **Primero el mínimo del juego de referencia (`docs/design/baseline.md`), luego las ideas
  nuevas.** Si una tarea salta ese orden, hay que decirlo.
- **Nunca se "arregla" un test desactivándolo.** Si un test falla por el refactor, el refactor
  está mal o el test necesita adaptarse a una API nueva, y eso se explica en el informe.
- **Una tarea = una rama = un PR.** Nada de mezclar refactor con funcionalidad.

## Cuando algo va mal

- *Claude dice que no puede correr Godot:* comprueba que `$env:GODOT` existe en esa terminal
  (`echo $env:GODOT`). Si no, cierra y reabre Orca para que herede la variable.
- *Los tests fallan en `main` también:* no es culpa de la tarea; ábrele una tarea `R0-fix`
  a Claude con el nombre del test.
- *Codex no tiene cuota:* `review.ps1 -Agent claude` hace la revisión con una sesión nueva de
  Claude en lugar de Codex (misma guía, menos independiente; úsalo solo de emergencia).
- *Un worktree quedó a medias:* bórralo en Orca y vuelve a abrir la tarea. La rama vieja se
  puede recuperar desde `git branch -a` si hacía falta.
