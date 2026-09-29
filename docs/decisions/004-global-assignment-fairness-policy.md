# ADR 004: Global assignment with bounded aging and route work

- Status: accepted task contract for #47
- Date: 2026-09-15
- Implements [ADR 003](003-scheduling-explainability-save-integrity-mobile-first.md), principle 1 (fair scheduling under load).

## Policy and acceptance contract (declared before implementation)

WorldState invokes one global pass each tick. Idle colonists include workers
whose previous job has terminated; active work is not preempted. Queued jobs
are indexed by descending `16 * priority - submitted_tick`, then submission
ordinal. Their effective priority is `16 * priority + ticks_waiting`.
Unbounded aging therefore overtakes the finite 32-point priority advantage.
Travel penalties are capped at 15, so distance cannot defeat aging forever.

Each idle colonist examines at most 32 indexed jobs per tick. A persistent
cursor advances past reserved, pending, or unreachable candidates, preventing
a blocked prefix from hiding later work. A new scan starts at the oldest
effective-priority head after reaching the end. Candidate pairs are ranked
globally by effective priority minus capped Manhattan travel lower bound,
then job ordinal and colonist ID. Disjoint pairs receive route requests in
two rounds, offering every worker a first candidate before second candidates.
Each worker retains a batch of at most two candidates, including its evaluation
cursor and completed route estimates. This is bounded greedy matching over a
global pair set, not optimal matching.

Each colonist owns at most one unfinished RouteSearch and calls its unchanged
`resume()` at most once per tick, reusing `RouteSearch.STEP_BUDGET` (64).
Pending requests survive ticks without reevaluation or frontier restart.
Found routes supply actual shortest-path travel estimates; completed batches
enter one global ready set ranked again using these estimates before activation.
Only the best available candidate per worker is activated; the unused candidate
remains queued. Each worker and job appears at most once in the assignment set.
A search in progress is never reported unreachable.
Unreachable results use t2's block reason and can be retried on a later scan.

A scheduling adapter exposes only selected jobs and proven blocking cases to
one call of t2's queue tick, then restores the full job collection. It does
not rewrite reservation or block-reason transitions. Deferred evaluation is
not a block reason. Reservations remain exclusively owned by t2. Block reasons
describe the last bounded evaluation and refresh when its cursor next visits;
the standalone queue's unbounded every-job polling is not run by WorldState.

## Supported load and executable example

`test_scheduling_fairness.gd` is the executable workload contract: 8 idle
colonists on a finite open 20-by-10 soil grid (surrounded by rock in the
48-by-48 world), 200 initially continuously
eligible unique dig orders cycling LOW/NORMAL/HIGH, and one new HIGH order
every 10 ticks for 600 ticks. New targets reuse completed tiles only. The
execution fixture completes each active order by explicit command before the
next tick; movement and excavation belong to a later task. Eligibility
means a passable target without a conflicting reservation and available
workers. Every initial and arriving order must transition to active within
300 ticks of submission, with zero starved orders. Arrivals continue while
the initial backlog drains, and the final cohort receives 300 drain ticks.
Two identical seeded runs must match state hashes and the complete event log.

Budgets are per colonist per tick: at most 32 job candidate examinations,
and at most 64 frontier expansions across all route work. Telemetry reports
actual expansions and resume calls, not merely a configured allowance.
The service bound applies to this declared workload, not arbitrary travel,
execution time, permanently blocked orders, or arrivals above service capacity.

## Alternatives and data boundary

Strict priority-FIFO can starve LOW jobs under continuous HIGH arrivals.
Greedy nearest-job selection can starve distant jobs and depends on worker
iteration order. Both reproduce the starvation risk ranked second in ADR 003;
bounded travel influence and aging avoid it.

The adapter and scheduler remain plain in-memory core objects. Existing save
schema and content examples are unchanged, as with t2/t3: these read models
are not valid save payloads. A future versioned save migration must include
submission ordinals/ticks, scan cursors, assignments and unfinished searches.
WorldState's diagnostic hash includes this continuation state. New command
payloads are `dig {x,y,priority?}` and `complete_job|cancel_job|fail_job|invalidate_job
{job_id}`; existing envelope validation still applies. Detached scheduling
telemetry and assignment reads are additive in-memory APIs. The fixture arranges
initial tiles/workers directly before issuing commands; no test-only production
command or public mutator is introduced.
