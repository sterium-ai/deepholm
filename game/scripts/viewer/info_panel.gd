extends ScrollContainer

## The debug viewer's independently scrollable information column: the
## status line, the alert/rejection/room labels boot.gd owns, the work table
## and the colonist panel. Layout only; boot.gd sets the label texts.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const WorkTablePanelType = preload("res://scripts/viewer/work_table_panel.gd")

var content: VBoxContainer
var status_label: Label
var work_table_panel: WorkTablePanelType
var colonist_panel: ColonistPanelType

func _init() -> void:
	custom_minimum_size.x = 360

## Call after this node is in the tree. `labels` are added under the status
## line, in order.
func build(world: WorldStateType, text_table: TextTableType, labels: Array[Label]) -> void:
	content = VBoxContainer.new()
	content.custom_minimum_size = Vector2(620, 1000)
	add_child(content)
	status_label = Label.new()
	content.add_child(status_label)
	for label in labels:
		content.add_child(label)
	work_table_panel = WorkTablePanelType.new()
	work_table_panel.custom_minimum_size = Vector2(620, 330)
	work_table_panel.setup(world, text_table)
	content.add_child(work_table_panel)
	colonist_panel = ColonistPanelType.new()
	colonist_panel.custom_minimum_size = Vector2(620, 650)
	colonist_panel.setup(world, text_table)
	content.add_child(colonist_panel)

## The colonist ids whose full records the next refresh() reads (the colonist
## panel's window), for boot.gd's WorldState.get_view_snapshot(detail_ids).
func detail_ids() -> Array:
	return colonist_panel.detail_ids()

## `snapshot` is this tick's WorldState.get_view_snapshot() (A9), shared by both panels.
func refresh(snapshot: Dictionary = {}) -> void:
	colonist_panel.refresh(snapshot)
	work_table_panel.refresh(snapshot)

func set_world(world: WorldStateType) -> void:
	colonist_panel.world = world
	colonist_panel.forget_rows()
	colonist_panel.refresh()
	work_table_panel.world = world
	work_table_panel.refresh()
